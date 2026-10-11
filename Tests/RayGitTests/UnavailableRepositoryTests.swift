import XCTest
@testable import RayGit
@testable import GitCore

@MainActor
final class UnavailableRepositoryTests: XCTestCase {
    private func repository(_ root: URL, _ name: String) async throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: directory, arguments: ["init", "-b", "main"])
        return directory
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testDeletedRegisteredRootPromptsAndCancellationKeepsEntries() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await repository(root, "first"), second = try await repository(root, "second")
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(first); await store.open(second)
        store.commitMessage = "keep draft"
        let files = store.files
        try FileManager.default.removeItem(at: first)
        await store.open(first)
        XCTAssertEqual(store.unavailableRepository?.path, first.path)
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertEqual(store.files, files)
        XCTAssertEqual(store.commitMessage, "keep draft")
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.pendingRepositoryPath)
        store.unavailableRepository = nil // The alert's Cancel action.
        XCTAssertTrue(store.recentPaths.contains(first.path))
        XCTAssertTrue(store.openRepositories.contains(first.path))
        store.removeRecentRepository(first.path)
        XCTAssertFalse(store.recentPaths.contains(first.path))
        XCTAssertFalse(store.openRepositories.contains(first.path))
        XCTAssertTrue(store.recentPaths.contains(second.path))
        XCTAssertTrue(store.openRepositories.contains(second.path))
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent(".git").path))
    }

    func testMovedRegisteredRootUsesSecurityScopedBookmarkWithoutMissingPrompt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await repository(root, "original"), valid = try await repository(root, "valid")
        let moved = root.appendingPathComponent("moved")
        let key = "bookmark:" + original.path
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let bookmark = try original.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: key)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(valid)
        store.recentPaths.append(original.path)
        try FileManager.default.moveItem(at: original, to: moved)
        await store.open(original)
        XCTAssertEqual(store.repositoryURL?.path, moved.path)
        XCTAssertNil(store.unavailableRepository)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.pendingRepositoryPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.appendingPathComponent(".git").path))
    }

    func testDeletedCurrentRootPromptsBeforeSameRepositoryFastPath() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try await repository(root, "current")
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(directory)
        try FileManager.default.removeItem(at: directory)
        await store.open(directory)
        XCTAssertEqual(store.unavailableRepository?.path, directory.path)
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.pendingRepositoryPath)
        XCTAssertTrue(store.recentPaths.contains(directory.path))
    }

    func testRemovedMetadataCannotOpenParentForCachedOrColdRegisteredRoot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await repository(root, "")
        let cached = try await repository(root, "cached"), cold = try await repository(root, "cold"), valid = try await repository(root, "valid")
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(cached); await store.open(valid)
        store.recentPaths.append(cold.path)
        for directory in [cached, cold] {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(".git"))
            await store.open(directory)
            XCTAssertEqual(store.unavailableRepository?.path, directory.path)
            XCTAssertEqual(store.repositoryURL?.path, valid.path)
            XCTAssertFalse(store.isBusy)
        }
    }

    func testLinkedWorktreeGitFileIsAvailable() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = try await repository(root, "main"), linked = root.appendingPathComponent("linked")
        _ = try await GitProcess.run(at: main, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Fixture"])
        _ = try await GitProcess.run(at: main, arguments: ["worktree", "add", "-b", "linked", linked.path])
        XCTAssertFalse(RepositoryStore.repositoryRootIsMissing(linked))
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.recentPaths = [linked.path]
        await store.open(linked)
        XCTAssertNil(store.unavailableRepository)
        XCTAssertEqual(store.repositoryURL?.path, linked.path)
    }

    func testUnknownInvalidRootsAndAutomaticRequestsDoNotPrompt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try await repository(root, "valid"), ordinary = root.appendingPathComponent("ordinary"), missing = root.appendingPathComponent("missing")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(valid)
        for directory in [ordinary, missing] {
            await store.open(directory)
            XCTAssertNil(store.unavailableRepository)
            XCTAssertEqual(store.repositoryURL?.path, valid.path)
        }
        store.recentPaths.append(missing.path)
        await store.open(missing, promptsIfUnavailable: false)
        XCTAssertNil(store.unavailableRepository)
        XCTAssertTrue(store.recentPaths.contains(missing.path))
        XCTAssertEqual(store.repositoryURL?.path, valid.path)
    }

    func testMissingRequestInterruptsPendingSwitchAndRestoresLastValidRoot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try await repository(root, "valid"), waiting = try await repository(root, "waiting"), missing = root.appendingPathComponent("missing")
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(valid)
        store.commitMessage = "last valid draft"
        store.recentPaths.append(missing.path)
        let wrapper = root.appendingPathComponent("git-wrapper")
        try """
        #!/bin/sh
        if [ -f .git/block-opening ]; then
            for arg in "$@"; do
                if [ "$arg" = "--show-toplevel" ]; then
                    touch .git/opening-blocked
                    attempts=0
                    while [ ! -f .git/release-opening ] && [ "$attempts" -lt 500 ]; do
                        sleep 0.01
                        attempts=$((attempts + 1))
                    done
                fi
            done
        fi
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try Data().write(to: waiting.appendingPathComponent(".git/block-opening"))
        let key = "raygit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer {
            try? Data().write(to: waiting.appendingPathComponent(".git/release-opening"))
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let opening = try XCTUnwrap(store.requestOpen(waiting))
        let blocked = waiting.appendingPathComponent(".git/opening-blocked")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        await store.open(missing)
        try Data().write(to: waiting.appendingPathComponent(".git/release-opening"))
        await opening.value
        XCTAssertEqual(store.repositoryURL?.path, valid.path)
        XCTAssertEqual(store.commitMessage, "last valid draft")
        XCTAssertEqual(store.unavailableRepository?.path, missing.path)
        XCTAssertFalse(store.isBusy); XCTAssertFalse(store.isRestoringViewState)
        XCTAssertNil(store.pendingRepositoryPath)
    }
}
