import Foundation

public enum RepositoryOperationState: String, Codable, Sendable {
    case merge, rebase
}

/// Git-visible state, excluding ignored build/log activity and transient lock files.
public struct RepositoryChangeState: Equatable, Sendable, Codable {
    public let history: String
    public let operation: RepositoryOperationState?
    public let recreatableConflicts: Set<String>?
    private let index: String
    private let files: [GitFile]
    private let worktree: [String]

    public init(history: String, index: String, files: [GitFile], root: URL, operation: RepositoryOperationState? = nil, recreatableConflicts: Set<String> = []) {
        self.history = history
        self.operation = operation
        self.recreatableConflicts = recreatableConflicts.isEmpty ? nil : recreatableConflicts
        self.index = index
        self.files = files.sorted { $0.path < $1.path }
        worktree = self.files.filter { $0.isUnstaged }.map { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file.path).path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern
            return "\(file.path)\0\(modified.map(String.init) ?? "missing")\0\(String(describing: attributes?[.size]))\0\(String(describing: attributes?[.systemFileNumber]))"
        }
    }
    public func refreshingWorktree(files: [GitFile], root: URL) -> Self {
        Self(history: history, index: index, files: files, root: root, operation: operation, recreatableConflicts: recreatableConflicts ?? [])
    }
}

public extension GitRepository {
    func worktreeChangeState(files: [GitFile], previous: RepositoryChangeState) -> RepositoryChangeState {
        previous.refreshingWorktree(files: files, root: url)
    }

    /// Git's ignore matching preserves tracked files, including tracked files
    /// inside otherwise ignored directories. Never infer this from extensions.
    func relevantWorktreeEvents(_ paths: [String]) async throws -> Bool {
        guard !paths.isEmpty else { return false }
        if paths.count > 512 { return true }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-event-paths-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        try Data((paths.joined(separator: "\0") + "\0").utf8).write(to: input, options: .atomic)
        let output = try await GitProcess.run(at: url, arguments: ["check-ignore", "--stdin", "-z"], allowedCodes: [0, 1], inputFile: input, literalPathspecs: false)
        let ignored = Set(output.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        return paths.contains { !ignored.contains($0) }
    }
    func operationState() async throws -> RepositoryOperationState? {
        let path = try await workflowRead(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .newlines)
        let directory = URL(fileURLWithPath: path)
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appendingPathComponent("rebase-merge").path)
            || manager.fileExists(atPath: directory.appendingPathComponent("rebase-apply/rebasing").path) { return .rebase }
        if manager.fileExists(atPath: directory.appendingPathComponent("MERGE_HEAD").path) { return .merge }
        return nil
    }

    func changeState(files: [GitFile]) async throws -> RepositoryChangeState {
        // show-ref exits 1 for an unborn repository. Other failures must not look
        // like a ref deletion, so retain the allowed exit code explicitly.
        async let refs = GitProcess.run(at: url, arguments: ["--no-optional-locks", "show-ref", "--head"], allowedCodes: [0, 1]).text
        async let head = GitProcess.run(at: url, arguments: ["--no-optional-locks", "symbolic-ref", "--quiet", "HEAD"], allowedCodes: [0, 1]).text
        async let index = workflowRead(["--no-optional-locks", "ls-files", "--stage", "-z"])
        async let tracking = GitProcess.run(at: url, arguments: ["--no-optional-locks", "config", "--local", "--null", "--get-regexp", "^branch\\..*\\.(remote|merge)$"], allowedCodes: [0, 1]).text
        async let stashLogPath = workflowRead(["rev-parse", "--git-path", "logs/refs/stash"])
        async let operation = operationState()
        async let undo = recreatableConflictPaths()
        let trackingText = try await tracking
        let stashPath = try await stashLogPath.trimmingCharacters(in: .newlines)
        let stashURL = stashPath.hasPrefix("/") ? URL(fileURLWithPath: stashPath) : url.appendingPathComponent(stashPath)
        let stashAttributes = try? FileManager.default.attributesOfItem(atPath: stashURL.path)
        let stashIdentity = stashAttributes.map { attributes in
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern
            return "\0stash:\(modified.map(String.init) ?? "missing"):\(String(describing: attributes[.size])):\(String(describing: attributes[.systemFileNumber]))"
        } ?? ""
        return try await RepositoryChangeState(history: head + refs + (trackingText.isEmpty ? "" : "\0" + trackingText) + stashIdentity, index: index, files: files, root: url, operation: operation, recreatableConflicts: undo)
    }

    func recreatableConflictPaths() async throws -> Set<String> {
        let output = try await workflowRead(["--no-optional-locks", "ls-files", "--resolve-undo", "-z"])
        return Set(output.split(separator: "\0").compactMap { record in
            record.firstIndex(of: "\t").map { String(record[record.index(after: $0)...]) }
        })
    }
}
