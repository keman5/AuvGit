import AppKit
import SwiftUI
import XCTest
@testable import GitCore
@testable import AuvGit

@MainActor
final class ComparisonParitySessionTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.autocrlf", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        try Data("first = 1; second = 2\nnext = 3\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let repo = GitRepository(url: root)
        try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: "Initial")
        return (root, repo)
    }
    func testIndexSavePreservesWorkingTreeAndOtherDrafts() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: root.appendingPathComponent("file.txt"))
        let session = FileCompareSession(repository: repo, path: "file.txt"); await session.reload()
        session.edit("worktree", text: "unfinished working draft\n")
        session.edit("index", text: "independent indexed content\n")
        let saved = await session.save()
        XCTAssertTrue(saved, session.error ?? "")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("file.txt")), original)
        let current = try await repo.fileComparison(path: "file.txt")
        XCTAssertEqual(current.index.text, "independent indexed content\n")
        XCTAssertTrue(session.isDirty("worktree")); XCTAssertFalse(session.isDirty("index"))
    }
    func testIndexSaveRejectsExternalChangesAndRetainsDraft() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repo, path: "file.txt"); await session.reload()
        session.edit("index", text: "draft\n")
        try Data("external\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(paths: ["file.txt"])
        let saved = await session.saveIndexDraft()
        XCTAssertFalse(saved); XCTAssertTrue(session.isDirty("index"))
        let current = try await repo.fileComparison(path: "file.txt")
        XCTAssertEqual(current.index.text, "external\n")
    }
    func testEditorStagesAndUnstagesOneInnerLineChange() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let working = "first = 100; second = 200\nnext = 3\n"
        try Data(working.utf8).write(to: root.appendingPathComponent("file.txt"))
        let session = FileCompareSession(repository: repo, path: "file.txt"); await session.reload()
        let selection = (working as NSString).range(of: "100")
        await session.stageEditorSelection(paneID: "worktree", selection: selection, granularity: .selection, unstage: false)
        let staged = try await repo.fileComparison(path: "file.txt")
        XCTAssertEqual(staged.index.text, "first = 100; second = 2\nnext = 3\n", session.error ?? "")
        XCTAssertEqual(staged.worktree.text, working)
        await session.stageEditorSelection(paneID: "index", selection: NSRange(location: 9, length: 0), granularity: .innerLine, unstage: true)
        let unstaged = try await repo.fileComparison(path: "file.txt")
        XCTAssertEqual(unstaged.index.text, "first = 1; second = 2\nnext = 3\n", session.error ?? "")
        XCTAssertEqual(unstaged.worktree.text, working)
    }
    func testLineEndingRulesFeedNavigationAndCompactProjection() {
        let text = "same\nnext\n"
        let columns = [ComparisonEditorColumn(id: "index", title: "Index", text: text, isEditable: false, message: nil, lineEnding: .crlf), ComparisonEditorColumn(id: "worktree", title: "Working", text: text, isEditable: true, message: nil)]
        XCTAssertFalse(CompactComparisonProjection(columns: columns, conflict: false).bands.isEmpty)
        XCTAssertTrue(CompactComparisonProjection(columns: columns, conflict: false, rules: .init(ignoreLineEndings: true)).bands.isEmpty)
        XCTAssertFalse(ComparisonChangeNavigation(texts: [text, text], endings: [.crlf, .lf]).bands.isEmpty)
        XCTAssertTrue(ComparisonChangeNavigation(texts: [text, text], rules: .init(ignoreLineEndings: true), endings: [.crlf, .lf]).bands.isEmpty)
    }
    func testGranularAcceptUsesOneUndoOperation() throws {
        let view = UndoableComparisonTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: nil)
        view.isEditable = true; view.string = "first new\nsecond new\nlast new"
        let original = view.string
        let edit = try XCTUnwrap(ComparisonTransfer.edit(source: "first old\nsecond old\nlast old", target: original, selection: NSRange(location: 0, length: 20), granularity: .selection))
        view.replaceAsUndoableEdit(edit.replacement, range: edit.range)
        XCTAssertNotEqual(view.string, original)
        view.editingUndoManager.undo(); XCTAssertEqual(view.string, original)
    }
    func testMergeBelowUsesFullWidthResultAndRetainsDraftCaretUndoAcrossLayout() async throws {
        _ = NSApplication.shared
        var model = ComparisonEditor(columns: [
            .init(id: "ours", title: "Ours", text: "left\n", isEditable: true, message: nil),
            .init(id: "worktree", title: "Result", text: "draft\n", isEditable: true, message: nil, preservesUndo: true),
            .init(id: "theirs", title: "Theirs", text: "right\n", isEditable: true, message: nil)
        ], wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "draft", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model); coordinator.split = split; coordinator.update(model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        func views(_ view: NSView) -> [ComparisonTextView] { (view as? ComparisonTextView).map { [$0] } ?? view.subviews.flatMap(views) }
        let result = try XCTUnwrap(views(split).first(where: { $0.string == "draft\n" }))
        result.replaceAsUndoableEdit("retained draft\n"); result.setSelectedRange(NSRange(location: 3, length: 2))
        let updatedColumns = model.columns.map { column in column.id == "worktree" ? ComparisonEditorColumn(id: column.id, title: column.title, text: result.string, isEditable: true, message: nil, preservesUndo: true) : column }
        model = ComparisonEditor(columns: updatedColumns, wrapLines: true, showLineNumbers: true, synchronizeScroll: true, search: "draft", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
        model.mergeResultBelow = true; coordinator.update(model); split.resetDistribution(); split.layoutSubtreeIfNeeded()
        XCTAssertFalse(split.isVertical); XCTAssertEqual(split.arrangedSubviews.count, 2)
        let sourceSplit = try XCTUnwrap(split.arrangedSubviews.first as? NSSplitView)
        XCTAssertTrue(sourceSplit.isVertical); XCTAssertEqual(sourceSplit.arrangedSubviews.count, 2)
        XCTAssertEqual(split.arrangedSubviews[1].frame.width, split.bounds.width, accuracy: 1)
        XCTAssertTrue(views(split).contains(where: { $0 === result }))
        XCTAssertEqual(result.selectedRange(), NSRange(location: 3, length: 2))
        model.mergeResultBelow = false; coordinator.update(model); split.resetDistribution()
        XCTAssertEqual(split.arrangedSubviews.count, 3)
        result.editingUndoManager.undo(); XCTAssertEqual(result.string, "draft\n")
        XCTAssertFalse(window.isVisible, "Background verification must not show the host window")
    }

    func testUnstagingAllLinesOfAddedFileRemovesIndexEntry() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let text = "new file\n"
        try Data(text.utf8).write(to: root.appendingPathComponent("added.txt")); try await repo.stage(paths: ["added.txt"])
        let session = FileCompareSession(repository: repo, path: "added.txt"); await session.reload()
        await session.stageEditorSelection(paneID: "index", selection: NSRange(location: 0, length: 0), granularity: .line, unstage: true)
        let current = try await repo.fileComparison(path: "added.txt")
        XCTAssertFalse(current.index.exists, session.error ?? ""); XCTAssertEqual(current.worktree.text, text)
    }
    func testUnstagingDeletedExecutableRestoresHeadMode() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("executable.sh")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try await repo.stage(paths: ["executable.sh"]); try await repo.commit(message: "Executable")
        try FileManager.default.removeItem(at: url); try await repo.stage(paths: ["executable.sh"])
        let session = FileCompareSession(repository: repo, path: "executable.sh"); await session.reload()
        await session.stageEditorSelection(paneID: "index", selection: NSRange(location: 0, length: 0), granularity: .line, unstage: true)
        let current = try await repo.fileComparison(path: "executable.sh")
        XCTAssertTrue(current.index.exists, session.error ?? ""); XCTAssertEqual(current.index.gitMode, "100755")
        XCTAssertFalse(current.worktree.exists)
    }

    func testUnstagingAllSelectedAddedLinesRemovesIndexEntry() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let text = "new first\nnew second\n"
        try Data(text.utf8).write(to: root.appendingPathComponent("added.txt")); try await repo.stage(paths: ["added.txt"])
        let session = FileCompareSession(repository: repo, path: "added.txt"); await session.reload()
        await session.stageEditorSelection(paneID: "index", selection: NSRange(location: 0, length: text.utf16.count), granularity: .selection, unstage: true)
        let current = try await repo.fileComparison(path: "added.txt")
        XCTAssertFalse(current.index.exists, session.error ?? ""); XCTAssertEqual(current.worktree.text, text)
    }

    func testInnerLineContextActionPreservesCaretColumn() throws {
        _ = NSApplication.shared
        let target = "first = 100; second = 200\n"
        let model = ComparisonEditor(columns: [.init(id: "index", title: "Index", text: "first = 1; second = 2\n", isEditable: false, message: nil), .init(id: "worktree", title: "Working", text: target, isEditable: true, message: nil)], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in })
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model); coordinator.split = split; coordinator.update(model)
        func views(_ view: NSView) -> [ComparisonTextView] { (view as? ComparisonTextView).map { [$0] } ?? view.subviews.flatMap(views) }
        let text = try XCTUnwrap(views(split).first(where: { $0.string == target }))
        text.setSelectedRange(NSRange(location: 9, length: 0))
        let action = try XCTUnwrap(text.blockMenu?(0).first(where: { $0.0.hasPrefix(comparisonParityText("applyInner")) })?.1)
        action()
        XCTAssertEqual(text.string, "first = 1; second = 200\n")
        text.editingUndoManager.undo(); XCTAssertEqual(text.string, target)
    }

    func testReloadAndReinterpretCancelForceCompareAndBusySessionCannotStartIt() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repo, path: "file.txt"); await session.reload()
        session.isBusy = true; session.requestForceCompare(); XCTAssertFalse(session.preparingForceCompare)
        session.isBusy = false; session.requestForceCompare(); XCTAssertTrue(session.preparingForceCompare)
        session.reinterpret(as: .utf8); XCTAssertFalse(session.preparingForceCompare); XCTAssertFalse(session.forceCompare)
        session.requestForceCompare(); await session.reload()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(session.preparingForceCompare); XCTAssertFalse(session.forceCompare)
    }

}
