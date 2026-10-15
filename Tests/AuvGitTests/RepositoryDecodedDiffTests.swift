import XCTest
import AuvGitLocalization
@testable import AuvGit
@testable import GitCore

@MainActor
final class RepositoryDecodedDiffTests: XCTestCase {
    private func utf16(_ text: String) -> Data { Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)! }
    func testSelectedFileKeepsDiffAcrossStageUnstageAndMixedChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        let file = root.appendingPathComponent("text.txt"), repository = GitRepository(url: root)
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["text.txt"])
        try await repository.commit(message: "Fixture")
        try "indexed\n".write(to: file, atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.isBusy = true // Keep fixture writes and explicit refreshes deterministic.
        store.mode = "workspace"; store.selectedPaths = ["text.txt"]; store.stagedDiff = false
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("+indexed"))
        try await repository.stage(paths: ["text.txt"])
        store.isBusy = false; await store.refresh(); store.isBusy = true
        XCTAssertEqual(store.selectedPaths, ["text.txt"])
        XCTAssertTrue(store.effectiveStagedDiff)
        XCTAssertTrue(store.diffText.contains("-base"))
        XCTAssertTrue(store.diffText.contains("+indexed"))
        XCTAssertTrue(store.canMutateDisplayedDiff)
        XCTAssertEqual(store.diffTitle, L10n.text("%@  ·  HEAD → Index", arguments: ["text.txt"]))
        try await repository.unstage(paths: ["text.txt"])
        store.stagedDiff = true // A stale staged preference must also recover after unstaging.
        store.isBusy = false; await store.refresh(); store.isBusy = true
        XCTAssertFalse(store.effectiveStagedDiff)
        XCTAssertTrue(store.diffText.contains("+indexed"))
        XCTAssertEqual(store.diffTitle, L10n.text("%@  ·  Index → Working Tree", arguments: ["text.txt"]))
        try await repository.stage(paths: ["text.txt"])
        try "working\n".write(to: file, atomically: true, encoding: .utf8)
        store.stagedDiff = false
        store.isBusy = false; await store.refresh(); store.isBusy = true
        XCTAssertTrue(store.diffText.contains("-indexed"))
        XCTAssertTrue(store.diffText.contains("+working"))
        store.stagedDiff = true; await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-base"))
        XCTAssertTrue(store.diffText.contains("+indexed"))
        XCTAssertFalse(store.diffText.contains("+working"))
        XCTAssertTrue(store.canMutateDisplayedDiff)
    }
    func testMainWorkspaceStagedAndStashPreviewsDecodeTextWithoutChangingOriginalBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        let file = root.appendingPathComponent("text.txt")
        let base = utf16("base version\n"), indexed = utf16("index version\n"), working = utf16("working version\n")
        try base.write(to: file)
        let repository = GitRepository(url: root)
        try await repository.stage(paths: ["text.txt"])
        try await repository.commit(message: "Fixture")
        try indexed.write(to: file)
        try await repository.stage(paths: ["text.txt"])
        try working.write(to: file)
        let raw = try await repository.diff(target: .worktree(path: "text.txt", untracked: false))
        XCTAssertTrue(DiffParser.parse(raw).isBinary)
        let store = RepositoryStore(persistsSession: false)
        await store.open(root)
        store.isBusy = true // Direct fixture writes must not race the filesystem refresh.
        store.mode = "workspace"; store.selectedPaths = ["text.txt"]; store.stagedDiff = false
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-index version"))
        XCTAssertTrue(store.diffText.contains("+working version"))
        XCTAssertFalse(DiffParser.parse(store.diffText).isBinary)
        store.stagedDiff = true
        await store.loadDiff()
        XCTAssertTrue(store.diffText.contains("-base version"))
        XCTAssertTrue(store.diffText.contains("+index version"))
        XCTAssertFalse(store.diffText.contains("working version"))
        let stagedBytes = try await GitProcess.run(at: root, arguments: ["show", ":text.txt"]).data
        XCTAssertEqual(stagedBytes, indexed)
        XCTAssertEqual(try Data(contentsOf: file), working)

        try await repository.stash(message: "UTF16 fixture")
        let hash = try await repository.workflowRead(["rev-parse", "stash@{0}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        store.mode = "history"; store.historyStashHash = hash; store.selectedCommit = hash
        await store.loadCommitFiles()
        XCTAssertTrue(store.diffText.contains("-base version"))
        XCTAssertTrue(store.diffText.contains("+working version"))
        XCTAssertFalse(DiffParser.parse(store.diffText).isBinary)
        XCTAssertEqual(try Data(contentsOf: file), base)
        let restoredIndex = try await GitProcess.run(at: root, arguments: ["show", ":text.txt"]).data
        XCTAssertEqual(restoredIndex, base)
    }
    func testNewSelectionCancelsRunningDiffAndPublishesLatestFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        for path in ["slow.txt", "latest.txt", "failed.txt"] {
            try "base\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        _ = try await GitProcess.run(at: root, arguments: ["add", "."])
        for path in ["slow.txt", "latest.txt", "failed.txt"] {
            try "changed \(path)\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.isBusy = true
        store.mode = "workspace"; store.stagedDiff = false; store.selectedPaths = ["latest.txt"]
        await store.loadDiff()
        let previousText = store.diffText, previousTitle = store.diffTitle
        let previousLeft = store.diffLeftRevisionTitle, previousRight = store.diffRightRevisionTitle
        XCTAssertTrue(store.canMutateDisplayedDiff)
        let wrapper = root.appendingPathComponent(".git/test-git")
        let started = root.appendingPathComponent(".git/slow-started")
        try """
        #!/bin/sh
        case " $* " in
          *" diff "*" slow.txt "*) touch .git/slow-started; if [ -f .git/slow-again ]; then exec /bin/sleep 10; fi; /bin/sleep 1 ;;
          *" diff "*" failed.txt "*) echo "Fixture read failed" >&2; exit 1 ;;
        esac
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        store.mode = "workspace"; store.stagedDiff = false; store.selectedPaths = ["slow.txt"]
        let slow = Task { await store.loadDiff() }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertTrue(store.loadingDiff)
        XCTAssertEqual(store.diffText, previousText)
        XCTAssertEqual(store.diffTitle, previousTitle)
        XCTAssertEqual(store.diffLeftRevisionTitle, previousLeft)
        XCTAssertEqual(store.diffRightRevisionTitle, previousRight)
        XCTAssertFalse(store.canMutateDisplayedDiff)
        store.isBusy = false
        await store.open(root)
        store.isBusy = true
        await slow.value
        XCTAssertTrue(store.diffText.contains("+changed slow.txt"))
        XCTAssertFalse(store.loadingDiff, "Re-clicking the same repository must not strand its running preview")
        XCTAssertTrue(store.canMutateDisplayedDiff)
        store.selectedPaths = ["latest.txt"]
        await store.loadDiff()
        try FileManager.default.removeItem(at: started)
        try Data().write(to: root.appendingPathComponent(".git/slow-again"))
        store.selectedPaths = ["slow.txt"]
        let obsolete = Task { await store.loadDiff() }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        store.selectedPaths = ["latest.txt"]
        let start = Date()
        await store.loadDiff()
        await obsolete.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Obsolete diff must stop rather than finish its blocked command")
        XCTAssertTrue(store.diffText.contains("+changed latest.txt"))
        XCTAssertFalse(store.loadingDiff)
        XCTAssertNil(store.error)
        XCTAssertTrue(store.canMutateDisplayedDiff)
        store.selectedPaths = ["failed.txt"]
        await store.loadDiff()
        XCTAssertEqual(store.diffText, previousText)
        XCTAssertEqual(store.diffTitle, previousTitle)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.canMutateDisplayedDiff)
        store.selectedPaths = []
        await store.loadDiff()
        XCTAssertTrue(store.diffText.isEmpty)
        XCTAssertNil(store.staticPreview)
        XCTAssertNil(store.conflictPreview)
        XCTAssertFalse(store.loadingDiff)
    }

    func testRepositoryRequestPublishesSelectionBeforeAsyncOpen() async {
        let store = RepositoryStore(persistsSession: false)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let task = store.requestOpen(target)
        XCTAssertEqual(store.pendingRepositoryPath, target.path)
        XCTAssertEqual(store.highlightedRepositoryPath, target.path)
        XCTAssertFalse(store.canMutateDisplayedDiff)
        task?.cancel()
        await task?.value
        store.closeTransientSession()
    }

}
