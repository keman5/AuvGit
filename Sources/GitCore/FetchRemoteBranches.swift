import Foundation

public extension GitRepository {
    /// Fetch every head, including branches excluded by a single-branch clone.
    func fetchAllRemoteBranches(remote: String, credential: NetworkCredential? = nil) async throws {
        let refspec = "+refs/heads/*:refs/remotes/" + remote + "/*"
        _ = try await runRemoteBranchCommand(remote: remote, arguments: [
            "fetch", "--atomic", "--progress", "--no-prune", "--no-tags", "--no-recurse-submodules", "--refmap=", "--", remote, refspec
        ], credential: credential)
        // Persist only after a successful fetch so later ordinary fetches include new branches.
        _ = try await workflowRead(["config", "--local", "--replace-all", "remote." + remote + ".fetch", refspec])
    }

    /// Advertised heads absent from this remote's conventional tracking namespace.
    func unfetchedRemoteBranches(remote: String, credential: NetworkCredential? = nil) async throws -> [String] {
        let output = try await runRemoteBranchCommand(remote: remote, arguments: ["ls-remote", "--heads", "--", remote], credential: credential)
        let prefix = "refs/heads/"
        let advertised = output.text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasPrefix(prefix) else { return nil }
            return String(fields[1].dropFirst(prefix.count))
        }
        let trackingPrefix = "refs/remotes/" + remote + "/"
        let tracking = try await workflowRead(["for-each-ref", "--format=%(refname)", trackingPrefix])
        let fetched = Set(tracking.split(separator: "\n").map { String($0.dropFirst(trackingPrefix.count)) })
        return Set(advertised).subtracting(fetched).sorted()
    }

    /// Fetch only the selected heads, then retain their mappings for ordinary future fetches.
    func fetchRemoteBranches(remote: String, branches: [String], credential: NetworkCredential? = nil) async throws {
        guard !branches.isEmpty else { throw GitError("Select at least one remote branch.") }
        let names = Set(branches).sorted()
        for branch in names {
            guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\0"), !branch.contains("\n"), !branch.contains("\r") else { throw GitError("Invalid remote branch") }
            _ = try await workflowRead(["check-ref-format", "refs/heads/" + branch])
        }
        let refspecs = names.map { "+refs/heads/" + $0 + ":refs/remotes/" + remote + "/" + $0 }
        _ = try await runRemoteBranchCommand(remote: remote, arguments: [
            "fetch", "--atomic", "--progress", "--no-prune", "--no-tags", "--no-recurse-submodules", "--refmap=", "--", remote
        ] + refspecs, credential: credential)
        let existing = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "remote." + remote + ".fetch"], allowedCodes: [0, 1]).text
        let mappings = Set(existing.split(separator: "\n").map { $0.hasPrefix("+") ? String($0.dropFirst()) : String($0) })
        let wildcard = "refs/heads/*:refs/remotes/" + remote + "/*"
        if !mappings.contains(wildcard) {
            for refspec in refspecs where !mappings.contains(String(refspec.dropFirst())) {
                _ = try await workflowRead(["config", "--add", "remote." + remote + ".fetch", refspec])
            }
        }
    }

    private func runRemoteBranchCommand(remote: String, arguments: [String], credential: NetworkCredential?) async throws -> GitOutput {
        let remotes = try await workflowRead(["remote"]).split(separator: "\n").map(String.init)
        guard remotes.contains(remote), !remote.hasPrefix("-"), !remote.contains("\0") else { throw GitError("Invalid remote name") }
        let lease: NetworkCredentialLease?
        if let credential {
            lease = try NetworkCredentialLease(endpoint: try await remoteAuthenticationTarget(for: .fetch, remoteName: remote).endpoint, credential: credential)
        } else { lease = nil }
        defer { lease?.remove() }
        return try await GitCommandLog.$privateCredentials.withValue(lease?.privateValues ?? []) {
            try await GitProcess.run(at: url, arguments: (lease?.gitArguments ?? NetworkAuthentication.arguments) + arguments,
                                     environmentOverrides: lease?.environment ?? [:])
        }
    }
}
