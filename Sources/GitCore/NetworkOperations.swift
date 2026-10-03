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
        let safe = redact(clean)
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
private final class ProgressLines: @unchecked Sendable {
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

    public func runNetwork(_ operation: NetworkOperation, progress: @escaping @Sendable (NetworkProgress) -> Void) async throws -> NetworkOperationResult {
        let args: [String]
        switch operation {
        case .fetch: args = ["fetch", "--all", "--prune", "--progress"]
        case .pull: args = ["pull", "--ff-only", "--progress"]
        case .pushPreview: args = ["push", "--dry-run", "--porcelain", "--progress"]
        case .push: args = ["push", "--porcelain", "--progress"]
        }
        let lines = ProgressLines(progress)
        let result = try await GitProcess.run(at: url, arguments: args, progress: { lines.accept($0) })
        lines.finish()
        return NetworkOperationResult(output: GitProgressParser.redact(result.text + (result.error.isEmpty ? "" : "\n" + result.error)))
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
