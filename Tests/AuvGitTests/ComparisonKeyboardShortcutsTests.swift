import AppKit
import XCTest
@testable import AuvGit

@MainActor
final class ComparisonKeyboardShortcutsTests: XCTestCase {
    func testRoutingUsesAssignedComparisonBindingsAndPreservesNativeEditing() throws {
        let name = "ComparisonKeyboardShortcutsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let shortcuts = KeyboardShortcuts(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let region = ComparisonKeyboardRegion.RegionView()
        window.contentView = region; region.shortcuts = shortcuts; region.standalone = true
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        var invoked: [ShortcutCommand] = []
        region.action = { invoked.append($0); return true }
        func event(_ value: ShortcutBinding) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: value.eventModifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: String(value.character), charactersIgnoringModifiers: String(value.character), isARepeat: false, keyCode: 0))
        }
        XCTAssertNil(region.handle(try event(shortcuts.binding(.compareReload))))
        XCTAssertEqual(invoked, [.compareReload])
        XCTAssertNil(region.handle(try event(shortcuts.binding(.compareFind))))
        XCTAssertNil(region.handle(try event(shortcuts.binding(.compareNextChange))))
        XCTAssertEqual(invoked, [.compareReload, .compareFind, .compareNextChange])
        XCTAssertNil(region.handle(try event(.init(key: "f", modifiers: 8))))
        XCTAssertEqual(invoked.removeLast(), .compareFind)
        XCTAssertNotNil(region.handle(try event(.init(key: "f", modifiers: 10))))
        XCTAssertNotNil(region.handle(try event(.init(key: "z", modifiers: 1))))
        XCTAssertTrue(shortcuts.set(.init(key: "F12", modifiers: 4), for: .compareReload))
        XCTAssertNil(region.handle(try event(shortcuts.binding(.compareReload))))
        XCTAssertTrue(shortcuts.setEnabled(false, for: .compareReload))
        let disabledEvent = try event(shortcuts.binding(.compareReload))
        XCTAssertNotNil(region.handle(disabledEvent))
        XCTAssertEqual(invoked.count, 4)
        XCTAssertTrue(shortcuts.setEnabled(true, for: .compareReload))
        XCTAssertNil(region.handle(disabledEvent))
        XCTAssertEqual(invoked.last, .compareReload)
        invoked.removeLast()
        let fieldEditor = NSTextView(); fieldEditor.isFieldEditor = true
        region.addSubview(fieldEditor); window.makeFirstResponder(fieldEditor)
        XCTAssertNotNil(region.handle(try event(shortcuts.binding(.compareReload))))
        XCTAssertEqual(invoked, [.compareReload, .compareFind, .compareNextChange, .compareReload])
        window.makeFirstResponder(nil); region.standalone = false
        XCTAssertNotNil(region.handle(try event(shortcuts.binding(.compareReload))))
        region.standalone = true; region.action = { _ in false }
        XCTAssertNil(region.handle(try event(shortcuts.binding(.compareReload))), "Owned but disabled comparison commands must not reach app actions")
    }
    func testTakeBlockUsesVisualSourceDirectionAndRemainsUndoable() throws {
        _ = NSApplication.shared
        let commands = ComparisonEditingCommands()
        let resolver = ComparisonResolverState()
        let conflict = "<<<<<<< HEAD\nleft\n=======\nright\n>>>>>>> topic\n"
        let model = ComparisonEditor(columns: [
            .init(id: "ours", title: "Left", text: "left\n", isEditable: false, message: nil),
            .init(id: "worktree", title: "Result", text: conflict, isEditable: true, message: nil, preservesUndo: true),
            .init(id: "theirs", title: "Right", text: "right\n", isEditable: false, message: nil)
        ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, resolver: resolver, editingCommands: commands)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(model); coordinator.split = split; coordinator.update(model)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = split; window.isReleasedWhenClosed = false; defer { window.close() }
        let scrolls = split.subviews.compactMap { $0.subviews.compactMap { $0 as? NSScrollView }.first }
        let result = try XCTUnwrap(scrolls[1].documentView as? NSTextView)
        XCTAssertTrue(commands.takeBlock(fromLeft: true)); XCTAssertEqual(result.string, "left\n")
        result.undoManager?.undo(); XCTAssertEqual(result.string, conflict)
        XCTAssertTrue(commands.takeBlock(fromLeft: false)); XCTAssertEqual(result.string, "right\n")
        XCTAssertFalse(commands.takeBlock(fromLeft: true), "No unresolved block remains")
    }

}
