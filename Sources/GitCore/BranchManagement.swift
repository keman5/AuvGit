import Foundation

public struct BranchDeletionNeedsForce: LocalizedError, Sendable {
    public let name: String
    public let hash: String
    public var errorDescription: String? { "The branch '\(name)' is not fully merged." }
}

public extension GitRepository {
    /// Resolve the selected tracking ref through the configured fetch mapping.
    func remoteBranchDestination(_ reference: String) async throws -> (remote: String, branch: String) {
        guard reference.hasPrefix("refs/remotes/"), !reference.contains("\0"), !reference.contains("\n") else { throw GitError("Invalid remote branch") }
        _ = try await workflowRead(["check-ref-format", reference])
        let symbolic = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "--quiet", reference], allowedCodes: [0, 1])
        guard symbolic.code == 1 else { throw GitError("Cannot delete a symbolic remote reference") }
        _ = try await workflowRevision(reference)
        let remotes = try await workflowRead(["remote"]).split(separator: "\n").map(String.init)
        var matches: [(remote: String, branch: String)] = []
        for remote in remotes {
            let specs = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "remote." + remote + ".fetch"], allowedCodes: [0, 1]).text
            for spec in specs.split(separator: "\n") where !spec.hasPrefix("^") {
                let parts = spec.trimmingCharacters(in: CharacterSet(charactersIn: "+")).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2, parts[0].hasPrefix("refs/heads/") else { continue }
                if let star = parts[1].firstIndex(of: "*"), parts[0].contains("*") {
                    let prefix = String(parts[1][..<star]), suffix = String(parts[1][parts[1].index(after: star)...])
                    guard reference.hasPrefix(prefix), reference.hasSuffix(suffix), reference.count >= prefix.count + suffix.count else { continue }
                    let name = String(reference.dropFirst(prefix.count).dropLast(suffix.count))
                    matches.append((remote, parts[0].replacingOccurrences(of: "*", with: name)))
                } else if parts[1] == reference { matches.append((remote, parts[0])) }
            }
        }
        guard matches.count == 1, let target = matches.first else { throw GitError("Cannot resolve a single remote branch destination") }
        _ = try await workflowRead(["check-ref-format", target.branch])
        return target
    }

    func deleteRemoteBranch(reference: String, credential: NetworkCredential? = nil) async throws {
        let target = try await remoteBranchDestination(reference)
        let urls = try await workflowRead(["remote", "get-url", "--push", "--all", target.remote]).split(separator: "\n")
        guard urls.count == 1 else { throw GitError("Remote branch deletion requires a single push URL") }
        let hash = try await workflowRevision(reference)
        let lease: NetworkCredentialLease?
        if let credential { lease = try NetworkCredentialLease(endpoint: try await remoteAuthenticationTarget(for: .push, remoteName: target.remote).endpoint, credential: credential) }
        else { lease = nil }
        defer { lease?.remove() }
        // Query the push endpoint: fetch and push URLs may refer to different servers.
        _ = try await GitCommandLog.$privateCredentials.withValue(lease?.privateValues ?? []) {
            let authentication = lease?.gitArguments ?? NetworkAuthentication.arguments
            let advertised = try await GitProcess.run(at: url, arguments: authentication +
                ["ls-remote", "--refs", "--", String(urls[0]), target.branch],
                environmentOverrides: lease?.environment ?? [:])
            let serverHash = advertised.text.split(separator: "\n").compactMap { line -> String? in
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                return fields.count == 2 && fields[1] == target.branch ? String(fields[0]) : nil
            }.first
            if serverHash == nil {
                // Already deleted on the server. Remove only the unchanged local tracking ref.
                return try await GitProcess.run(at: url, arguments: ["update-ref", "--no-deref", "-d", reference, hash])
            }
            let changedMessage = "Remote branch changed; fetch updates and confirm deletion again"
            guard serverHash == hash else { throw GitError(changedMessage) }
            // Keep the lease: a commit can still arrive between this read and the push.
            do {
                return try await GitProcess.run(at: url, arguments: authentication +
                    ["push", "--porcelain", "--force-with-lease=" + target.branch + ":" + hash, "--", target.remote, ":" + target.branch],
                    environmentOverrides: lease?.environment ?? [:])
            } catch {
                if error.localizedDescription.lowercased().contains("stale info") {
                    throw GitError(changedMessage + "\n" + error.localizedDescription)
                }
                throw error
            }
        }
    }
}
