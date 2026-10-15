import AppKit
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class HistoryKeyboardShortcutsTests: XCTestCase {
    func testEmbeddedHistoryLeavesFileShortcutsToTheFocusedTable() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let region = HistoryKeyboardRegion.RegionView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        region.paneScoped = true
        window.contentView!.addSubview(region)
        let files = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        files.addTableColumn(NSTableColumn(identifier: .init("file")))
        let scroll = NSScrollView(frame: NSRect(x: 250, y: 0, width: 200, height: 300))
        scroll.documentView = files
        window.contentView!.addSubview(scroll)
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(files))
        var calls = 0
        region.action = { _ in calls += 1 }; region.find = { calls += 1 }; region.showChanges = { calls += 1 }
        let inputs: [(String, NSEvent.ModifierFlags)] = [("c", .command), ("\r", []), ("f", .command)]
        for (characters, flags) in inputs {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
            XCTAssertNotNil(region.handle(event))
        }
        XCTAssertEqual(calls, 0)
        scroll.setFrameOrigin(.zero)
        for (characters, flags) in inputs {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
            XCTAssertNil(region.handle(event))
        }
        XCTAssertEqual(calls, 3)
    }
    func testGraphNavigationUsesRelationshipsRatherThanAdjacentRows() {
        func commit(_ hash: String, _ parents: [String]) -> GitCommit {
            GitCommit(hash: hash, parents: parents, author: "A", date: .distantPast, subject: hash, body: "", refs: [])
        }
        let commits = [commit("merge", ["main", "topic"]), commit("unrelated", ["other"]), commit("topic", ["base"]), commit("main", ["base"]), commit("base", [])]
        XCTAssertEqual(HistoryCommitNavigation.target(commits: commits, selection: "merge", child: false), "main")
        XCTAssertEqual(HistoryCommitNavigation.target(commits: commits, selection: "topic", child: true), "merge")
        XCTAssertNil(HistoryCommitNavigation.target(commits: commits, selection: "base", child: false))
        XCTAssertNil(HistoryCommitNavigation.target(commits: commits, selection: "unrelated", child: false))
        XCTAssertNil(HistoryCommitNavigation.target(commits: commits, selection: nil, child: true))
    }
    func testWindowCommandsPreserveNativeEditingAndModalScope() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        let region = HistoryKeyboardRegion.RegionView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let table = NSTableView(frame: region.frame)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit")))
        let scroll = NSScrollView(frame: region.frame)
        scroll.documentView = table
        content.addSubview(scroll); content.addSubview(region)
        let suite = "HistoryKeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        region.shortcuts = KeyboardShortcuts(defaults: defaults)
        var actions: [HistoryAction] = []
        var navigation: [Bool] = []
        var changes = 0
        region.navigate = { navigation.append($0) }; region.showChanges = { changes += 1 }
        var finds = 0
        region.action = { actions.append($0) }; region.find = { finds += 1 }
        func key(_ value: String, _ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: 0))
        }
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertFalse(table.visibleRect.isEmpty)
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSUpArrowFunctionKey)!), .option)))
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSDownArrowFunctionKey)!), .option)))
        XCTAssertEqual(navigation, [true, false])
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSF4FunctionKey)!), [])))
        XCTAssertEqual(changes, 1)
        XCTAssertNil(region.handle(try key("r")))
        XCTAssertNil(region.handle(try key("r", [.command, .shift])))
        XCTAssertNil(region.handle(try key("c")))
        XCTAssertNil(region.handle(try key("l")))
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSF7FunctionKey)!), [])))
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSF7FunctionKey)!), .shift)))
        XCTAssertNil(region.handle(try key("\r", [])))
        XCTAssertNil(region.handle(try key("f")))
        XCTAssertEqual(actions, [.reset, .resetAdvanced, .copyMessage, .viewLog, .createBranch, .createTag, .show]); XCTAssertEqual(finds, 1)
        XCTAssertNotNil(region.handle(try key("r", [.command, .option])))
        let editor = NSTextView(frame: region.frame); content.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(region.handle(try key(String(UnicodeScalar(NSUpArrowFunctionKey)!), .option)))
        XCTAssertNotNil(region.handle(try key("g")))
        XCTAssertNotNil(region.handle(try key("d")))
        XCTAssertNotNil(region.handle(try key("k", [.command, .shift])))
        XCTAssertNotNil(region.handle(try key(String(UnicodeScalar(NSF4FunctionKey)!), [])))
        XCTAssertEqual(navigation, [true, false]); XCTAssertEqual(changes, 1)
        XCTAssertNil(region.handle(try key("r")))
        XCTAssertNil(region.handle(try key("f")))
        XCTAssertNotNil(region.handle(try key("c")))
        XCTAssertNotNil(region.handle(try key("\r", [])))
        editor.isEditable = false
        XCTAssertNotNil(region.handle(try key("c")))
        let field = NSTextField(frame: region.frame); content.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertNil(region.handle(try key("r", [.command, .shift])))
        XCTAssertNotNil(region.handle(try key("c")))
        XCTAssertNotNil(region.handle(try key("\r", [])))
        let other = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        other.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("other")))
        let otherScroll = NSScrollView(frame: NSRect(x: 250, y: 0, width: 200, height: 300))
        otherScroll.documentView = other; content.addSubview(otherScroll)
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertTrue(window.firstResponder === other)
        XCTAssertNotNil(region.handle(try key("c")), "Reference lists must retain their own copy command")
        XCTAssertNil(region.handle(try key("r")))
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(region.handle(try key("l")))
        XCTAssertEqual(actions.count, 11)
        let unrelatedWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let unrelatedEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: unrelatedWindow.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 0))
        XCTAssertNotNil(region.handle(unrelatedEvent))
        region.isHidden = true
        XCTAssertNotNil(region.handle(try key("r")))
        region.isHidden = false
        XCTAssertTrue(region.shortcuts.set(.init(key: "F8", modifiers: 6), for: .reset))
        XCTAssertNotNil(region.handle(try key("r")))
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSF8FunctionKey)!), [.shift, .option])))
        XCTAssertEqual(actions.last, .reset)
        XCTAssertEqual(actions.count, 12)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(region.shortcuts.set(.init(key: "b", modifiers: 5), for: .copyHash))
        XCTAssertNil(region.handle(try key("b", [.command, .option])))
        XCTAssertEqual(actions.last, .copyHash)
        XCTAssertNotNil(region.handle(try key("c")))
        XCTAssertTrue(region.shortcuts.set(.init(key: "j", modifiers: 5), for: .show))
        XCTAssertNil(region.handle(try key("j", [.command, .option])))
        XCTAssertEqual(actions.last, .show)
        XCTAssertNotNil(region.handle(try key("\r", [])))
        XCTAssertTrue(window.makeFirstResponder(table))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNotNil(region.handle(try key(String(UnicodeScalar(NSF8FunctionKey)!), [.shift, .option])))
        XCTAssertEqual(actions.count, 14)
        window.endSheet(sheet)
        let comparison = ReadOnlyDiffTextView(frame: region.frame)
        content.addSubview(comparison)
        XCTAssertTrue(window.makeFirstResponder(comparison))
        XCTAssertNotNil(region.handle(try key("f")))
        XCTAssertNotNil(region.handle(try key("g")))
        XCTAssertNotNil(region.handle(try key(String(UnicodeScalar(NSF6FunctionKey)!), [])))
        XCTAssertEqual(actions.count, 14)
        let terminal = TerminalSession(directory: FileManager.default.temporaryDirectory).view
        terminal.frame = region.frame
        content.addSubview(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        let actionCount = actions.count, findCount = finds, navigationCount = navigation.count, changeCount = changes
        for event in [
            try key("\r", []),
            try key("f"),
            try key("r"),
            try key(String(UnicodeScalar(NSUpArrowFunctionKey)!), .option),
            try key(String(UnicodeScalar(NSF4FunctionKey)!), [])
        ] {
            XCTAssertNotNil(region.handle(event))
        }
        XCTAssertEqual(actions.count, actionCount)
        XCTAssertEqual(finds, findCount)
        XCTAssertEqual(navigation.count, navigationCount)
        XCTAssertEqual(changes, changeCount)
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertNil(region.handle(try key("f")))
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertNil(region.handle(try key("f")))
        XCTAssertTrue(region.shortcuts.setEnabled(false, for: .copyHash))
        let count = actions.count
        XCTAssertNotNil(region.handle(try key("b", [.command, .option])))
        XCTAssertEqual(actions.count, count)
        XCTAssertTrue(region.shortcuts.setEnabled(true, for: .copyHash))
        XCTAssertNil(region.handle(try key("b", [.command, .option])))
        XCTAssertEqual(actions.last, .copyHash)
        XCTAssertEqual(actions.count, count + 1)
        XCTAssertTrue(region.shortcuts.setEnabled(false, for: .copyMessage))
        XCTAssertTrue(region.shortcuts.set(.init(key: "c", modifiers: 1), for: .copyHash))
        XCTAssertNil(region.handle(try key("c")))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertNotNil(region.handle(try key("c")))
        XCTAssertEqual(actions.count, count + 2)
    }
}
