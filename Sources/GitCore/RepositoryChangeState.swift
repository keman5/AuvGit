import Foundation

public enum RepositoryOperationState: String, Codable, Sendable {
    case merge, rebase
}

/// Git-visible state, excluding ignored build/log activity and transient lock files.
public struct RepositoryChangeState: Equatable, Sendable, Codable {
    public let history: String
    public let operation: RepositoryOperationState?
    private let index: String
    private let files: [GitFile]
    private let worktree: [String]

    public init(history: String, index: String, files: [GitFile], root: URL, operation: RepositoryOperationState? = nil) {
        self.history = history
        self.operation = operation
        self.index = index
        self.files = files.sorted { $0.path < $1.path }
        worktree = self.files.filter { $0.isUnstaged }.map { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file.path).path)
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern
            return "\(file.path)\0\(modified.map(String.init) ?? "missing")\0\(String(describing: attributes?[.size]))\0\(String(describing: attributes?[.systemFileNumber]))"
        }
    }
}

public extension GitRepository {
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
        async let operation = operationState()
        let trackingText = try await tracking
        return try await RepositoryChangeState(history: head + refs + (trackingText.isEmpty ? "" : "\0" + trackingText), index: index, files: files, root: url, operation: operation)
    }
}
