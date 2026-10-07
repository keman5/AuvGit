import AppKit
import XCTest
@testable import RayGit

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    private func event(_ characters: String, flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
    func testKeyCapturePreservesButtonsAndRecordsPhysicalModifiers() {
        let draft = ShortcutBinding(key: "a", modifiers: 5)
        XCTAssertEqual(recordedShortcut(event("b"), preserving: draft), .init(key: "b", modifiers: 5))
        XCTAssertEqual(recordedShortcut(event("C", flags: [.command]), preserving: draft), .init(key: "c", modifiers: 1))
        XCTAssertEqual(recordedShortcut(event(String(UnicodeScalar(NSF20FunctionKey)!)), preserving: draft)?.key, "F20")
        XCTAssertEqual(recordedShortcut(event("\r"), preserving: draft)?.key, "Return")
        XCTAssertEqual(recordedShortcut(event("?", flags: [.control, .shift]), preserving: draft), .init(key: "?", modifiers: 10))
        XCTAssertNil(recordedShortcut(event("\u{1b}"), preserving: draft))
    }
    func testFocusedRecorderConsumesCommandEquivalentAndEscapeCancels() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 150, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ShortcutRecorder.RecorderView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        var captured: ShortcutBinding?
        view.onChange = { captured = $0 }
        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertTrue(view.performKeyEquivalent(with: event("c", flags: [.command])))
        XCTAssertEqual(captured, .init(key: "c", modifiers: 1))
        view.keyDown(with: event("\u{1b}", keyCode: 53))
        XCTAssertFalse(window.firstResponder === view)
    }
    private final class MenuTarget: NSObject {
        var invoked = false
        @objc func open(_ sender: Any?) { invoked = true }
    }
    func testApplicationDispatchCapturesBeforeCommandMenu() {
        let application = NSApplication.shared
        let originalMenu = application.mainMenu
        defer { application.mainMenu = originalMenu }
        let target = MenuTarget()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Open", action: #selector(MenuTarget.open(_:)), keyEquivalent: "o")
        item.target = target
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
        application.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 150, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = ShortcutRecorder.RecorderView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(view)
        var captured: ShortcutBinding?
        view.onChange = { captured = $0 }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view))
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "o", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31)!
        application.sendEvent(key)
        XCTAssertEqual(captured, .init(key: "o", modifiers: 1))
        XCTAssertFalse(target.invoked)
        XCTAssertFalse(window.firstResponder === view)
    }

}
