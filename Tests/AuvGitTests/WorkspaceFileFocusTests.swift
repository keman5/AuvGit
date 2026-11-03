import AppKit
import XCTest
import Combine
@testable import AuvGit

@MainActor
final class WorkspaceFileFocusTests: XCTestCase {
    private final class FileRows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    }

    func testProjectDefaultRoutesSelectAllToFilesWithoutMovingSidebarResponder() async throws {
        let (window, list, _, _, focus) = fixture()
        defer { window.close() }
        let rows = FileRows()
        let files = NSTableView(frame: list.bounds)
        files.addTableColumn(NSTableColumn(identifier: .init("files")))
        files.allowsMultipleSelection = true; files.dataSource = rows
        list.addSubview(files); files.reloadData()
        let sidebar = NSTableView(frame: NSRect(x: 300, y: 0, width: 250, height: 300))
        sidebar.addTableColumn(NSTableColumn(identifier: .init("repositories")))
        sidebar.allowsMultipleSelection = true; sidebar.dataSource = rows
        window.contentView!.addSubview(sidebar); sidebar.reloadData()
        let appearance = NativeFocusAppearance.forWindow(window)
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        focus.setDefaultScope(true); appearance.defaultFileScope = focus
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        focus.handle(key)
        XCTAssertTrue(appearance.handle(key))
        await Task.yield()
        XCTAssertEqual(files.selectedRowIndexes, IndexSet(integersIn: 0..<3))
        XCTAssertTrue(sidebar.selectedRowIndexes.isEmpty)
        XCTAssertTrue(window.firstResponder === sidebar)
        XCTAssertTrue(focus.hasFileFocus)
        XCTAssertFalse(appearance.isVisible)
        let oldEditor = NSTextView(frame: list.frame)
        oldEditor.string = "inactive project draft"
        window.contentView!.addSubview(oldEditor, positioned: .below, relativeTo: list)
        XCTAssertTrue(window.makeFirstResponder(oldEditor))
        oldEditor.setSelectedRange(NSRange(location: 0, length: 0))
        files.deselectAll(nil)
        XCTAssertTrue(appearance.handle(key))
        XCTAssertEqual(files.selectedRowIndexes, IndexSet(integersIn: 0..<3))
        XCTAssertEqual(oldEditor.selectedRange().length, 0, "A retained project's editor must not swallow file selection")
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        try await click(NSPoint(x: 400, y: 100), in: window, focus: focus)
        XCTAssertFalse(focus.hasFileFocus)
        XCTAssertFalse(focus.usesDefaultScope)
        focus.setDefaultScope(true)
        XCTAssertTrue(focus.hasFileFocus, "Returning to the project restores file command ownership")
        XCTAssertTrue(window.firstResponder === sidebar)
        focus.setDefaultScope(false)
        XCTAssertFalse(focus.hasFileFocus, "Inactive projects must release their command scope")
        withExtendedLifetime(rows) {}
    }

    func testDefaultFileScopePreservesTextEditingAndReleasesOnTab() async throws {
        let (window, _, _, _, focus) = fixture()
        defer { window.close() }
        let appearance = NativeFocusAppearance.forWindow(window)
        let editor = NSTextView(frame: NSRect(x: 300, y: 0, width: 250, height: 300))
        editor.string = "commit message"
        window.contentView!.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        focus.setDefaultScope(true); appearance.defaultFileScope = focus
        let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(appearance.handle(selectAll))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(window.firstResponder === editor)
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        focus.handle(tab)
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertFalse(focus.usesDefaultScope)
        XCTAssertFalse(focus.hasFileFocus)
    }

    func testFocusIgnoresOverlappingBackgroundProjectTables() throws {
        let (window, list, _, _, focus) = fixture()
        defer { window.close() }
        let background = NSTableView(frame: list.bounds)
        background.addTableColumn(NSTableColumn(identifier: .init("background")))
        list.addSubview(background)
        let foreground = NSTableView(frame: list.bounds)
        foreground.addTableColumn(NSTableColumn(identifier: .init("foreground")))
        list.addSubview(foreground)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(focus.focus(in: window))
        XCTAssertTrue(window.firstResponder === foreground,
                      "A retained project's table at the same coordinates must not receive file commands")
        foreground.isHidden = true
        XCTAssertTrue(focus.focus(in: window))
        XCTAssertTrue(window.firstResponder === background)
    }

    func testProgrammaticFocusChoosesNativeResponderInsideMarkedPane() throws {
        let (window, list, _, _, focus) = fixture()
        defer { window.close() }
        let table = NSTableView(frame: list.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        list.addSubview(table)
        let outside = NSTextView(frame: NSRect(x: 300, y: 0, width: 250, height: 300))
        window.contentView!.addSubview(outside)
        window.contentView?.layoutSubtreeIfNeeded()
        let appearance = NativeFocusAppearance.forWindow(window)
        XCTAssertTrue(window.makeFirstResponder(outside))
        XCTAssertTrue(focus.focus(in: window))
        appearance.apply()
        XCTAssertTrue(window.firstResponder === table)
        XCTAssertFalse(appearance.isVisible, "Explicit content selection does not reveal keyboard rings")
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
