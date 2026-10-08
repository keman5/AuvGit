import Foundation
import CryptoKit

public enum NetworkOperation: String, CaseIterable, Sendable { case fetch, pull, pushPreview, push }
public struct NetworkProgress: Equatable, Sendable {
    public let message: String
    public let fraction: Double?
}
public enum GitProgressParser {
    public static func parse(_ line: String) -> NetworkProgress? {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let safe = GitCommandLog.redact(clean)
        let regex = try! NSRegularExpression(pattern: #"(\d{1,3})%"#)
        if let match = regex.firstMatch(in: safe, range: NSRange(location: 0, length: safe.utf16.count)), let value = Double((safe as NSString).substring(with: match.range(at: 1))) {
            return NetworkProgress(message: safe, fraction: min(1, max(0, value / 100)))
        }
        return NetworkProgress(message: safe, fraction: nil)
    }
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?:https?|ssh|git)://[^\s]+"#, with: "[remote]", options: .regularExpression)
    }
}
final class ProgressLines: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let callback: @Sendable (NetworkProgress) -> Void
    init(_ callback: @escaping @Sendable (NetworkProgress) -> Void) { self.callback = callback }
    func accept(_ chunk: String) {
        lock.lock()
        pending += chunk
        let pieces = pending.components(separatedBy: CharacterSet.newlines)
        pending = pieces.last ?? ""
        if pending.utf16.count > 65_536 { pending = "" }
        let events = pieces.dropLast().compactMap(GitProgressParser.parse)
        lock.unlock()
        events.forEach(callback)
    }
    func finish() { lock.lock(); let value = pending; pending = ""; lock.unlock(); if let event = GitProgressParser.parse(value) { callback(event) } }
}
public struct NetworkOperationResult: Sendable { public let output: String }
public struct CredentialConfiguration: Sendable {
    public let helpers: [String]
    public let sshAgentAvailable: Bool
}
enum NetworkAuthentication {
    // Command-local configuration leaves repository and global credential settings untouched.
    // Existing helpers are tried first; gh supplies an already signed-in GitHub account.
    static func arguments(ghPath: String?) -> [String] {
        guard let ghPath else { return [] }
        let quoted = "'" + ghPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ["-c", "credential.https://github.com.helper=!\(quoted) auth git-credential"]
    }
    static var arguments: [String] {
        let path = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return arguments(ghPath: path)
    }
}
extension GitRepository {
    /// Hash configuration rather than retaining or displaying remote URLs that can contain credentials.
    public func networkPreviewIdentity() async throws -> String {
        var bytes = Data()
        for arguments in [["show-ref"], ["symbolic-ref", "--quiet", "HEAD"], ["config", "--get-regexp", "^(remote\\..*|branch\\..*|push\\..*)$"]] {
            let output = try await GitProcess.run(at: url, arguments: arguments, allowedCodes: [0, 1])
            bytes.append(output.data); bytes.append(0)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    public func runNetwork(_ operation: NetworkOperation, credential: NetworkCredential? = nil, progress: @escaping @Sendable (NetworkProgress) -> Void) async throws -> NetworkOperationResult {
        let args: [String]
        switch operation {
        case .fetch: args = ["fetch", "--all", "--progress"] + (GitRuntimePreferences.shared.fetchPrune ? ["--prune"] : ["--no-prune"])
        case .pull: args = ["pull", "--ff-only", "--progress"]
        case .pushPreview: args = ["push", "--dry-run", "--porcelain", "--progress"]
        case .push: args = ["push", "--porcelain", "--progress"]
        }
        let lease: NetworkCredentialLease?
        if let credential {
            lease = try NetworkCredentialLease(endpoint: try await remoteAuthenticationTarget(for: operation).endpoint, credential: credential)
        } else { lease = nil }
        defer { lease?.remove() }
        let lines = ProgressLines(progress)
        defer { lines.finish() }
        let result = try await GitCommandLog.$privateCredentials.withValue(lease?.privateValues ?? []) {
            try await GitProcess.run(at: url, arguments: (lease?.gitArguments ?? NetworkAuthentication.arguments) + args,
                                     progress: { lines.accept($0) }, environmentOverrides: lease?.environment ?? [:])
        }
        return NetworkOperationResult(output: GitProgressParser.redact(result.text + (result.error.isEmpty ? "" : "\n" + result.error)))
    }
    /// Poll advertised heads first; fetch changed heads without touching the checked-out branch or worktree.
    public func backgroundFetch() async throws {
        let remotes = try await GitProcess.run(at: url, arguments: ["remote"], timeout: 30, noninteractive: true).text.split(separator: "\n").map(String.init)
        var failure: Error?
        for remote in remotes {
            try Task.checkCancellation()
            do {
                let endpoint = try await GitProcess.run(at: url, arguments: ["remote", "get-url", remote], timeout: 30).text.trimmingCharacters(in: .newlines)
                var sshCommand: String?
                if ["ssh://", "git+ssh://", "ssh+git://"].contains(where: endpoint.hasPrefix) || (!endpoint.contains("://") && !endpoint.hasPrefix("/") && endpoint.contains(":")) {
                    let configured = try await GitProcess.run(at: url, arguments: ["config", "--get", "core.sshCommand"], allowedCodes: [0, 1], timeout: 30).text.trimmingCharacters(in: .newlines)
                    let environment = GitRuntimePreferences.shared.environment(ProcessInfo.processInfo.environment)
                    let ssh = environment["GIT_SSH_COMMAND"] ?? (configured.isEmpty ? (environment["GIT_SSH"] ?? "ssh") : configured)
                    guard let executable = ["ssh", "/usr/bin/ssh", "/opt/homebrew/bin/ssh", "/usr/local/bin/ssh"].first(where: { ssh == $0 || ssh.hasPrefix($0 + " ") }) else {
                        // ponytail: custom SSH wrappers need a noninteractive contract before background use.
                        throw GitError("Background refresh requires a noninteractive SSH command.")
                    }
                    sshCommand = executable + " -oBatchMode=yes" + ssh.dropFirst(executable.count)
                }
                let advertised = try await GitProcess.run(at: url, arguments: NetworkAuthentication.arguments + ["ls-remote", "--heads", "--", remote], timeout: 10, noninteractive: true, sshCommand: sshCommand).text
                let tracking = try await GitProcess.run(at: url, arguments: ["for-each-ref", "--format=%(objectname) %(refname)", "refs/remotes/" + remote + "/"], timeout: 10).text
                let localHeads = Set(tracking.split(separator: "\n").map { line in
                    line.replacingOccurrences(of: " refs/remotes/" + remote + "/", with: " refs/heads/")
                })
                let changed = advertised.split(separator: "\n").contains { line in
                    let fields = line.split(whereSeparator: { $0.isWhitespace })
                    return fields.count == 2 && !localHeads.contains(String(fields[0]) + " " + fields[1])
                }
                guard changed else { continue }
                _ = try await GitProcess.run(at: url, arguments: NetworkAuthentication.arguments + [
                    "fetch", "--quiet", "--no-prune", "--no-prune-tags", "--no-tags", "--no-recurse-submodules",
                    "--no-write-fetch-head", "--no-auto-maintenance", "--refmap=", "--", remote,
                    "+refs/heads/*:refs/remotes/" + remote + "/*"
                ], timeout: 30, noninteractive: true, sshCommand: sshCommand)
            }
            catch { if Task.isCancelled { throw CancellationError() }; failure = error }
        }
        if let failure { throw failure }
    }
    public func credentialConfiguration() async throws -> CredentialConfiguration {
        let result = try await GitProcess.run(at: url, arguments: ["config", "--get-all", "credential.helper"], allowedCodes: [0, 1])
        let helpers = result.text.split(separator: "\n").map { helper -> String in
            let value = helper.trimmingCharacters(in: .whitespaces)
            // Custom helpers may embed secrets. Only expose known names, never shell/helper arguments.
            if ["osxkeychain", "cache", "store", "manager", "manager-core"].contains(value) { return value }
            return "Custom helper"
        }
        let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        return CredentialConfiguration(helpers: helpers, sshAgentAvailable: socket.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    }
    public func configureKeychainHelper() async throws {
        _ = try await GitProcess.run(at: url, arguments: ["config", "--local", "--replace-all", "credential.helper", "osxkeychain"])
    }
}
