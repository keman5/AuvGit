import XCTest
import AppKit
@testable import GitCore
@testable import RayGit

@MainActor
final class RevisionCopyEditingTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-copy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Copy Fixture"],
                     ["config", "user.email", "copy@example.invalid"], ["config", "commit.gpgsign", "false"],
                     ["config", "core.hooksPath", root.appendingPathComponent("no-hooks").path], ["config", "core.autocrlf", "false"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        for text in ["parent\n", "historical\n", "current\n"] {
            try Data(text.utf8).write(to: root.appendingPathComponent("file.txt"))
            try await repo.stage(paths: ["file.txt"]); try await repo.commit(message: text)
        }
        let hash = try await repo.workflowRevision("HEAD~1")
        return (root, repo, hash)
    }

    func testHistoricalColumnsKeepSeparateDraftsAndSaveOnlyActiveCopyToWorktree() async throws {
        let (root, repo, hash) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repo, path: "file.txt", target: .commit(hash: hash, path: "file.txt"))
        await session.reload()
        XCTAssertNil(session.error); XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.text(in: "head"), "parent\n")
        XCTAssertEqual(session.draft, "historical\n")
        XCTAssertEqual(session.text(in: "current"), "current\n")
        for id in ["head", "worktree", "current"] { XCTAssertTrue(session.canEdit(id)) }
        let before = try await repo.fileComparison(path: "file.txt")
        session.edit("worktree", text: "edited history\n")
        session.edit("head", text: "edited parent\n")
        XCTAssertTrue(session.closeMessage.contains(session.savingPaneTitle))
        XCTAssertTrue(session.closeMessage.contains(compareText("Other Drafts Discarded On Close")))
        let saved = await session.save(); XCTAssertTrue(saved, session.error ?? "save failed")
        XCTAssertFalse(session.isDirty("head")); XCTAssertTrue(session.isDirty("worktree"))
        XCTAssertEqual(session.draft, "edited history\n")
        XCTAssertEqual(session.text(in: "current"), "edited parent\n")
        XCTAssertEqual(session.snapshot?.worktree.text, "historical\n")
        XCTAssertEqual(session.snapshot?.head.text, "parent\n")
        let after = try await repo.fileComparison(path: "file.txt")
        XCTAssertEqual(after.worktree.text, "edited parent\n")
        XCTAssertEqual(after.head.data, before.head.data); XCTAssertEqual(after.index.data, before.index.data)
        session.activePaneID = "worktree"
        let savedAgain = await session.save(); XCTAssertTrue(savedAgain, session.error ?? "save failed")
        XCTAssertFalse(session.isDirty)
        let historical = try await repo.comparisonPreview(target: .commit(hash: hash, path: "file.txt"))
        XCTAssertEqual(historical.worktree.text, "historical\n")
    }

    func testHeadAndIndexCopiesNeverWriteToIndexAndPreserveUnsavedWorkingCopy() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repo, path: "file.txt")
        await session.reload()
        session.edit("worktree", text: "pending worktree\n")
        session.edit("index", text: "index copy\n")
        let saved = await session.save(); XCTAssertTrue(saved, session.error ?? "save failed")
        XCTAssertEqual(session.draft, "pending worktree\n"); XCTAssertTrue(session.isDirty("worktree"))
        let after = try await repo.fileComparison(path: "file.txt")
        XCTAssertEqual(after.index.text, "current\n"); XCTAssertEqual(after.worktree.text, "index copy\n")
        session.edit("worktree", text: "current\n")
        session.edit("head", text: "head copy\n")
        let savedHead = await session.save(); XCTAssertTrue(savedHead, session.error ?? "save failed")
        XCTAssertEqual(session.draft, "head copy\n"); XCTAssertFalse(session.isDirty)
    }

    func testStashTrackedAndUntrackedCopiesDoNotChangeStashOrIndex() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("stashed\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("untracked stash\n".utf8).write(to: root.appendingPathComponent("extra.txt"))
        _ = try await GitProcess.run(at: root, arguments: ["stash", "push", "-u", "-m", "Copy fixture"])
        let stash = try await repo.workflowRevision("stash@{0}")
        for (path, revision, original) in [("file.txt", stash, "stashed\n"), ("extra.txt", stash + "^3", "untracked stash\n")] {
            let session = FileCompareSession(repository: repo, path: path, target: .commit(hash: revision, path: path))
            await session.reload(); XCTAssertNil(session.error); XCTAssertEqual(session.draft, original)
            let before = try await repo.fileComparison(path: path)
            session.edit("worktree", text: "edited " + original)
            let saved = await session.save(); XCTAssertTrue(saved, session.error ?? "save failed")
            let after = try await repo.fileComparison(path: path)
            XCTAssertEqual(after.index.data, before.index.data); XCTAssertEqual(after.head.data, before.head.data)
            XCTAssertEqual(after.worktree.text, "edited " + original)
            let source = try await repo.comparisonPreview(target: .commit(hash: revision, path: path))
            XCTAssertEqual(source.worktree.text, original)
        }
        let afterStash = try await repo.workflowRevision("stash@{0}"); XCTAssertEqual(afterStash, stash)
    }

    func testExternalWritesRejectSaveAndKeepEveryDraft() async throws {
        let (root, repo, hash) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repo, path: "file.txt", target: .commit(hash: hash, path: "file.txt"))
        await session.reload()
        session.edit("head", text: "parent draft\n"); session.edit("worktree", text: "history draft\n")
        try Data("external\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let saved = await session.save(); XCTAssertFalse(saved); XCTAssertNotNil(session.error)
        XCTAssertTrue(session.isDirty("head")); XCTAssertTrue(session.isDirty("worktree"))
        XCTAssertEqual(session.text(in: "head"), "parent draft\n"); XCTAssertEqual(session.draft, "history draft\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "external\n")
        try Data("current\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("external index\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repo.stage(paths: ["file.txt"])
        try Data("current\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let staleIndexSave = await session.save(); XCTAssertFalse(staleIndexSave)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt"), encoding: .utf8), "current\n")
        XCTAssertTrue(session.isDirty("head")); XCTAssertTrue(session.isDirty("worktree"))
    }

    func testDeletedExecutableCanBeRestoredWithoutOverwritingNewFileOrFollowingSymlink() async throws {
        let (root, repo, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("scripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("run.sh")
        try Data("#!/bin/sh\necho historical\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try await repo.stage(paths: ["scripts/run.sh"]); try await repo.commit(message: "Executable")
        let hash = try await repo.workflowRevision("HEAD")
        try FileManager.default.removeItem(at: directory)
        _ = try await GitProcess.run(at: root, arguments: ["add", "-u"]); try await repo.commit(message: "Remove executable")
        let session = FileCompareSession(repository: repo, path: "scripts/run.sh", target: .commit(hash: hash, path: "scripts/run.sh"))
        await session.reload(); XCTAssertFalse(session.savedWorktree?.exists ?? true)
        let missing = try XCTUnwrap(session.savedWorktree)
        session.edit("worktree", text: "#!/bin/sh\necho edited\n")
        let saved = await session.save(); XCTAssertTrue(saved, session.error ?? "save failed")
        let after = try await repo.fileComparison(path: "scripts/run.sh")
        XCTAssertEqual(after.worktree.gitMode, "100755"); XCTAssertFalse(after.index.exists)
        do { _ = try await repo.saveWorktree(path: "scripts/run.sh", text: "overwrite", expected: missing); XCTFail("Must reject a newly created file") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "#!/bin/sh\necho edited\n")
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        do { _ = try await repo.saveWorktree(path: "scripts/run.sh", text: "escape", expected: missing); XCTFail("Must reject symlink parents") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("run.sh").path))
    }

    func testEachNativePaneRetainsUndoAndSearchTargetsFocusedCopyAcrossLayouts() async throws {
        _ = NSApplication.shared
        var values = ["head": "left left\n", "worktree": "right\n", "index": "middle\n"]
        let commands = ComparisonEditingCommands()
        func model(_ ids: [String]) -> ComparisonEditor {
            ComparisonEditor(columns: ids.map { ComparisonEditorColumn(id: $0, title: $0, text: values[$0]!, isEditable: true, message: nil, preservesUndo: true) },
                             wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "left", navigation: 0, changeNavigation: 0,
                             onEdit: { values[$0] = $1 }, editingCommands: commands)
        }
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 260)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model(["head", "worktree"]))
        coordinator.split = split; coordinator.update(coordinator.model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution(); coordinator.alignDisplay()
        func editors(_ view: NSView) -> [UndoableComparisonTextView] {
            ([view as? UndoableComparisonTextView].compactMap { $0 }) + view.subviews.flatMap(editors)
        }
        let left = try XCTUnwrap(editors(split).first(where: { $0.string == values["head"] }))
        coordinator.active = left
        coordinator.navigate(forward: true)
        XCTAssertEqual(left.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertNil(commands.replaceSearch(options: ComparisonSearchOptions(query: "left"), replacement: "changed", all: true))
        XCTAssertEqual(values["head"], "changed changed\n"); XCTAssertEqual(values["worktree"], "right\n")
        coordinator.update(model(["head", "index", "worktree"])); split.resetDistribution(); coordinator.alignDisplay()
        XCTAssertTrue(editors(split).contains(where: { $0 === left }))
        coordinator.active = left
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(commands.canUndo)
        commands.undo(); XCTAssertEqual(values["head"], "left left\n")
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(commands.canRedo)
        commands.redo(); XCTAssertEqual(values["head"], "changed changed\n")
        let right = try XCTUnwrap(editors(split).first(where: { $0.string == "right\n" }))
        window.makeFirstResponder(right); coordinator.active = right
        right.insertText(" typed", replacementRange: NSRange(location: 5, length: 0))
        XCTAssertEqual(values["worktree"], "right typed\n")
        for _ in 0..<5 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(commands.canUndo)
        commands.undo(); XCTAssertEqual(values["worktree"], "right\n")
        XCTAssertEqual(values["head"], "changed changed\n")
    }
}
