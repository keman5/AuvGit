import XCTest
@testable import AuvGit
@testable import GitCore

final class RepositoryPresentationCacheTests: XCTestCase {
    func testPresentationRoundTripDoesNotWriteToRepository() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("not-created/repository")
        let directory = root.appendingPathComponent("cache")
        let cache = RepositoryPresentationCache(directory: directory)
        let file = GitFile(path: "file.txt", originalPath: "old.txt", indexStatus: "R", worktreeStatus: "M")
        let commit = GitCommit(hash: "abc", parents: ["def"], author: "Test", date: Date(timeIntervalSince1970: 100), subject: "Subject", body: "Body", refs: ["main"])
        let state = RepositoryChangeState(history: "history", index: "index", files: [file], root: repository)
        let snapshot = RepositoryPresentationSnapshot(files: [file], branches: [.init(name: "main", isCurrent: true, isRemote: false)], branch: "main",
            stashes: [.init(ref: "stash@{0}", subject: "Saved", hash: "stash-hash")], commits: [commit], commitFiles: [.init(path: "file.txt", status: "M")],
            tree: [.init(path: "folder", isDirectory: true, children: [.init(path: "folder/file.txt", isDirectory: false, children: [])])],
            loadedCount: 1, hasMore: true, observedState: state, historyState: "history", mainHistoryHead: "abc", historyScope: ["scope"],
            localUnpushedCommitHashes: ["abc"], diffText: "diff preview", diffIdentity: "identity", diffFilename: "file.txt", diffLeft: "HEAD", diffRight: "Working Tree", diffTitle: "Changes", diffArguments: ["file.txt"])
        try await cache.save(snapshot, for: repository)
        let result = await cache.load(repository: repository)
        let loaded = try XCTUnwrap(result)
        XCTAssertEqual(loaded.files, [file]); XCTAssertEqual(loaded.commits, [commit])
        XCTAssertEqual(loaded.branch, "main"); XCTAssertEqual(loaded.branches, snapshot.branches)
        XCTAssertEqual(loaded.stashes, snapshot.stashes); XCTAssertEqual(loaded.commitFiles, snapshot.commitFiles)
        XCTAssertEqual(loaded.observedState, state); XCTAssertEqual(loaded.mainHistoryHead, "abc")
        XCTAssertEqual(loaded.tree?.first?.children.first?.path, "folder/file.txt")
        XCTAssertEqual(loaded.diffText, "diff preview"); XCTAssertEqual(loaded.diffArguments, ["file.txt"])
        XCTAssertEqual(loaded.localUnpushedCommitHashes, ["abc"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.path))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptionVersionAndRepositoryMismatchFallBackWithoutDeletingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo"), directory = root.appendingPathComponent("cache")
        let cache = RepositoryPresentationCache(directory: directory)
        let empty = await cache.load(repository: repository)
        XCTAssertNil(empty)
        try await cache.save(.init(), for: repository)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        payload["version"] = 2
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let wrongVersion = await cache.load(repository: repository)
        XCTAssertNil(wrongVersion)
        payload["version"] = 1; payload["repository"] = "/wrong/repository"
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        let wrongRepository = await cache.load(repository: repository)
        XCTAssertNil(wrongRepository)
        try Data("corrupt".utf8).write(to: file)
        let corrupt = await cache.load(repository: repository)
        XCTAssertNil(corrupt)
        try await cache.remove(repository: repository)
        try await cache.remove(repository: repository)
    }

    func testCountAndByteBudgetsEvictOldEntriesAndOversizedReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cache"), first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let cache = RepositoryPresentationCache(directory: directory, maximumEntries: 1, maximumBytes: 1024)
        try await cache.save(.init(branch: "first"), for: first)
        let oldFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: oldFile.path)
        try await cache.save(.init(branch: "second"), for: second)
        let evicted = await cache.load(repository: first), retained = await cache.load(repository: second)
        XCTAssertNil(evicted); XCTAssertEqual(retained?.branch, "second")
        try await cache.save(.init(diffText: String(repeating: "x", count: 2048)), for: second)
        let oversized = await cache.load(repository: second)
        XCTAssertNil(oversized)
        let byteCache = RepositoryPresentationCache(directory: directory, maximumEntries: 32, maximumBytes: 1024)
        try await byteCache.save(.init(diffText: String(repeating: "x", count: 450)), for: first)
        let firstFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: firstFile.path)
        try await byteCache.save(.init(diffText: String(repeating: "y", count: 450)), for: second)
        let evictedByBytes = await byteCache.load(repository: first), keptByBytes = await byteCache.load(repository: second)
        XCTAssertNil(evictedByBytes); XCTAssertNotNil(keptByBytes)
    }

    func testRemoveAndNewerSaveInvalidateEncodingInProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo")
        let cache = RepositoryPresentationCache(directory: root.appendingPathComponent("cache"))
        let large = RepositoryPresentationSnapshot(diffText: String(repeating: "x", count: 20 * 1024 * 1024))
        let removedSave = Task { try await cache.save(large, for: repository) }
        try await waitForEncoding(cache)
        try await cache.remove(repository: repository)
        try await removedSave.value
        let removed = await cache.load(repository: repository)
        XCTAssertNil(removed)

        let supersededSave = Task { try await cache.save(large, for: repository) }
        try await waitForEncoding(cache)
        try await cache.save(.init(branch: "newest"), for: repository)
        try await supersededSave.value
        let newest = await cache.load(repository: repository)
        XCTAssertEqual(newest?.branch, "newest")
        XCTAssertEqual(newest?.diffText, "")
    }

    private func waitForEncoding(_ cache: RepositoryPresentationCache) async throws {
        let deadline = Date().addingTimeInterval(2)
        while await cache.pendingSaves.isEmpty {
            guard Date() < deadline else { throw NSError(domain: "CacheEncodingDidNotStart", code: 1) }
            await Task.yield()
        }
    }

}
