import AppKit
import SwiftUI
import XCTest
@testable import AuvGit

/// Never show or key a test window: only its native responder chain is exercised.
@MainActor
final class ComparisonSearchShortcutFocusTests: XCTestCase {
    private final class BackgroundWindow: NSWindow {
        override func makeKey() {}
    }

    func testFirstShortcutWaitsForPresentationAndRepeatedShortcutSelectsQuery() throws {
        _ = NSApplication.shared
        let window = BackgroundWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let region = ComparisonKeyboardRegion.RegionView(frame: window.contentView!.bounds)
        window.contentView = region
        region.standalone = true
        defer { window.close() }
        var openings = 0
        region.action = { command in
            XCTAssertEqual(command, .compareFind)
            openings += 1
            return true
        }
        XCTAssertNil(region.handle(try findEvent(in: window, flags: .shift)))
        XCTAssertEqual(openings, 1)
        // Field creation can occur after the shortcut's next-run-loop attempt.
        drain(region)
        let host = searchHost()
        region.addSubview(host)
        drain(host)
        let query = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == comparisonSearchText("Find") })
        let replacement = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == comparisonSearchText("Replace with") })
        XCTAssertNil(query.currentEditor(), "Ordinary presentation still waits for an explicit focus action")
        NotificationCenter.default.post(name: NSPopover.didShowNotification, object: NSPopover())
        drain(host)
        assertSelected(query, in: window)
        XCTAssertFalse(window.isVisible)

        for flags: NSEvent.ModifierFlags in [.shift, .command, .control] {
            window.makeFirstResponder(replacement)
            XCTAssertNil(region.handle(try findEvent(in: window, flags: flags)))
            assertSelected(query, in: window)
        }
        XCTAssertEqual(openings, 1, "Refocusing must reuse the existing search")
        XCTAssertNotNil(region.handle(try findEvent(in: window, flags: .shift)), "Typing uppercase F in the query must remain native")
        XCTAssertFalse(window.isVisible)
    }

    func testCancelledShortcutCannotFocusALaterMousePresentation() throws {
        _ = NSApplication.shared
        let window = BackgroundWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let region = ComparisonKeyboardRegion.RegionView(frame: window.contentView!.bounds)
        window.contentView = region; region.standalone = true; region.action = { _ in true }
        defer { window.close() }
        XCTAssertNil(region.handle(try findEvent(in: window, flags: .shift)))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNotNil(region.handle(escape))
        let host = searchHost(); region.addSubview(host); drain(host)
        NotificationCenter.default.post(name: NSPopover.didShowNotification, object: NSPopover())
        let query = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == comparisonSearchText("Find") })
        XCTAssertNil(query.currentEditor())
        XCTAssertFalse(window.isVisible)
    }

    private func searchHost() -> NSHostingView<ComparisonSearchPopover> {
        let host = NSHostingView(rootView: ComparisonSearchPopover(options: .constant(.init(query: "🙂existing")),
            replacement: .constant("replacement"), matchCount: 0, onNavigate: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 270)
        return host
    }
    private func findEvent(in window: NSWindow, flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "F", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
    }
    private func assertSelected(_ field: NSTextField, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.firstResponder === field.currentEditor(), file: file, line: line)
        XCTAssertEqual((field.currentEditor() as? NSTextView)?.selectedRange(),
            NSRange(location: 0, length: field.stringValue.utf16.count), file: file, line: line)
    }
    private func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    private func drain(_ view: NSView) {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
