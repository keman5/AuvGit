import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class RepositoryPresentationOpeningTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func repository(_ root: URL, _ name: String) async throws -> URL {
        let directory = name.isEmpty ? root : root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: directory, arguments: ["init", "-b", "main"])
        try "base\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: directory, arguments: ["add", "."])
        _ = try await GitProcess.run(at: directory, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "Fixture"])
        return directory
    }

    func testFirstDiskCachedOpenPublishesBeforeBlockedStatusWithin100Milliseconds() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repository(root, "first"), second = try await repository(root, "second")
        try "cached content\n".write(to: second.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let repo = GitRepository(url: second), cache = RepositoryPresentationCache(directory: root.appendingPathComponent("cache"))
        let files = try await repo.status(), branches = try await repo.branches(), commits = try await repo.log()
        let state = try await repo.changeState(files: files)
        let snapshot = RepositoryPresentationSnapshot(files: files, branches: branches, branch: "main", stashes: [.init(ref: "stash@{0}", subject: "Cached stash")],
            commits: commits, loadedCount: commits.count, observedState: state, historyState: state.history, mainHistoryHead: commits.first?.hash,
            diffText: "cached comparison", diffIdentity: "cached", diffFilename: "file.txt", diffLeft: "HEAD", diffRight: "Working Tree")
        try await cache.save(snapshot, for: second)
        try "fresh content\n".write(to: second.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "new file\n".write(to: second.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: cache)
        defer { store.closeTransientSession() }
        await store.open(first)
        let wrapper = root.appendingPathComponent("git-wrapper")
        try """
        #!/bin/sh
        if [ -f .git/block-status ]; then
            for arg in "$@"; do
                if [ "$arg" = "status" ]; then
                    touch .git/status-blocked
                    attempts=0
                    while [ ! -f .git/release-status ] && [ "$attempts" -lt 500 ]; do
                        sleep 0.01
                        attempts=$((attempts + 1))
                    done
                fi
            done
        fi
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try Data().write(to: second.appendingPathComponent(".git/block-status"))
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer {
            try? Data().write(to: second.appendingPathComponent(".git/release-status"))
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let start = Date()
        let opening = try XCTUnwrap(store.requestOpen(second))
        while store.repositoryURL?.path != second.path, Date().timeIntervalSince(start) < 0.1 { await Task.yield() }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertLessThan(elapsed, 0.1, "Disk snapshot publication must not wait for Git status")
        XCTAssertEqual(store.files, files); XCTAssertEqual(store.branches, branches); XCTAssertEqual(store.commits, commits)
        XCTAssertEqual(store.stashes, snapshot.stashes); XCTAssertEqual(store.diffText, "cached comparison")
        XCTAssertEqual(store.selectedCommit, commits.first?.hash)
        XCTAssertEqual(store.selectedPaths, ["file.txt"])
        XCTAssertTrue(store.isBusy); XCTAssertFalse(store.canMutateDisplayedDiff)
        let blocked = second.appendingPathComponent(".git/status-blocked"), deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertTrue(store.isBusy); XCTAssertEqual(store.diffText, "cached comparison")
        try Data().write(to: second.appendingPathComponent(".git/release-status"))
        await opening.value
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.error)
        XCTAssertTrue(store.files.contains { $0.path == "new.txt" && $0.isUntracked })
        XCTAssertTrue(store.diffText.contains("fresh content"))
        XCTAssertFalse(store.diffText.contains("cached comparison"))
        print("First disk-cached model publication: \(elapsed)s")
    }

    func testCorruptPresentationFallsBackToFreshOpen() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await repository(root, "repo"), directory = root.appendingPathComponent("cache")
        let cache = RepositoryPresentationCache(directory: directory)
        try await cache.save(.init(diffText: "invalid"), for: repo)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: file)
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: cache)
        defer { store.closeTransientSession() }
        await store.open(repo)
        XCTAssertEqual(store.repositoryURL?.path, repo.path)
        XCTAssertEqual(store.commits.first?.subject, "Fixture")
        XCTAssertNil(store.error); XCTAssertFalse(store.isBusy)
    }

    func testDiskCachedRegisteredRootWithRemovedGitCannotOpenItsParent() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repository(root, "")
        let missing = try await repository(root, "missing"), valid = try await repository(root, "valid")
        let cache = RepositoryPresentationCache(directory: root.appendingPathComponent("cache"))
        try await cache.save(.init(branch: "stale"), for: missing)
        try FileManager.default.removeItem(at: missing.appendingPathComponent(".git"))
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: cache)
        defer { store.closeTransientSession() }
        await store.open(valid)
        store.recentPaths.append(missing.path)
        await store.open(missing)
        XCTAssertEqual(store.repositoryURL?.path, valid.path)
        XCTAssertEqual(store.unavailableRepository?.path, missing.path)
        XCTAssertFalse(store.isBusy)
    }

    func testRemoveRecentAlsoRemovesOnlyItsDiskPresentation() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repository(root, "first"), valid = try await repository(root, "valid")
        let cache = RepositoryPresentationCache(directory: root.appendingPathComponent("cache"))
        try await cache.save(.init(branch: "first"), for: first)
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: cache)
        defer { store.closeTransientSession() }
        await store.open(valid)
        store.recentPaths.append(first.path)
        store.removeRecentRepository(first.path)
        let deadline = Date().addingTimeInterval(2)
        var removed = false
        while Date() < deadline {
            if await cache.load(repository: first) == nil { removed = true; break }
            await Task.yield()
        }
        XCTAssertTrue(removed)
        XCTAssertFalse(store.recentPaths.contains(first.path))
        XCTAssertTrue(store.recentPaths.contains(valid.path))
        XCTAssertEqual(store.repositoryURL?.path, valid.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.appendingPathComponent(".git").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent(".git").path))
    }
    func testCorruptIndexKeepsTargetHistoryBlocksMutationsAndPreservesIndex() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try await repository(root, "valid"), damaged = try await repository(root, "damaged")
        let index = damaged.appendingPathComponent(".git/index")
        let goodIndex = try Data(contentsOf: index)
        var corrupted = goodIndex
        corrupted.replaceSubrange(36..<40, with: [0xbd, 0xef, 0x00, 0x00])
        try corrupted.write(to: index)
        let cache = RepositoryPresentationCache(directory: root.appendingPathComponent("cache"))
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true, presentationCache: cache)
        defer { store.closeTransientSession() }
        store.showsWorkspaceTree = true
        await store.open(valid)
        await store.open(damaged)
        XCTAssertEqual(store.repositoryURL?.path, damaged.path, "An unreadable index must not bounce to the previous project")
        XCTAssertNotNil(store.repository)
        XCTAssertEqual(store.branch, "main")
        XCTAssertEqual(store.commits.first?.subject, "Fixture")
        XCTAssertEqual(store.branches.first?.name, "main")
        XCTAssertNotNil(store.workspaceStatusFailure)
        XCTAssertTrue(store.files.isEmpty)
        store.commitMessage = "Must not commit"; store.amend = true
        XCTAssertFalse(store.canCommit); XCTAssertFalse(store.canMutateDisplayedDiff)
        var mutated = false
        store.operation("blocked") { _ in mutated = true }
        await Task.yield()
        XCTAssertFalse(mutated)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(try Data(contentsOf: index), corrupted)
        await store.open(valid)
        XCTAssertNil(store.workspaceStatusFailure)
        let started = ContinuousClock.now
        let opening = try XCTUnwrap(store.requestOpen(damaged))
        XCTAssertEqual(store.repositoryURL?.path, damaged.path)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(100))
        XCTAssertNotNil(store.workspaceStatusFailure)
        await opening.value
        XCTAssertEqual(store.repositoryURL?.path, damaged.path)
        XCTAssertEqual(try Data(contentsOf: index), corrupted)
        try goodIndex.write(to: index)
        await store.refreshFileStatus()
        XCTAssertNil(store.workspaceStatusFailure)
        XCTAssertNil(store.error)
    }

}
