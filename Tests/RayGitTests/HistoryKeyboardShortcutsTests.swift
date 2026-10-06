import AppKit
import XCTest
@testable import RayGit

@MainActor
final class HistoryKeyboardShortcutsTests: XCTestCase {
    func testWindowCommandsPreserveNativeEditingAndModalScope() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try XCTUnwrap(window.contentView)
        let region = HistoryKeyboardRegion.RegionView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let table = NSTableView(frame: region.frame)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("commit")))
        let scroll = NSScrollView(frame: region.frame)
        scroll.documentView = table
        content.addSubview(scroll); content.addSubview(region)
        var actions: [HistoryAction] = []
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
        XCTAssertNil(region.handle(try key("r")))
        XCTAssertNil(region.handle(try key("r", [.command, .shift])))
        XCTAssertNil(region.handle(try key("c")))
        XCTAssertNil(region.handle(try key("l")))
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSF7FunctionKey)!), [])))
        XCTAssertNil(region.handle(try key(String(UnicodeScalar(NSF7FunctionKey)!), .shift)))
        XCTAssertNil(region.handle(try key("\r", [])))
        XCTAssertNil(region.handle(try key("f")))
        XCTAssertEqual(actions, [.reset, .resetAdvanced, .copyHash, .viewLog, .createBranch, .createTag, .show]); XCTAssertEqual(finds, 1)
        XCTAssertNotNil(region.handle(try key("r", [.command, .option])))
        let editor = NSTextView(frame: region.frame); content.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
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
        XCTAssertTrue(window.makeFirstResponder(table))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertNotNil(region.handle(try key("r")))
        XCTAssertEqual(actions.count, 11)
        window.endSheet(sheet)
    }
}
