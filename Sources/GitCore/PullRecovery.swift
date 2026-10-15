import Foundation

public struct PullOperationOutcome: Sendable {
    public let conflicts: [String]
    public let stashHash: String?
    public let changesRestored: Bool
    public let restorationError: String?
    public var needsNotice: Bool { !conflicts.isEmpty || stashHash != nil }
}

public struct PullRecoveryFailure: LocalizedError, Sendable {
    public let stashHash: String
    public let message: String
    public var errorDescription: String? { message + "\nSaved changes remain in stash " + stashHash }
}

extension GitRepository {
    /// Try Git's normal merge first. Only an overwrite refusal permits saving the
    /// worktree and retrying. Never abort a real merge conflict or delete its stash.
    func pullWithRecovery(arguments: [String], environment: [String: String],
                          progress: @escaping @Sendable (String) -> Void) async throws -> NetworkOperationResult {
        try await requirePullReady()
        do {
            let result = try await GitProcess.run(at: url, arguments: arguments, progress: progress, environmentOverrides: environment)
            return NetworkOperationResult(output: pullOutput(result))
        } catch {
            if error is CancellationError { throw error }
            let conflicts = try await status().filter(\.isConflict).map(\.path)
            if !conflicts.isEmpty {
                return NetworkOperationResult(output: GitProgressParser.redact(error.localizedDescription),
                    pullOutcome: PullOperationOutcome(conflicts: conflicts, stashHash: nil, changesRestored: false, restorationError: nil))
            }
            let message = error.localizedDescription.lowercased()
            guard message.contains("would be overwritten by merge") || message.contains("would be overwritten by checkout") else { throw error }
            try await requirePullReady()
            guard !(try await status()).isEmpty else { throw error }
        }

        let previous = try? await workflowRevision("refs/stash")
        try await stash(message: "AuvGit auto-stash before pull")
        let saved = try await workflowRevision("refs/stash")
        guard saved != previous else { throw GitError("No recoverable auto-stash was created; pull stopped.") }
        do {
            var output: String
            do {
                let result = try await GitProcess.run(at: url, arguments: arguments, progress: progress, environmentOverrides: environment)
                output = pullOutput(result)
            } catch {
                if error is CancellationError { throw error }
                let conflicts = try await status().filter(\.isConflict).map(\.path)
                guard !conflicts.isEmpty else { throw error }
                // Do not apply saved work on top of an unresolved committed merge.
                return NetworkOperationResult(output: GitProgressParser.redact(error.localizedDescription),
                    pullOutcome: PullOperationOutcome(conflicts: conflicts, stashHash: saved, changesRestored: false, restorationError: nil))
            }

            // Preserve the original index when possible. Git can reject --index
            // before applying anything; then use a worktree three-way merge so
            // incompatible local edits become ordinary local conflict entries.
            var restored = try await GitProcess.run(at: url, arguments: ["stash", "apply", "--index", saved], allowedCodes: [0, 1, 128])
            if restored.code != 0, try await status().isEmpty {
                restored = try await GitProcess.run(at: url, arguments: ["stash", "apply", saved], allowedCodes: [0, 1, 128])
            }
            output += "\n" + pullOutput(restored)
            let conflicts = try await status().filter(\.isConflict).map(\.path)
            return NetworkOperationResult(output: output,
                pullOutcome: PullOperationOutcome(conflicts: conflicts, stashHash: saved, changesRestored: restored.code == 0,
                    restorationError: restored.code == 0 || !conflicts.isEmpty ? nil : pullOutput(restored)))
        } catch {
            throw PullRecoveryFailure(stashHash: saved, message: GitProgressParser.redact(error.localizedDescription))
        }
    }

    private func requirePullReady() async throws {
        guard !(try await status()).contains(where: \.isConflict) else {
            throw GitError("Resolve the existing local conflicts before pulling.")
        }
        for state in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"] {
            let path = try await workflowRead(["rev-parse", "--git-path", state]).trimmingCharacters(in: .newlines)
            let location = path.hasPrefix("/") ? path : url.appendingPathComponent(path).path
            guard !FileManager.default.fileExists(atPath: location) else {
                throw GitError("Finish the current merge, rebase, cherry-pick or revert before pulling.")
            }
        }
    }

    private func pullOutput(_ output: GitOutput) -> String {
        GitProgressParser.redact(output.text + (output.error.isEmpty ? "" : "\n" + output.error))
    }
}
