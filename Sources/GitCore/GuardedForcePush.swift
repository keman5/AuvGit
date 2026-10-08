import Foundation
import CryptoKit

public struct ForcePushPreview: Sendable {
    public let remote: String
    public let remoteBranch: String
    public let localCommit: String
    public let remoteCommit: String
    public let remoteOnlyCount: Int?
    fileprivate let repository: URL
    fileprivate let localBranch: String
    fileprivate let endpoint: String
    fileprivate let configuration: String
    fileprivate let trackingRef: String?
}
public enum ForcePushPreparationError: LocalizedError, Sendable {
    case notRequired
    case unsupportedForce(String)
    public var errorDescription: String? {
        switch self { case .notRequired: return "No guarded force-push confirmation is needed."
        case let .unsupportedForce(message): return message }
    }
}
public enum ForcePushRejection {
    public static func isNonFastForward(_ error: Error) -> Bool { matches(error.localizedDescription) }
    static func matches(_ text: String) -> Bool {
        let value = text.lowercased()
        return value.contains("[rejected]") && (value.contains("non-fast-forward") || value.contains("fetch first"))
    }
}
public enum LocalNetworkPreflight: Sendable {
    case pushBehind(remote: String, branch: String, remoteOnlyCount: Int)
    case pullDiverged(remoteOnlyCount: Int, localOnlyCount: Int)
}
public extension GitRepository {
    /// Advisory only: tracking refs describe the last fetch, never a force-push lease.
    func localNetworkPreflight(_ operation: NetworkOperation) async throws -> LocalNetworkPreflight? {
        if operation == .pull {
            let upstream = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", "@{upstream}"], allowedCodes: [0, 128])
            guard upstream.code == 0 else { return nil }
            let counts = try await GitProcess.run(at: url, arguments: ["rev-list", "--left-right", "--count", "HEAD..." + upstream.text.trimmingCharacters(in: .newlines)])
            let values = counts.text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            guard values.count == 2, values[0] > 0, values[1] > 0 else { return nil }
            return .pullDiverged(remoteOnlyCount: values[1], localOnlyCount: values[0])
        }
        guard operation == .push || operation == .pushPreview,
              let target = try await localPushTarget() else { return nil }
        let count = try await localRemoteOnlyCount(reference: target.tracking)
        guard let count, count > 0 else { return nil }
        return .pushBehind(remote: target.remote, branch: String(target.reference.dropFirst("refs/heads/".count)), remoteOnlyCount: count)
    }
    /// A dry run lets Git resolve push.default, pushRemote, refspecs and destination names.
    /// Only a single rejected current-branch update may become a confirmation preview.
    func prepareForcePush() async throws -> ForcePushPreview {
        guard let preview = try await preparePush() else { throw ForcePushPreparationError.notRequired }
        return preview
    }
    /// Resolves and validates the destination with one dry run; nil means an ordinary push is ready.
    func preparePush() async throws -> ForcePushPreview? {
        do { return try await preparedForcePush() }
        catch let error as ForcePushPreparationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw ForcePushPreparationError.unsupportedForce(error.localizedDescription) }
    }
    private func preparedForcePush() async throws -> ForcePushPreview? {
        try Task.checkCancellation()
        let branch = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "--quiet", "HEAD"], allowedCodes: [0, 1])
        guard branch.code == 0 else { throw GitError("Force push requires a checked-out local branch.") }
        let localBranch = branch.text.trimmingCharacters(in: .newlines)
        let localCommit = try await workflowRevision("HEAD")
        let configuration = try await forcePushConfigurationIdentity()
        let shortBranch = String(localBranch.dropFirst("refs/heads/".count))
        let remote = try await configuredPushRemote(branch: shortBranch)
        let configuredSpecs = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "remote." + remote + ".push"], allowedCodes: [0, 1])
        let mirror = try await configurationValue("remote." + remote + ".mirror")
        let configuredForce = configuredSpecs.text.split(separator: "\n").contains { $0.hasPrefix("+") } || mirror == "true"
        var verifiedRemoteCommit: String?
        var verifiedReference: String?
        if let target = try await localPushTarget(), target.remote == remote,
           let count = try await localRemoteOnlyCount(reference: target.tracking), count > 0 {
            let advertised = try await advertisedBranch(endpoint: target.endpoint, reference: target.reference)
            if !advertised.isEmpty, let freshCount = try await localRemoteOnlyCount(reference: advertised), freshCount > 0 {
                verifiedRemoteCommit = advertised
                verifiedReference = target.reference
            }
        }
        // A known rejection only needs a fresh advertisement for its exact lease.
        // Complex mappings and unknown remote objects still let Git resolve the push.
        let dryRun: GitOutput
        if verifiedReference != nil { dryRun = GitOutput(data: Data(), error: "", code: 0) }
        else { dryRun = try await GitProcess.run(at: url, arguments: NetworkAuthentication.arguments + ["push", "--dry-run", "--porcelain", "--progress"], allowedCodes: [0, 1, 128]) }
        let rows = verifiedReference.map { [["!", localBranch + ":" + $0, "[rejected] (non-fast-forward)"]] } ?? dryRun.text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }.filter { $0.count == 3 && $0[0].count == 1 }
        let forcedIntent = configuredForce || rows.contains { $0[0] == "+" || $0[0] == "-" }
        let rejected = rows.contains { $0[0] == "!" && ForcePushRejection.matches($0[2]) }
        guard forcedIntent || rejected else {
            guard dryRun.code == 0 else { throw ForcePushPreparationError.unsupportedForce(GitProgressParser.redact(dryRun.error.isEmpty ? dryRun.text : dryRun.error)) }
            return nil
        }
        guard rows.count == 1, rows[0][0] != "-", !rows[0][2].contains("[remote rejected]"),
              forcedIntent || (rows[0][0] == "!" && ForcePushRejection.matches(rows[0][2])) else {
            throw ForcePushPreparationError.unsupportedForce("Force push cannot confirm multiple or unsupported push targets.")
        }
        let pair = rows[0][1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard pair.count == 2, pair[0] == localBranch, pair[1].hasPrefix("refs/heads/") else {
            throw ForcePushPreparationError.unsupportedForce("The push destination is ambiguous or does not update the current branch.")
        }
        let endpoints = try await GitProcess.run(at: url, arguments: ["remote", "get-url", "--push", "--all", remote]).text.split(separator: "\n").map(String.init)
        guard endpoints.count == 1, let endpoint = endpoints.first, !endpoint.hasPrefix("-") else {
            throw ForcePushPreparationError.unsupportedForce("Force push requires exactly one push endpoint.")
        }
        let remoteCommit: String
        if let verifiedRemoteCommit { remoteCommit = verifiedRemoteCommit }
        else { remoteCommit = try await advertisedBranch(endpoint: endpoint, reference: pair[1]) }
        guard !remoteCommit.isEmpty else { throw GitError("The rejected remote branch no longer exists. Preview the push again.") }
        var count: Int?
        if (try await GitProcess.run(at: url, arguments: ["cat-file", "-e", remoteCommit + "^{commit}"], allowedCodes: [0, 1, 128])).code == 0 {
            let output = try await GitProcess.run(at: url, arguments: ["rev-list", "--count", localCommit + ".." + remoteCommit])
            count = Int(output.text.trimmingCharacters(in: .newlines))
        }
        guard configuration == (try await forcePushConfigurationIdentity()), localCommit == (try await workflowRevision("HEAD")) else {
            throw GitError("The branch or push configuration changed. Preview the push again.")
        }
        let tracking = try await GitProcess.run(at: url, arguments: ["for-each-ref", "--format=%(push)", localBranch])
        let trackingName = tracking.text.trimmingCharacters(in: .newlines)
        return ForcePushPreview(remote: remote, remoteBranch: pair[1], localCommit: localCommit, remoteCommit: remoteCommit,
                                remoteOnlyCount: count, repository: url, localBranch: localBranch, endpoint: endpoint, configuration: configuration, trackingRef: trackingName.hasPrefix("refs/remotes/") ? trackingName : nil)
    }
    /// Sends the pinned commit to one pinned endpoint/ref; the lease is checked atomically by Git.
    func forcePush(_ preview: ForcePushPreview, progress: @escaping @Sendable (NetworkProgress) -> Void) async throws -> NetworkOperationResult {
        try Task.checkCancellation()
        let branch = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "--quiet", "HEAD"], allowedCodes: [0, 1])
        guard preview.repository == url, branch.text.trimmingCharacters(in: .newlines) == preview.localBranch,
              preview.localCommit == (try await workflowRevision("HEAD")),
              preview.configuration == (try await forcePushConfigurationIdentity()) else {
            throw GitError("The branch or push configuration changed after confirmation. Preview the push again.")
        }
        var previousTracking: String?
        if let ref = preview.trackingRef {
            let value = try await GitProcess.run(at: url, arguments: ["rev-parse", "--verify", ref], allowedCodes: [0, 128])
            previousTracking = value.code == 0 ? value.text.trimmingCharacters(in: .newlines) : ""
        }
        let result = try await GitProcess.run(at: url, arguments: NetworkAuthentication.arguments + [
            "push", "--porcelain", "--progress", "--no-follow-tags", "--recurse-submodules=no",
            "--force-with-lease=" + preview.remoteBranch + ":" + preview.remoteCommit,
            preview.endpoint, preview.localCommit + ":" + preview.remoteBranch
        ], progress: { chunk in if let value = GitProgressParser.parse(chunk) { progress(value) } })
        if let ref = preview.trackingRef, let previousTracking {
            // URL-pinned pushes do not update tracking refs themselves. Compare-and-swap
            // preserves any concurrent fetch update while reflecting this successful push.
            _ = try? await GitProcess.run(at: url, arguments: ["update-ref", ref, preview.localCommit, previousTracking], allowedCodes: [0, 1, 128])
        }
        return NetworkOperationResult(output: GitProgressParser.redact(result.text + "\n" + result.error))
    }
}
private extension GitRepository {
    func localRemoteOnlyCount(reference: String) async throws -> Int? {
        let count = try await GitProcess.run(at: url, arguments: ["rev-list", "--count", "HEAD.." + reference], allowedCodes: [0, 128])
        return count.code == 0 ? Int(count.text.trimmingCharacters(in: .newlines)) : nil
    }
    func localPushTarget() async throws -> (remote: String, reference: String, tracking: String, endpoint: String)? {
        let head = try await GitProcess.run(at: url, arguments: ["symbolic-ref", "--quiet", "HEAD"], allowedCodes: [0, 1])
        guard head.code == 0 else { return nil }
        let branch = String(head.text.trimmingCharacters(in: .newlines).dropFirst("refs/heads/".count))
        guard let remote = try? await configuredPushRemote(branch: branch),
              try await configurationValue("remote." + remote + ".push") == nil,
              try await configurationValue("remote." + remote + ".mirror") == nil,
              try await configurationValue("push.followTags") == nil else { return nil }
        let mode = try await configurationValue("push.default") ?? "simple"
        let upstreamRemote = try await configurationValue("branch." + branch + ".remote")
        let merge = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "branch." + branch + ".merge"], allowedCodes: [0, 1])
        let upstreamRefs = merge.text.split(separator: "\n").map(String.init)
        let reference: String
        switch mode {
        case "current": reference = "refs/heads/" + branch
        case "simple":
            guard upstreamRemote != nil else { return nil }
            if remote == upstreamRemote {
                guard upstreamRefs == ["refs/heads/" + branch] else { return nil }
            }
            reference = "refs/heads/" + branch
        case "upstream", "tracking":
            guard remote == upstreamRemote, upstreamRefs.count == 1, upstreamRefs[0].hasPrefix("refs/heads/") else { return nil }
            reference = upstreamRefs[0]
        default: return nil
        }
        let fetchSpecs = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "remote." + remote + ".fetch"], allowedCodes: [0, 1])
        guard fetchSpecs.text.split(separator: "\n").map(String.init) == ["+refs/heads/*:refs/remotes/" + remote + "/*"] else { return nil }
        let fetchURLs = try await GitProcess.run(at: url, arguments: ["remote", "get-url", "--all", remote]).text.split(separator: "\n").map(String.init)
        let pushURLs = try await GitProcess.run(at: url, arguments: ["remote", "get-url", "--push", "--all", remote]).text.split(separator: "\n").map(String.init)
        guard pushURLs.count == 1, pushURLs == fetchURLs, let endpoint = pushURLs.first, !endpoint.hasPrefix("-") else { return nil }
        return (remote, reference, "refs/remotes/" + remote + "/" + reference.dropFirst("refs/heads/".count), endpoint)
    }
    func configurationValue(_ key: String) async throws -> String? {
        let value = try await GitProcess.run(at: url, arguments: ["config", "--get", key], allowedCodes: [0, 1])
        return value.code == 0 ? value.text.trimmingCharacters(in: .newlines) : nil
    }
    func configuredPushRemote(branch: String) async throws -> String {
        let branchRemote = try await configurationValue("branch." + branch + ".pushRemote")
        let defaultRemote = try await configurationValue("remote.pushDefault")
        let upstreamRemote = try await configurationValue("branch." + branch + ".remote")
        let names = try await GitProcess.run(at: url, arguments: ["remote"]).text.split(separator: "\n").map(String.init)
        let remote = branchRemote ?? defaultRemote ?? upstreamRemote ?? (names.count == 1 ? names[0] : "origin")
        guard names.contains(remote), !remote.hasPrefix("-") else { throw GitError("Cannot resolve a single configured push remote.") }
        return remote
    }
    func advertisedBranch(endpoint: String, reference: String) async throws -> String {
        let output = try await GitProcess.run(at: url, arguments: NetworkAuthentication.arguments + ["ls-remote", "--heads", endpoint, reference])
        let rows = output.text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1] == reference else { return nil }
            let oid = String(fields[0])
            return [40, 64].contains(oid.count) && oid.allSatisfy(\.isHexDigit) ? oid : nil
        }
        guard rows.count <= 1 else { throw GitError("The remote branch advertisement is ambiguous.") }
        return rows.first ?? ""
    }
    func forcePushConfigurationIdentity() async throws -> String {
        let output = try await GitProcess.run(at: url, arguments: ["config", "--null", "--list"], allowedCodes: [0, 1])
        return SHA256.hash(data: output.data).map { String(format: "%02x", $0) }.joined()
    }
}
