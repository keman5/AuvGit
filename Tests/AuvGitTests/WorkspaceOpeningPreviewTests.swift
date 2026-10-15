import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class WorkspaceOpeningPreviewTests: XCTestCase {
    func testColdWorkspacePublishesUsableListsBeforeSlowComparison() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "."])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        try "changed\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent(".git/test-git")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "diff" ]; then
                touch .git/diff-blocked
                attempts=0
                while [ ! -f .git/release-diff ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        let started = Date()
        let opening = Task { await store.open(root) }
        let blocked = root.appendingPathComponent(".git/diff-blocked"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertEqual(store.repositoryURL?.path, root.path)
        XCTAssertEqual(store.files.map(\.path), ["file.txt"])
        XCTAssertEqual(store.branches.first?.name, "main")
        XCTAssertEqual(store.commits.first?.subject, "Fixture")
        XCTAssertFalse(store.isBusy, "A slow preview must not disable the already loaded project")
        XCTAssertNil(store.pendingRepositoryPath)
        XCTAssertTrue(store.loadingDiff)
        XCTAssertFalse(store.canMutateDisplayedDiff)
        print("Cold workspace lists usable before comparison: \(Date().timeIntervalSince(started))s")
        try Data().write(to: root.appendingPathComponent(".git/release-diff"))
        await opening.value
        XCTAssertTrue(store.diffText.contains("+changed"))
        XCTAssertFalse(store.loadingDiff)
        XCTAssertTrue(store.canMutateDisplayedDiff)

        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: other, arguments: ["init", "-b", "main"])
        await store.open(other)
        try "changed again\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: blocked)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/release-diff"))
        let reopening = Task { await store.open(root) }
        let warmDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < warmDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertEqual(store.repositoryURL?.path, root.path)
        XCTAssertFalse(store.isBusy, "Changed cached projects must also become usable before their preview finishes")
        XCTAssertNil(store.pendingRepositoryPath)
        XCTAssertTrue(store.loadingDiff)
        XCTAssertFalse(store.canMutateDisplayedDiff)
        try Data().write(to: root.appendingPathComponent(".git/release-diff"))
        await reopening.value
        XCTAssertTrue(store.diffText.contains("+changed again"))
        XCTAssertTrue(store.canMutateDisplayedDiff)
    }
}
