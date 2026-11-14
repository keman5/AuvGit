import XCTest
import AppKit
import SwiftUI
import GitCore
@testable import AuvGit

@MainActor
final class HistoryGraphFeaturesTests: XCTestCase {
    private func commit(_ hash: String, parents: [String] = [], refs: [String] = [], graphParents: [String]? = nil) -> GitCommit {
        GitCommit(hash: hash, parents: parents, author: "Writer", date: .distantPast, subject: hash, body: "", refs: refs,
                  authorEmail: "writer@example.test", committer: "Integrator", committerEmail: "integrator@example.test", graphParents: graphParents)
    }
    func testIndividualMergeCollapseBridgesExclusiveSideAndRetainsRealParents() {
        let commits = [commit("merge", parents: ["main", "side"]), commit("main", parents: ["base"]),
                       commit("side", parents: ["side-parent"]), commit("side-parent", parents: ["base"]), commit("base")]
        let folded = HistoryMergeCollapse.project(commits, collapsed: ["merge"], preserving: [])
        XCTAssertEqual(folded.commits.map(\.hash), ["merge", "main", "base"])
        XCTAssertEqual(folded.hiddenCounts["merge"], 2)
        XCTAssertEqual(folded.commits.first?.parents, ["main", "side"], "Comparison/mutation retains real parent IDs")
        XCTAssertEqual(folded.commits.first?.graphParents, ["main", "base"])
        XCTAssertFalse(CommitGraph(commits: folded.commits).frontier.contains("side"))
        XCTAssertEqual(HistoryMergeCollapse.project(commits, collapsed: [], preserving: []).commits, commits)
    }
    func testCollapsePreservesSelectedDescendantAndReferencedTip() {
        let commits = [commit("merge", parents: ["main", "side"]), commit("main", parents: ["base"]),
                       commit("side", parents: ["middle"], refs: ["refs/heads/topic"]), commit("middle", parents: ["selected"]),
                       commit("selected", parents: ["base"]), commit("base")]
        let folded = HistoryMergeCollapse.project(commits, collapsed: ["merge"], preserving: ["selected"])
        XCTAssertTrue(folded.commits.contains { $0.hash == "selected" })
        XCTAssertTrue(folded.commits.contains { $0.hash == "side" })
        XCTAssertFalse(folded.commits.contains { $0.hash == "middle" })
        XCTAssertEqual(folded.commits.first { $0.hash == "side" }?.graphParents, ["selected"])
    }
    func testProjectedReferenceRetainsCanonicalIdentityAndRemoteVisibility() {
        let commits = [commit("visible", refs: ["HEAD -> refs/heads/main~", "refs/heads/origin/topic~", "refs/remotes/origin/topic~", "refs/tags/v1~"])]
        let styles = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/topic"], visibleRemoteBranchNames: [])
        XCTAssertTrue(styles.referenceLabel("HEAD -> refs/heads/main~").hasSuffix("main~"))
        XCTAssertFalse(styles.isCurrentCommit("visible"), "A projected HEAD reference is not the actual HEAD node")
        XCTAssertFalse(styles.isRemoteReference("refs/heads/origin/topic~"))
        XCTAssertFalse(styles.isVisibleReference("refs/remotes/origin/topic~"))
        XCTAssertTrue(styles.isVisibleReference("refs/heads/origin/topic~"))
        XCTAssertTrue(styles.isTagReference("refs/tags/v1~"))
        XCTAssertEqual(HistoryGraphStylePlan.canonicalReference("refs/heads/topic~"), "refs/heads/topic")
    }
    func testFilteredGraphUsesProjectedParentsWithoutChangingCommitParents() {
        let commits = [commit("child", parents: ["hidden"], graphParents: ["ancestor"]), commit("ancestor")]
        let graph = CommitGraph(commits: commits)
        XCTAssertTrue(graph.rows[0].segments.contains { $0.lineageHash == "ancestor" && $0.fromY == 0.5 })
        XCTAssertFalse(graph.frontier.contains("hidden"))
        XCTAssertEqual(commits[0].parents, ["hidden"])
    }
    func testIdentityDimensionsIndependentlyChooseCommitterNameAndEmail() {
        let entry = commit("commit")
        XCTAssertEqual(HistoryIdentityMode.committer.text(entry, names: true, emails: true), "Integrator <integrator@example.test>")
        XCTAssertEqual(HistoryIdentityMode.author.text(entry, names: false, emails: true), "writer@example.test")
        XCTAssertEqual(HistoryIdentityMode.committer.email(entry), "integrator@example.test")
        XCTAssertEqual(HistoryIdentityMode.author.text(entry, names: false, emails: false), "")
    }
    private func tableView(commits: [GitCommit], selection: Binding<String?> = .constant(nil)) -> NativeCompactHistoryTable {
        NativeCompactHistoryTable(commits: commits, graph: CommitGraph(commits: commits), styles: HistoryGraphStylePlan(commits: commits, remoteBranchNames: []),
            selection: selection, navigationGeneration: nil, graphWidth: 24, nameWidth: 60, dateWidth: 65,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
    }
    func testVirtualAndRealRowsShareSelectionWithoutFakeCommitOrDuplicateCallbacks() {
        var primary: String?
        var changes: [Set<String>] = []
        var view = tableView(commits: [commit("head")], selection: Binding(get: { primary }, set: { primary = $0 }))
        view.virtualRows = [.workingTree, .index]
        view.onSelectCommits = { changes.append($0) }
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        coordinator.table = table
        table.reloadData()
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertNil(view.commit(at: 0))
        XCTAssertNil(view.commit(at: 1))
        XCTAssertEqual(view.commit(at: 2)?.hash, "head")
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        let notification = Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        coordinator.tableViewSelectionDidChange(notification)
        XCTAssertEqual(changes, [[HistoryVirtualRow.workingTree.id, "head"]])
        XCTAssertNotNil(primary)
        coordinator.tableViewSelectionDidChange(notification)
        XCTAssertEqual(changes.count, 1, "Repeated native selection notifications must not retrigger comparison")
        coordinator.updatingSelection = true
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(notification)
        XCTAssertEqual(changes.count, 1, "Programmatic reload/selection is silent")
    }
    func testVirtualRowsNeverExposeGitActionsOrCommitHashesInReusedCells() {
        var view = tableView(commits: [commit("head")])
        let cell = CompactHistoryCell(frame: NSRect(x: 0, y: 0, width: 650, height: 22))
        cell.configure(parent: view, index: 0)
        XCTAssertEqual(cell.displayedCommitHash, "head")
        view.virtualRows = [.index]
        cell.configure(parent: view, index: 0)
        XCTAssertNil(cell.displayedCommitHash)
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator; coordinator.table = table; table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = NSMenu(); coordinator.menuNeedsUpdate(menu)
        XCTAssertTrue(menu.items.isEmpty)
    }
    func testDragPayloadRoundTripsCanonicalReferenceAndRepositoryGeneration() throws {
        let generation = UUID()
        let payload = HistoryGraphDragPayload(source: .localBranch("refs/heads/origin/topic"), generation: generation)
        let decoded = try JSONDecoder().decode(HistoryGraphDragPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.source, .localBranch("refs/heads/origin/topic"))
        XCTAssertEqual(decoded.generation, generation)
        XCTAssertEqual(HistoryGraphDragSource.head.operations, [.reset, .rebase])
        XCTAssertEqual(HistoryGraphDragSource.localBranch("refs/heads/topic").operations, [.moveBranch, .rebase])
    }
    func testOverlapCacheBoundsCandidateWorkCachesAndInvalidatesRepository() async {
        let commits = (0..<160).map { commit("c\($0)") }
        let cache = HistoryOverlapCache()
        var calls = 0, requested: [String] = []
        let loader: (String, [String]) async throws -> [String: Int] = { selected, candidates in
            calls += 1; requested = candidates
            XCTAssertEqual(selected, "c80")
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0, $0 == "c81" ? 2 : 0) })
        }
        let generation = UUID()
        await cache.load(selected: "c80", commits: commits, generation: generation, enabled: true, loader: loader)
        XCTAssertLessThanOrEqual(requested.count, 80)
        XCTAssertTrue(requested.contains("c79")); XCTAssertTrue(requested.contains("c81"))
        XCTAssertFalse(requested.contains("c80"))
        XCTAssertEqual(cache.values["c81"], 2)
        await cache.load(selected: "c80", commits: commits, generation: generation, enabled: true, loader: loader)
        XCTAssertEqual(calls, 1)
        await cache.load(selected: "c80", commits: commits, generation: UUID(), enabled: true, loader: loader)
        XCTAssertEqual(calls, 2)
        await cache.load(selected: HistoryVirtualRow.index.id, commits: commits, generation: generation, enabled: true, loader: loader)
        XCTAssertTrue(cache.values.isEmpty); XCTAssertEqual(calls, 2)
    }
    func testSlowOverlapLoadCannotReplaceANewerSelectionInSameRepository() async throws {
        let commits = [commit("first"), commit("second"), commit("candidate")]
        let cache = HistoryOverlapCache()
        let generation = UUID()
        let started = expectation(description: "Old overlap request started")
        var resumeOld: CheckedContinuation<[String: Int], Error>?
        let old = Task { @MainActor in
            await cache.load(selected: "first", commits: commits, generation: generation, enabled: true) { _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    resumeOld = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await cache.load(selected: "second", commits: commits, generation: generation, enabled: true) { _, _ in ["candidate": 3] }
        XCTAssertEqual(cache.values, ["candidate": 3])
        XCTAssertFalse(cache.isLoading)
        try XCTUnwrap(resumeOld).resume(returning: ["candidate": 99])
        await old.value
        XCTAssertEqual(cache.values, ["candidate": 3], "Completion of an older request must not replace the latest selection, even without cancellation")
        XCTAssertFalse(cache.isLoading)
    }

    func testExplicitClickActivatesAutoSelectedHeadOnceWithoutSelectionFeedback() {
        var calls: [Set<String>] = []
        var view = tableView(commits: [commit("head")], selection: .constant("head"))
        view.requiresSelectionActivation = true
        view.onSelectCommits = { calls.append($0) }
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator; coordinator.table = table; table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.rangeSelection.synchronize(primary: "head", orderedIDs: view.rowIDs)
        let notification = Notification(name: NSTableView.selectionDidChangeNotification, object: table)
        coordinator.tableViewSelectionDidChange(notification)
        XCTAssertTrue(calls.isEmpty, "Unchanged programmatic selection remains silent")
        coordinator.activateSelectionFromExplicitClick(row: 0)
        XCTAssertEqual(calls, [["head"]], "Clicking auto-selected HEAD must open its journal files")
        coordinator.activateSelectionFromExplicitClick(row: 0)
        coordinator.tableViewSelectionDidChange(notification)
        XCTAssertEqual(calls.count, 1, "A stale SwiftUI activation flag cannot cause duplicate fetches")
        coordinator.parent.requiresSelectionActivation = false
        coordinator.activateSelectionFromExplicitClick(row: 0)
        XCTAssertEqual(calls.count, 1)
    }
    func testChangedSelectionClickDoesNotAlsoEmitActivationCallback() {
        var calls: [Set<String>] = []
        var view = tableView(commits: [commit("head"), commit("older")], selection: .constant("head"))
        view.requiresSelectionActivation = true
        view.onSelectCommits = { calls.append($0) }
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator; coordinator.table = table; table.reloadData()
        coordinator.rangeSelection.synchronize(primary: "head", orderedIDs: view.rowIDs)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        coordinator.activateSelectionFromExplicitClick(row: 1)
        XCTAssertEqual(calls, [["older"]], "A normal selection change already activates the journal")
    }

}
