import XCTest
import AppKit
import Combine
import Darwin
@testable import AuvGit
@testable import GitCore

/// All windows remain unshown: these regressions must never activate the app.
@MainActor
final class LoadingPerformanceRegressionTests: XCTestCase {
    func testSearchDoesNotRebuildDiffDecorationOrLayoutAndDropsObsoleteResults() async throws {
        _ = NSApplication.shared
        let source = (0..<600).map { "let value\($0) = 0" }.joined(separator: "\n")
        let target = source.replacingOccurrences(of: "value300 = 0", with: "value300 = 123")
        let commands = ComparisonEditingCommands()
        func editor(_ query: String) -> ComparisonEditor {
            ComparisonEditor(columns: [
                .init(id: "head", title: "HEAD", text: source, isEditable: false, message: nil),
                .init(id: "worktree", title: "Result", text: target, isEditable: true, message: nil)
            ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true,
                search: query, navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, editingCommands: commands)
        }
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor("")); coordinator.split = split; coordinator.update(editor(""))
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution()
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(2)) }
        let decorationCount = coordinator.decorationBuildCount, layoutCount = coordinator.naturalLayoutBuildCount
        coordinator.update(editor("value"))
        try await waitForSearch(coordinator)
        XCTAssertEqual(commands.searchTotal, 600)
        coordinator.update(editor("0"))
        coordinator.update(editor("value300"))
        try await waitForSearch(coordinator)
        coordinator.alignDisplay()
        XCTAssertEqual(commands.searchTotal, 1)
        XCTAssertEqual(coordinator.decorationBuildCount, decorationCount)
        XCTAssertEqual(coordinator.naturalLayoutBuildCount, layoutCount)
        coordinator.update(editor(""))
        XCTAssertFalse(coordinator.searching)
    }

    func testOnlyChangedPaneNeedsNaturalWrappedLayout() async throws {
        _ = NSApplication.shared
        let source = (0..<40).map { "line \($0) " + String(repeating: "wrapped content ", count: 4) }.joined(separator: "\n")
        func editor(_ result: String) -> ComparisonEditor {
            ComparisonEditor(columns: [
                .init(id: "head", title: "HEAD", text: source, isEditable: false, message: nil),
                .init(id: "worktree", title: "Result", text: result, isEditable: true, message: nil)
            ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true,
                search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
        }
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor(source)); coordinator.split = split; coordinator.update(editor(source))
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution()
        for _ in 0..<5 { split.layoutSubtreeIfNeeded(); coordinator.alignDisplay(); try await Task.sleep(for: .milliseconds(2)) }
        let before = coordinator.naturalLayoutBuildCount
        coordinator.update(editor(source + "\ninserted")); coordinator.alignDisplay()
        XCTAssertEqual(coordinator.naturalLayoutBuildCount, before + 1)
    }

    func testInactiveProjectDoesNotInvalidateWorkspaceAndOnlyThreeProjectsRetainPanels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        let projects = WorkspaceProjects(initial: initial)
        defer { projects.sessions.forEach { $0.closeTransientSession() } }
        for index in 0..<5 {
            let repo = try await GitRepository.initialize(at: root.appendingPathComponent("repo\(index)"))
            await projects.active.open(repo.url)
        }
        XCTAssertEqual(projects.residentSessionIDs.count, 3)
        XCTAssertTrue(projects.residentSessionIDs.contains(projects.active.sessionIdentity))
        XCTAssertFalse(projects.residentSessionIDs.contains(initial.sessionIdentity))
        var changes = 0
        let observation = projects.objectWillChange.sink { changes += 1 }
        initial.commitMessage = "background draft"
        XCTAssertEqual(changes, 0)
        projects.active.commitMessage = "foreground draft"
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(initial.commitMessage, "background draft")
        withExtendedLifetime(observation) {}
    }

    func testConcurrentStaticPreviewLoadsReuseDecodedImageAndMetadata() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 19, pixelsHigh: 7, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        async let first = StaticPreviewWorker.shared.load(data)
        async let second = StaticPreviewWorker.shared.load(data)
        let (a, b) = await (first, second)
        XCTAssertTrue(a === b)
        XCTAssertNotNil(a.image)
        XCTAssertEqual(a.dimensions?.0, 19); XCTAssertEqual(a.dimensions?.1, 7)
        let invalid = Data("<html>not a static image</html>".utf8)
        let failure = await StaticPreviewWorker.shared.load(invalid)
        let repeated = await StaticPreviewWorker.shared.load(invalid)
        XCTAssertNil(failure.image); XCTAssertTrue(failure === repeated)
    }

    private func waitForSearch(_ coordinator: ComparisonEditor.Coordinator) async throws {
        let deadline = Date().addingTimeInterval(3)
        while coordinator.searching, Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(coordinator.searching)
        await Task.yield()
    }

    func testIncomingHistoryUsesIndependentIncrementalPages() async throws {
        let defaults = UserDefaults.standard, key = "preferences.historyPageSize"
        let previous = defaults.object(forKey: key); defaults.set(25, forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"], ["commit", "--allow-empty", "-m", "base"], ["remote", "add", "origin", root.path]] {
            _ = try await repo.workflowRead(args)
        }
        let branch = try await repo.currentBranch()
        let tree = try await repo.workflowRead(["rev-parse", "HEAD^{tree}"]).trimmingCharacters(in: .newlines)
        var parent = try await repo.workflowRevision("HEAD")
        for index in 0..<60 { parent = try await repo.workflowRead(["commit-tree", tree, "-p", parent, "-m", "incoming \(index)"]).trimmingCharacters(in: .newlines) }
        _ = try await repo.workflowRead(["update-ref", "refs/remotes/origin/main", parent])
        try await repo.setUpstream(branch: branch, remoteBranch: "refs/remotes/origin/main")
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = root; store.branches = try await repo.branches()
        await store.loadHistory(reset: true)
        XCTAssertEqual(store.commits.count, 26); XCTAssertTrue(store.hasMore)
        await store.loadHistory(reset: false)
        XCTAssertEqual(store.commits.count, 51); XCTAssertTrue(store.hasMore)
        await store.loadHistory(reset: false)
        XCTAssertEqual(store.commits.count, 61); XCTAssertFalse(store.hasMore)
        XCTAssertEqual(Set(store.commits.map(\.hash)).count, 61)
        XCTAssertEqual(store.commits.first?.subject, "incoming 59")
        XCTAssertEqual(store.commits.last?.subject, "base")
        let traversalCount = await repo.publicationTraversalCount
        XCTAssertEqual(traversalCount, 1)
    }

    func testSelectingAnotherCommitCancelsObsoleteGitDetailProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await repo.workflowRead(args) }
        try "old\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["old.txt"]); try await repo.commit(message: "old")
        let old = try await repo.workflowRevision("HEAD")
        try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["new.txt"]); try await repo.commit(message: "new")
        let latest = try await repo.workflowRevision("HEAD")
        try old.write(to: root.appendingPathComponent(".git/blocked-hash"), atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        blocked=$(cat .git/blocked-hash)
        is_show=false
        for arg in "$@"; do
          if [ "$arg" = show ]; then is_show=true; fi
          if $is_show && [ "$arg" = "$blocked" ]; then
            trap 'touch .git/detail-cancelled; exit 143' TERM
            echo $$ > .git/detail-started
            attempts=0
            while [ "$attempts" -lt 500 ]; do sleep 0.01; attempts=$((attempts + 1)); done
          fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let defaults = UserDefaults.standard, key = "auvgit.git.executablePath", previous = defaults.object(forKey: key)
        defaults.set(wrapper.path, forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = root; store.mode = "history"; store.selectedCommit = old
        let obsolete = Task { await store.loadCommitFiles() }
        let started = root.appendingPathComponent(".git/detail-started")
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let pid = try XCTUnwrap(Int32(String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let cancelledAt = Date()
        store.selectedCommit = latest
        await store.loadCommitFiles(); await obsolete.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 3, "The obsolete five-second command must be cancelled promptly")
        XCTAssertEqual(kill(pid, 0), -1, "Cancelled detail commands must be reaped")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(store.commitFiles.map(\.path), ["new.txt"])
        XCTAssertEqual(store.selectedCommit, latest)
        XCTAssertNil(store.error)
    }
}
