import Foundation

public struct GitCommandRecord: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    public let directory: String
    public let command: String
    public let output: String
    public let error: String?
    public let duration: TimeInterval
    public let exitCode: Int32?
    public let operation: String
    public let cancelled: Bool
    public let userInitiated: Bool
    public let operationID: UUID?
    private let archive: GitLogArchive?
    public let previewTruncated: Bool
    public var fullOutputAvailable: Bool { !previewTruncated || archive?.available == true }
    public var fullOutput: String { archive?.read()?.output ?? output }
    public var fullError: String? { archive?.read()?.error ?? error }
    public func fullContents() -> (output: String, error: String?, complete: Bool) {
        guard let contents = archive?.read() else { return (output, error, !previewTruncated) }
        return (contents.output, contents.error, true)
    }
    init(date: Date, directory: String, command: String, output: String, error: String?, duration: TimeInterval, exitCode: Int32?, operation: String, cancelled: Bool = false, userInitiated: Bool = false, operationID: UUID? = nil) {
        self.date = date; self.directory = directory; self.command = command
        self.duration = duration; self.exitCode = exitCode; self.operation = operation; self.cancelled = cancelled; self.userInitiated = userInitiated; self.operationID = operationID
        previewTruncated = output.count > 32_768 || (error?.count ?? 0) > 32_768
        self.output = String(output.prefix(32_768)); self.error = error.map { String($0.prefix(32_768)) }
        archive = previewTruncated ? GitLogArchive(output: output, error: error) : nil
    }
}

