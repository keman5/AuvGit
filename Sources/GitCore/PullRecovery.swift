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
    /// Carry local changes through fast-forwards before saving dirty rebase input.
    /// Retain a recovery stash only while changes are unresolved or unrestored.
    func pullWithRecovery(arguments: [String], environment: [String: String],
                          fetchArguments: [String] = ["fetch", "--progress"],
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
            let dirtyRebase = message.contains("cannot pull with rebase") &&
                (message.contains("unstaged changes") || message.contains("index contains uncommitted changes"))
            guard dirtyRebase || message.contains("would be overwritten by merge") || message.contains("would be overwritten by checkout") else { throw error }
            try await requirePullReady()
            guard !(try await status()).isEmpty else { throw error }
            if dirtyRebase, let pullIndex = arguments.firstIndex(of: "pull") {
                // Git rejects dirty rebase input before contacting the remote.
                // Verify access before moving the user's changes into a stash.
                _ = try await GitProcess.run(at: url, arguments: Array(arguments[..<pullIndex]) + fetchArguments,
                    progress: progress, environmentOverrides: environment)
                do {
                    // A rebase rejects all tracked edits, even when the fetched
                    // update can carry them through a fast-forward unchanged.
                    let result = try await GitProcess.run(at: url,
                        arguments: ["merge", "--ff-only", "--no-autostash", "--no-edit", "--progress", "FETCH_HEAD"],
                        progress: progress, environmentOverrides: environment)
                    return NetworkOperationResult(output: pullOutput(result))
                } catch {
                    if error is CancellationError { throw error }
                    let message = error.localizedDescription.lowercased()
                    guard message.contains("not possible to fast-forward") ||
                            message.contains("would be overwritten by merge") ||
                            message.contains("would be overwritten by checkout") else { throw error }
                    try await requirePullReady()
                }
            }
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
                // Do not apply saved work on top of an unresolved rebase.
                return NetworkOperationResult(output: GitProgressParser.redact(error.localizedDescription),
                    pullOutcome: PullOperationOutcome(conflicts: conflicts, stashHash: saved, changesRestored: false, restorationError: nil))
            }

            // Preserve the original index when possible. Git can reject --index
            // before applying anything; then use a worktree three-way merge so
            // incompatible local edits become ordinary local conflict entries.
            let restoration = try await pullRestorationRevision(for: saved)
            var restored = try await GitProcess.run(at: url, arguments: ["stash", "apply", "--index", restoration], allowedCodes: [0, 1, 128])
            if restored.code != 0, try await status().isEmpty {
                restored = try await GitProcess.run(at: url, arguments: ["stash", "apply", restoration], allowedCodes: [0, 1, 128])
            }
            output += "\n" + pullOutput(restored)
            let conflicts = try await status().filter(\.isConflict).map(\.path)
            if restored.code == 0, conflicts.isEmpty {
                // Resolve the exact saved object rather than assuming stash@{0}
                // still refers to this operation's temporary copy.
                if let recovery = try await stashes().first(where: { $0.hash == saved }) {
                    try await dropStashes([recovery])
                }
                return NetworkOperationResult(output: output,
                    pullOutcome: PullOperationOutcome(conflicts: [], stashHash: nil, changesRestored: true, restorationError: nil))
            }
            return NetworkOperationResult(output: output,
                pullOutcome: PullOperationOutcome(conflicts: conflicts, stashHash: saved, changesRestored: restored.code == 0,
                    restorationError: restored.code == 0 || !conflicts.isEmpty ? nil : pullOutput(restored)))
        } catch {
            throw PullRecoveryFailure(stashHash: saved, message: GitProgressParser.redact(error.localizedDescription))
        }
    }

    /// A reset can leave a formerly tracked file untracked, then pull delivers
    /// that exact file again. Exclude only verified duplicates from the temporary
    /// restoration object; keep the original stash intact until apply succeeds.
    private func pullRestorationRevision(for saved: String) async throws -> String {
        let parents = try await workflowRead(["show", "-s", "--format=%T %P", saved])
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard parents.count == 4 else { return saved }
        let listing = try await GitProcess.run(at: url, arguments: ["ls-tree", "-r", "-z", parents[3]])
        var duplicates: [String] = []
        for entry in listing.data.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 9) else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3 else { continue }
            let path = String(decoding: entry[entry.index(after: tab)...], as: UTF8.self)
            let indexed = try await historyComparisonContent(endpoint: .index, path: path)
            guard indexed.gitMode == String(fields[0]), indexed.objectID == String(fields[2]), let data = indexed.data else { continue }
            let working = try await historyComparisonContent(endpoint: .workingTree, path: path)
            guard indexed.gitMode == working.gitMode, data == working.data else { continue }
            duplicates.append(path)
        }
        guard !duplicates.isEmpty else { return saved }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-pull-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("paths")
        try Data((duplicates.joined(separator: "\0") + "\0").utf8).write(to: input)
        let environment = ["GIT_INDEX_FILE": directory.appendingPathComponent("index").path]
        _ = try await GitProcess.run(at: url, arguments: ["read-tree", parents[3]], environmentOverrides: environment)
        _ = try await GitProcess.run(at: url, arguments: ["update-index", "--force-remove", "-z", "--stdin"], inputFile: input, environmentOverrides: environment)
        let tree = try await GitProcess.run(at: url, arguments: ["write-tree"], environmentOverrides: environment).text.trimmingCharacters(in: .newlines)
        var arguments = ["-c", "commit.gpgsign=false", "commit-tree", parents[0], "-p", parents[1], "-p", parents[2]]
        if duplicates.count != listing.data.split(separator: 0).count {
            let untracked = try await workflowRead(["-c", "commit.gpgsign=false", "commit-tree", tree, "-m", "AuvGit remaining untracked pull recovery"])
                .trimmingCharacters(in: .newlines)
            arguments += ["-p", untracked]
        }
        arguments += ["-m", "AuvGit pull restoration"]
        return try await workflowRead(arguments).trimmingCharacters(in: .newlines)
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
