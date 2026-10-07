import AppKit
import XCTest
import Combine
@testable import RayGit

@MainActor
final class WorkspaceFileFocusTests: XCTestCase {
    func testProgrammaticFocusChoosesNativeResponderInsideMarkedPane() throws {
        let (window, list, _, _, focus) = fixture()
        defer { window.close() }
        let table = NSTableView(frame: list.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        list.addSubview(table)
        let outside = NSTextView(frame: NSRect(x: 300, y: 0, width: 250, height: 300))
        window.contentView!.addSubview(outside)
        window.orderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(outside))
        XCTAssertTrue(focus.focus(in: window))
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertFalse(focus.focus(in: window, text: true))
        table.isHidden = true
        XCTAssertFalse(focus.focus(in: window))
    }
    private final class KeyboardButton: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }
    private func fixture() -> (NSWindow, NSView, NSView, NSButton, WorkspaceFileFocus) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = content
        let list = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 350))
        let toolbar = NSView(frame: NSRect(x: 0, y: 350, width: 600, height: 50))
        let button = KeyboardButton(frame: NSRect(x: 350, y: 100, width: 100, height: 30))
        content.addSubview(list); content.addSubview(toolbar); content.addSubview(button)
        let focus = WorkspaceFileFocus()
        focus.register(list, toolbar: false); focus.register(toolbar, toolbar: true)
        return (window, list, toolbar, button, focus)
    }
    private func click(_ point: NSPoint, in window: NSWindow, focus: WorkspaceFileFocus) async throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        focus.handle(event)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        focus.handle(up)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    func testScopeUpdatesImmediatelyWithoutRebuildingInsideMouseTracking() async throws {
        let (window, _, _, _, focus) = fixture()
        defer { window.close() }
        var invalidations = 0
        let observation = focus.objectWillChange.sink { invalidations += 1 }
        defer { observation.cancel() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        focus.handle(event)
        XCTAssertTrue(focus.hasFileFocus, "Toolbar commands must see selected scope even if the table consumes mouseUp")
        XCTAssertEqual(invalidations, 0, "Do not rebuild the hosting tree inside the mouse monitor")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(invalidations, 1)
        focus.handle(event)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(invalidations, 1, "Repeated same-scope clicks must not invalidate the table")
    }
    func testFocusRegionDoesNotInterceptFileClicks() {
        let region = WorkspaceFileFocusRegion.RegionView(frame: NSRect(x: 0, y: 0, width: 250, height: 350))
        XCTAssertNil(region.hitTest(NSPoint(x: 100, y: 100)))
    }
    func testListClickThenToolbarRetainsSelectionScope() async throws {
        let (window, _, _, _, focus) = fixture()
        defer { window.close() }
        try await click(NSPoint(x: 100, y: 100), in: window, focus: focus)
        XCTAssertTrue(focus.hasFileFocus)
        try await click(NSPoint(x: 100, y: 375), in: window, focus: focus)
        XCTAssertTrue(focus.hasFileFocus)
    }
    func testOtherPaneClickThenToolbarRetainsGlobalScope() async throws {
        let (window, _, _, _, focus) = fixture()
        defer { window.close() }
        try await click(NSPoint(x: 100, y: 100), in: window, focus: focus)
        try await click(NSPoint(x: 400, y: 100), in: window, focus: focus)
        XCTAssertFalse(focus.hasFileFocus)
        try await click(NSPoint(x: 100, y: 375), in: window, focus: focus)
        XCTAssertFalse(focus.hasFileFocus)
    }
    func testKeyboardFocusToOutsideButtonClearsSelectionScope() async throws {
        let (window, _, _, button, focus) = fixture()
        defer { window.close() }
        try await click(NSPoint(x: 100, y: 100), in: window, focus: focus)
        window.initialFirstResponder = button
        XCTAssertTrue(window.makeFirstResponder(button))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        focus.handle(event)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertFalse(focus.hasFileFocus)
    }
}