/// Files belong to their record and disappear when its final copy is released.
/// A session-wide budget also evicts old archives while records remain visible.
private final class GitLogArchive: @unchecked Sendable {
    struct Contents: Codable { let output: String; let error: String? }
    private static let lock = NSLock()
    private static var files: [(URL, Int)] = {
        let manager = FileManager.default
        let urls = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey])) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("raygit-log-") }.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]) else { return nil }
            if (values.creationDate ?? .distantPast) < Date().addingTimeInterval(-86400) { try? manager.removeItem(at: url); return nil }
            return (url, values.fileSize ?? 0)
        }
    }()
    private static let budget = 64 * 1024 * 1024
    private let url: URL
    init?(output: String, error: String?) {
        guard let data = try? JSONEncoder().encode(Contents(output: output, error: error)), data.count <= Self.budget else { return nil }
        url = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-log-" + UUID().uuidString)
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.files.removeAll { !FileManager.default.fileExists(atPath: $0.0.path) }
        while Self.files.reduce(data.count, { $0 + $1.1 }) > Self.budget || Self.files.count >= 200 {
            let oldest = Self.files.removeFirst(); try? FileManager.default.removeItem(at: oldest.0)
        }
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil }
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.write(contentsOf: data)
        }
        catch { try? FileManager.default.removeItem(at: url); return nil }
        Self.files.append((url, data.count))
    }
    var available: Bool { FileManager.default.fileExists(atPath: url.path) }
    func read() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }
    deinit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try? FileManager.default.removeItem(at: url); Self.files.removeAll { $0.0 == url }
    }
}
public enum GitCommandLog {
    @TaskLocal public static var suppressRoutineReads = false
    @TaskLocal public static var userInitiated = false
    @TaskLocal public static var operationID: UUID?
    @TaskLocal public static var progress: (@Sendable (NetworkProgress) -> Void)?
    public static let notification = Notification.Name("RayGitCommandCompleted")
    public static func userOperation(directory: URL, name: String, started: Date, error: String? = nil, cancelled: Bool = false, operationID: UUID? = nil) -> GitCommandRecord {
        GitCommandRecord(date: started, directory: directory.path, command: "",
                         output: cancelled ? "Cancelled" : "", error: error.map(redact),
                         duration: Date().timeIntervalSince(started), exitCode: nil, operation: redact(name), cancelled: cancelled, userInitiated: true, operationID: operationID)
    }
    public static func applicationFailure(directory: URL?, message: String) -> GitCommandRecord {
        GitCommandRecord(date: Date(), directory: directory?.path ?? "", command: "",
                         output: "", error: redact(message), duration: 0, exitCode: nil, operation: "Application operation")
    }
    public static func redact(_ value: String) -> String {
        var text = value.replacingOccurrences(of: #"(?:https?|ssh|git)://[^\s]+"#, with: "[remote]", options: .regularExpression)
        for pattern in [#"(?i)(authorization:\s*(?:bearer|basic)\s+)\S+"#, #"(?i)((?:password|token|secret|access_token)=)[^\s&]+"#, #"(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)"#] {
            text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return text
    }
    static func record(directory: URL, executable: String, arguments: [String], output: String, error: String?, exitCode: Int32?, started: Date) {
        var safeArguments: [String] = []
        var hideNext = false
        var configCommand = false
        var configKeySeen = false
        var operation = "git"
        for argument in arguments {
            if configCommand {
                if argument.hasPrefix("-") || !configKeySeen { safeArguments.append(String(redact(argument).prefix(32_768))); if !argument.hasPrefix("-") { configKeySeen = true } }
                else { safeArguments.append("[configuration value]") }
                continue
            }
            if hideNext { safeArguments.append("[configuration]"); hideNext = false; continue }
            safeArguments.append(String(redact(argument).prefix(32_768))); if argument == "-c" { hideNext = true }
            if operation == "git", !argument.hasPrefix("-") { operation = redact(argument) }
            if argument == "config" || argument == "credential" { configCommand = true }
        }
        let sensitive = arguments.contains("credential") || arguments.contains("config")
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let record = GitCommandRecord(date: started, directory: directory.path,
            command: ([executable] + safeArguments).map(quote).joined(separator: " "),
            output: sensitive ? "[configuration output omitted]" : redact(output),
            error: sensitive ? error.map { _ in "[configuration error omitted]" } : error.map(redact), duration: Date().timeIntervalSince(started), exitCode: exitCode, operation: operation, userInitiated: userInitiated, operationID: operationID)
        NotificationCenter.default.post(name: notification, object: record)
    }
}
public enum GitFailureSummary {
    public static func message(for message: String, localize: (String) -> String) -> String? {
        guard let key = key(for: message) else { return nil }
        let summary = localize(key)
        guard key == "Remote rejected the push" else { return summary }
        let lines = GitCommandLog.redact(message).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let remote = lines.filter { $0.lowercased().hasPrefix("remote:") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Enumerating objects:") && !$0.hasPrefix("Counting objects:") && !$0.hasPrefix("Compressing objects:") && !$0.hasPrefix("Total ") && !$0.hasPrefix("Resolving deltas:") }
        let reasons = remote.isEmpty ? lines.filter { $0.lowercased().contains("[remote rejected]") }
            : remote.filter { $0.lowercased().hasPrefix("error:") } + remote.filter { !$0.lowercased().hasPrefix("error:") }
        return summary + ": " + reasons.joined(separator: " · ")
    }
    public static func key(for message: String) -> String? {
        let text = message.lowercased()
        if text.contains("finish or abort the active git operation before resetting") { return "Finish or abort the active Git operation before resetting" }
        if text.contains("repository or head changed. reopen the reset confirmation.") { return "Repository or HEAD changed. Reopen the reset confirmation." }
        if text.contains("stale info") { return "Remote changed; preview and confirm force push again" }
        if text.contains("branch or push configuration changed") { return "Branch or push configuration changed; preview and confirm force push again" }
        if text.contains("[remote rejected]") || text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("remote: error:") }) { return "Remote rejected the push" }
        if text.contains("ssl certificate") || text.contains("certificate verify failed") || text.contains("certificate verification failed") || text.contains("ssl connect error") || text.contains("tls handshake") { return "TLS certificate verification failed" }
        if text.contains("proxy authentication") || text.contains("could not resolve proxy") || text.contains("failed to connect to proxy") || text.contains("proxy connect aborted") || text.contains("http code 407") { return "Proxy connection or authentication failed" }
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") { return "SSH host key verification failed" }
        if text.contains("failed to sign") || text.contains("gpg failed") || text.contains("signing failed") { return "Commit signing failed" }
        if text.contains("hook declined") || text.contains("hook failed") || text.contains("pre-commit") || text.contains("pre-receive") { return "Git hook rejected the operation" }
        if text.contains("git-lfs") || text.contains("git lfs") { return "Git LFS operation failed" }
        if text.contains("no space left") || text.contains("disk full") { return "Disk is full" }
        if text.contains("not a git repository") { return "Not a Git repository" }
        if text.contains("could not read username") || text.contains("authentication failed") || text.contains("askpass") { return "Authentication required" }
        if text.contains("permission denied (publickey)") { return "SSH authentication failed" }
        if text.contains("no upstream branch") || text.contains("no tracking information") { return "No upstream branch configured" }
        if text.contains("non-fast-forward") || text.contains("fetch first") || text.contains("not possible to fast-forward") { return "Remote and local branches have diverged" }
        if text.contains("could not resolve host") || text.contains("unable to access") || text.contains("connection refused") { return "Cannot connect to remote" }
        if text.contains("would be overwritten") { return "Local changes would be overwritten" }
        if text.contains("index.lock") { return "Repository is locked by another Git operation" }
        if text.contains("timed out") { return "Git operation timed out" }
        if text.contains("repository not found") { return "Remote repository unavailable" }
        if text.contains("unknown revision") || text.contains("bad revision") || text.contains("not a valid object") || text.contains("needed a single revision") || text.contains("pathspec") { return "Revision or path not found" }
        if text.contains("unable to auto-detect email") || text.contains("author identity unknown") || text.contains("empty ident") { return "Git author identity is not configured" }
        if text.contains("unmerged") || text.contains("resolve your current index") || text.contains("merge conflict") { return "Resolve conflicts before continuing" }
        if text.contains("permission denied") || text.contains("operation not permitted") || text.contains("read-only file system") { return "Permission denied" }
        return nil
    }
}
