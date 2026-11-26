import AppKit
import SwiftUI
import XCTest
import AuvGitLocalization
@testable import AuvGit
@testable import GitCore

@MainActor
final class HistoryResetSelectionTests: XCTestCase {
    func testMixedResetFromHistoryMenuSurvivesSameRepositoryRefresh() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Reset Tester"), ("user.email", "reset@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        let file = root.appendingPathComponent("file.txt")
        for content in ["parent", "local tip"] {
            try content.write(to: file, atomically: true, encoding: .utf8)
            try await repo.stage(paths: ["file.txt"])
            try await repo.commit(message: content)
        }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(root)
        let parent = try await repo.workflowRevision("HEAD^")
        store.selectedCommit = parent
        store.selectJournalRows([parent])
        var request: HistoryResetRequest?
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        let commits = store.commits
        let graph = CommitGraph(commits: commits)
        let styles = HistoryGraphStylePlan(commits: commits, remoteBranchNames: [])
        let repositoryURL = try XCTUnwrap(store.repositoryURL)
        let repositoryIdentity = store.graphRepositoryIdentity
        func history(generation: UUID, repositoryIdentity: UUID) -> NativeCompactHistoryTable {
            NativeCompactHistoryTable(commits: commits, graph: graph, styles: styles,
                selection: .constant(parent), navigationGeneration: generation,
                graphWidth: 24, nameWidth: 70, dateWidth: 65, showAvatars: false, showNames: true,
                showRemoteLabels: true, showTagLabels: true, isBusy: false, hasMore: false, isLoading: false,
                onLoadMore: {}, onAction: { action, commit in
                    request = HistoryResetRequest(commit: commit, repositoryURL: repositoryURL, advanced: action == .resetAdvanced)
                }, repositoryIdentity: repositoryIdentity)
        }
        let coordinator = history(generation: UUID(), repositoryIdentity: repositoryIdentity).makeCoordinator()
        coordinator.table = table
        table.dataSource = coordinator
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: try XCTUnwrap(commits.firstIndex { $0.hash == parent })), byExtendingSelection: false)
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { ($0.representedObject as? (HistoryAction, GitCommit, UUID?))?.0 == .resetAdvanced })
        XCTAssertTrue(item.isEnabled)
        coordinator.parent = history(generation: UUID(), repositoryIdentity: UUID())
        coordinator.performAction(item)
        XCTAssertNil(request, "An open reset menu must never target a different repository, even with the same commits")

        coordinator.parent = history(generation: UUID(), repositoryIdentity: repositoryIdentity)
        coordinator.performAction(item)

        let target = try XCTUnwrap(request, "Refreshing history in the same repository must preserve the reset menu target")
        XCTAssertEqual(target.commit.hash, parent)
        let host = NSHostingView(rootView: HistoryResetSheet(store: store, request: target).nativeFocusRoot())
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 480)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func confirmation(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == L10n.text("confirm", table: "HistoryReset") { return button }
            return view.subviews.lazy.compactMap(confirmation).first
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while confirmation(in: host)?.isEnabled != true, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let confirm = try XCTUnwrap(confirmation(in: host))
        XCTAssertTrue(confirm.isEnabled)
        confirm.performClick(nil)
        while store.isBusy || !store.files.contains(where: { $0.path == "file.txt" && $0.isUnstaged }) {
            if ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let head = try await repo.workflowRevision("HEAD")
        XCTAssertEqual(head, parent)
        XCTAssertTrue(store.files.contains { $0.path == "file.txt" && $0.isUnstaged && !$0.isStaged })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local tip")
    }

    func testSelectedCommitResetMovesAllLaterChangesToUnstagedWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Reset Tester"), ("user.email", "reset@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        let file = root.appendingPathComponent("file.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"])
        try await repo.commit(message: "Selected commit")
        let target = try await repo.workflowRevision("HEAD")
        try "later\n".write(to: file, atomically: true, encoding: .utf8)
        try "added\n".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt", "added.txt"])
        try await repo.commit(message: "First later commit")
        try "tip\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file.txt"])
        try await repo.commit(message: "Second later commit")
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        let tip = try await repo.workflowRevision("HEAD")
        store.selectedCommit = nil
        let initialFallback = try await store.historyResetRequest(advanced: true)
        XCTAssertEqual(initialFallback?.commit.hash, tip)
        store.selectedCommit = target

        // No window or history focus: the global command must still use selection.
        for advanced in [false, true] {
            let resolved = try await store.historyResetRequest(advanced: advanced)
            let request = try XCTUnwrap(resolved)
            XCTAssertEqual(request.commit.hash, target)
            XCTAssertEqual(request.repositoryURL, store.repositoryURL)
            XCTAssertEqual(request.advanced, advanced)
        }
        // A list refresh can temporarily remove the selected commit from the displayed rows.
        store.commits.removeAll { $0.hash == target }
        let resolved = try await store.historyResetRequest(advanced: true)
        let request = try XCTUnwrap(resolved)
        XCTAssertEqual(request.commit.hash, target)
        let activeRepo = try XCTUnwrap(store.repository)
        let context = try await activeRepo.resetContext()

        store.isBusy = true
        XCTAssertThrowsError(try store.startHistoryReset(request, mode: .mixed, context: context))
        let unchangedHead = try await activeRepo.workflowRevision("HEAD")
        XCTAssertEqual(unchangedHead, tip)
        store.isBusy = false

        // A failed Git reset must tell the confirmation sheet why it failed.
        let lock = root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        var failure: Error?
        var completed = false
        try store.startHistoryReset(request, mode: .mixed, context: context,
                                    onFailure: { failure = $0 }, onSuccess: { completed = true })
        let failureDeadline = ContinuousClock.now + .seconds(10)
        while failure == nil, !completed, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try FileManager.default.removeItem(at: lock)
        XCTAssertTrue(try XCTUnwrap(failure).localizedDescription.contains("index.lock"))
        XCTAssertFalse(completed)
        let failedHead = try await activeRepo.workflowRevision("HEAD")
        XCTAssertEqual(failedHead, tip)

        try store.startHistoryReset(request, mode: .mixed, context: context,
                                    onFailure: { failure = $0 }, onSuccess: { completed = true })
        XCTAssertTrue(store.isBusy, "The confirmation must start a real repository operation")
        let deadline = ContinuousClock.now + .seconds(10)
        while (store.isBusy || !store.files.contains(where: { $0.path == "added.txt" })) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(completed, "The confirmation can close after Git succeeds")
        XCTAssertNil(store.error)
        XCTAssertTrue(store.files.contains { $0.path == "added.txt" && $0.isUntracked })
        XCTAssertTrue(store.operationLog.contains { $0.command.contains("--mixed") && $0.exitCode == 0 })

        let head = try await activeRepo.workflowRevision("HEAD")
        let index = try await activeRepo.workflowRead(["show", ":file.txt"])
        let staged = try await activeRepo.workflowRead(["diff", "--cached", "--name-only"])
        let files = try await activeRepo.status()
        XCTAssertEqual(head, target)
        XCTAssertEqual(index, "base\n")
        XCTAssertEqual(staged, "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "tip\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("added.txt"), encoding: .utf8), "added\n")
        XCTAssertTrue(files.contains { $0.path == "file.txt" && $0.isUnstaged && !$0.isStaged })
        XCTAssertTrue(files.contains { $0.path == "added.txt" && $0.isUntracked })

        store.selectedCommit = nil
        let resolvedFallback = try await store.historyResetRequest(advanced: true)
        let fallback = try XCTUnwrap(resolvedFallback)
        XCTAssertEqual(fallback.commit.hash, target)
        store.isBusy = true
        let busyRequest = try await store.historyResetRequest(advanced: true)
        XCTAssertNil(busyRequest)
    }
}
