import Foundation

public struct MissingRemoteUpstream: Sendable {
    public let localBranch: String
    public let remote: String
    public let mergeRef: String
    public let availableBranches: [String]
    public var trackingBranch: String { remote + "/" + mergeRef.dropFirst("refs/heads/".count) }
}

public struct FetchOperationOutcome: Sendable {
    public let addedBranches: [String]
    public let updatedBranches: [String]
    public let prunedBranches: [String]
    public let missingUpstream: MissingRemoteUpstream?
    /// Fetch succeeded, but a later upstream check could not complete.
    public let upstreamCheckFailure: String?
}

extension GitRepository {
    func fetchTrackingSnapshot(remote: String? = nil) async throws -> [String: String] {
        let prefix = "refs/remotes/" + (remote.map { $0 + "/" } ?? "")
        let output = try await workflowRead(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)", prefix])
        return Dictionary(uniqueKeysWithValues: output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[2].isEmpty else { return nil }
            return (String(fields[0].dropFirst("refs/remotes/".count)), String(fields[1]))
        })
    }

    func fetchOutcome(before: [String: String], remote: String? = nil, credential: NetworkCredential?) async throws -> FetchOperationOutcome {
        let after = try await fetchTrackingSnapshot(remote: remote)
        var missing: MissingRemoteUpstream?, checkFailure: String?
        do {
            let head = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], allowedCodes: [0, 1])
            if head.code == 0 {
                let branch = head.text.trimmingCharacters(in: .newlines)
                let configuredRemote = try await upstreamConfiguration(branch: branch, field: "remote")
                let merged = try await upstreamConfiguration(branch: branch, field: "merge").split(separator: "\n").map(String.init)
                let remotes = try await workflowRead(["remote"]).split(separator: "\n").map(String.init)
                if let trackedRemote = configuredRemote.split(separator: "\n").first.map(String.init),
                   remotes.contains(trackedRemote), remote == nil || remote == trackedRemote,
                   merged.count == 1, let merge = merged.first, merge.hasPrefix("refs/heads/") {
                    // A retained tracking ref is not evidence that the branch still exists.
                    // Query only the current upstream's remote, with the same credential scope.
                    let advertised = try await runRemoteBranchCommand(remote: trackedRemote,
                        arguments: ["ls-remote", "--heads", "--", trackedRemote], credential: credential)
                    let prefix = "refs/heads/"
                    let names = advertised.text.split(separator: "\n").compactMap { line -> String? in
                        let fields = line.split(whereSeparator: { $0.isWhitespace })
                        guard fields.count == 2, fields[1].hasPrefix(prefix) else { return nil }
                        return String(fields[1].dropFirst(prefix.count))
                    }
                    if !names.contains(String(merge.dropFirst(prefix.count))) {
                        missing = MissingRemoteUpstream(localBranch: branch, remote: trackedRemote, mergeRef: merge,
                            availableBranches: names.map { trackedRemote + "/" + $0 }.filter { after[$0] != nil }.sorted())
                    }
                }
            }
        } catch {
            if error is CancellationError { throw error }
            checkFailure = GitCommandLog.redact(error.localizedDescription)
        }
        return FetchOperationOutcome(addedBranches: after.keys.filter { before[$0] == nil }.sorted(),
            updatedBranches: after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.sorted(),
            prunedBranches: before.keys.filter { after[$0] == nil }.sorted(),
            missingUpstream: missing, upstreamCheckFailure: checkFailure)
    }

    public func repairUpstream(_ expected: MissingRemoteUpstream, trackingBranch: String) async throws {
        let branch = try await currentBranch()
        let remote = try await upstreamConfiguration(branch: expected.localBranch, field: "remote")
        let merge = try await upstreamConfiguration(branch: expected.localBranch, field: "merge")
        guard branch == expected.localBranch, remote == expected.remote, merge == expected.mergeRef else {
            throw GitError("Branch or upstream changed. Fetch again before setting a tracking branch.")
        }
        guard expected.availableBranches.contains(trackingBranch) else { throw GitError("Invalid remote branch") }
        try await setUpstream(branch: expected.localBranch, remoteBranch: "refs/remotes/" + trackingBranch)
    }

    private func upstreamConfiguration(branch: String, field: String) async throws -> String {
        try await GitProcess.run(at: url, arguments: ["config", "--get-all", "branch." + branch + "." + field],
            allowedCodes: [0, 1]).text.trimmingCharacters(in: .newlines)
    }
}
