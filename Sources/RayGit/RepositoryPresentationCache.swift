import Foundation
import CryptoKit
import GitCore

// Display-only persisted state; validate the repository and refresh before enabling mutations.
struct RepositoryPresentationSnapshot: Codable, Sendable {
    var files: [GitFile] = []
    var branches: [GitBranch] = []
    var branch = ""
    var stashes: [GitStash] = []
    var commits: [GitCommit] = []
    var commitFiles: [GitCommitFile] = []
    var tree: [WorkspaceFileNode]? = nil
    var loadedCount = 0
    var hasMore = false
    var observedState: RepositoryChangeState? = nil
    var historyState: String? = nil
    var mainHistoryHead: String? = nil
    var historyScope: [String]? = nil
    var localUnpushedCommitHashes: Set<String>? = nil
    var diffText = ""
    var diffIdentity: String? = nil
    var diffFilename: String? = nil
    var diffLeft: String? = nil
    var diffRight: String? = nil
    var diffTitle = ""
    var diffArguments: [String] = []
    var workspaceStatusFailure: String? = nil
}

actor RepositoryPresentationCache {
    static let shared = RepositoryPresentationCache()
    private let directory: URL
    private let maximumEntries: Int
    private let maximumBytes: Int
    private(set) var pendingSaves: [String: UUID] = [:]
    private struct Entry: Codable, Sendable {
        let version: Int
        let repository: String
        let snapshot: RepositoryPresentationSnapshot
    }
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RayGit/RepositoryPresentation", isDirectory: true), maximumEntries: Int = 32, maximumBytes: Int = 128 * 1024 * 1024) {
        self.directory = directory
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }
    private func file(for repository: URL) -> URL {
        let hash = SHA256.hash(data: Data(repository.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func load(repository: URL) async -> RepositoryPresentationSnapshot? {
        let file = file(for: repository), byteLimit = maximumBytes
        // A background project decode must not queue foreground reads on this actor.
        return await Task.detached(priority: .userInitiated) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let size = attributes[.size] as? Int, size <= byteLimit,
                  let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.version == 1,
                  entry.repository == repository.standardizedFileURL.path else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return entry.snapshot
        }.value
    }
    func save(_ snapshot: RepositoryPresentationSnapshot, for repository: URL) async throws {
        let file = file(for: repository), version = UUID()
        pendingSaves[file.path] = version
        defer { if pendingSaves[file.path] == version { pendingSaves.removeValue(forKey: file.path) } }
        let entry = Entry(version: 1, repository: repository.standardizedFileURL.path, snapshot: snapshot)
        // Encoding cannot hold up a project read; removals invalidate writes still being encoded.
        let data = try await Task.detached(priority: .utility) { try JSONEncoder().encode(entry) }.value
        guard pendingSaves[file.path] == version else { return }
        guard maximumEntries > 0, data.count <= maximumBytes else {
            try remove(repository: repository)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .map { file in (file, try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var count = files.count, bytes = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (old, values) in files where count > maximumEntries || bytes > maximumBytes {
            try FileManager.default.removeItem(at: old)
            count -= 1; bytes -= values.fileSize ?? 0
        }
    }
    func remove(repository: URL) throws {
        let file = file(for: repository)
        pendingSaves.removeValue(forKey: file.path)
        do { try FileManager.default.removeItem(at: file) }
        catch {
            let error = error as NSError
            if error.domain != NSCocoaErrorDomain || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { throw error }
        }
    }
}
