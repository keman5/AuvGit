import Foundation

public struct FirstBranchPushRequest: Identifiable, Sendable {
    public let id = UUID()
    public let branch: String
    public let commit: String
    public let remotes: [String]
    public let remoteBranches: [GitBranch]
}

public extension GitRepository {
    func firstPushRequest() async throws -> FirstBranchPushRequest? {
        let branches = try await branches()
        guard let current = branches.first(where: { $0.isCurrent && !$0.isRemote }) else { return nil }
        if let upstream = current.upstream, branches.contains(where: { $0.isRemote && $0.name == upstream }) { return nil }
        let names = try await workflowRead(["remote"]).split(separator: "\n").map(String.init)
        return FirstBranchPushRequest(branch: current.name, commit: try await workflowRevision("HEAD"),
            remotes: names, remoteBranches: branches.filter(\.isRemote))
    }

    /// Explicit refspec overrides push.default and remote.*.push. Never force a destination.
    func pushFirstBranch(_ request: FirstBranchPushRequest, remote: String, remoteBranch: String,
                         credential: NetworkCredential? = nil) async throws {
        guard try await currentBranch() == request.branch, try await workflowRevision("HEAD") == request.commit,
              let current = try await firstPushRequest(), current.branch == request.branch else {
            throw GitError("The current branch or commit changed. Select the push destination again.")
        }
        guard current.remotes.contains(remote), !remote.hasPrefix("-"), !remoteBranch.hasPrefix("-"),
              !remoteBranch.isEmpty, !remoteBranch.contains("\0"), !remoteBranch.contains("\n") else {
            throw GitError("Invalid push destination")
        }
        _ = try await workflowRead(["check-ref-format", "refs/heads/" + remoteBranch])
        // Refuse configurations that would implicitly force or mirror other refs.
        let mirror = try await GitProcess.run(at: url, arguments: ["config", "--bool", "--get", "remote." + remote + ".mirror"], allowedCodes: [0, 1])
        guard mirror.text.trimmingCharacters(in: .newlines) != "true" else { throw GitError("A mirror remote cannot be used for a single branch push.") }
        let urls = try await workflowRead(["remote", "get-url", "--push", "--all", remote]).split(separator: "\n")
        guard urls.count == 1 else { throw GitError("Select a remote with a single push URL.") }
        let lease: NetworkCredentialLease?
        if let credential { lease = try NetworkCredentialLease(endpoint: try await remoteAuthenticationTarget(for: .push, remoteName: remote).endpoint, credential: credential) }
        else { lease = nil }
        defer { lease?.remove() }
        _ = try await GitCommandLog.$privateCredentials.withValue(lease?.privateValues ?? []) {
            try await GitProcess.run(at: url, arguments: (lease?.gitArguments ?? NetworkAuthentication.arguments) +
                ["push", "--set-upstream", "--porcelain", "--progress", "--", remote,
                 "refs/heads/" + request.branch + ":refs/heads/" + remoteBranch], environmentOverrides: lease?.environment ?? [:])
        }
    }
}
