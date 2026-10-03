import Foundation

/// Git-visible state, excluding ignored build/log activity and transient lock files.
public struct RepositoryChangeState: Equatable, Sendable {
    public let history: String
    private let index: String
    private let files: [GitFile]
    private let worktree: [String]

    public init(history: String, index: String, files: [GitFile], root: URL) {
        self.history = history
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
    func changeState(files: [GitFile]) async throws -> RepositoryChangeState {
        // show-ref exits 1 for an unborn repository. Other failures must not look
        // like a ref deletion, so retain the allowed exit code explicitly.
        let refs = try await GitProcess.run(at: url, arguments: ["--no-optional-locks", "show-ref", "--head"], allowedCodes: [0, 1]).text
        let head = try await GitProcess.run(at: url, arguments: ["--no-optional-locks", "symbolic-ref", "--quiet", "HEAD"], allowedCodes: [0, 1]).text
        let index = try await workflowRead(["--no-optional-locks", "ls-files", "--stage", "-z"])
        return RepositoryChangeState(history: head + refs, index: index, files: files, root: url)
    }
}
