import AppKit
import SwiftUI
import XCTest
@testable import RayGit

@MainActor
final class NativeFocusAppearanceTests: XCTestCase {
    private final class CountingView: NSView {
        var subtreeReads = 0
        override var subviews: [NSView] {
            get { subtreeReads += 1; return super.subviews }
            set { super.subviews = newValue }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { self }
    }

    func testContextMarkerLookupVisitsDeepHierarchyOnce() throws {
        let window = window()
        defer { window.close() }
        let depth = 12
        let views = (0..<depth).map { _ in CountingView(frame: NSRect(x: 0, y: 0, width: 240, height: 100)) }
        window.contentView = views[0]
        for index in 1..<depth { views[index - 1].addSubview(views[index]) }
        let marker = ContextRowMarker(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        views[depth - 1].addSubview(marker)
        views.forEach { $0.subtreeReads = 0 }
        let point = marker.convert(NSPoint(x: 30, y: 13), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let focus = NativeContextRowFocus()

        focus.handle(event, in: window)

        XCTAssertLessThanOrEqual(views.reduce(0) { $0 + $1.subtreeReads }, depth * 2,
                                 "Context clicks must not repeatedly search nested subtrees")
        XCTAssertEqual(views[depth - 1].subviews.count, 2, "The matching row must still receive a highlight")
        focus.clear()
        XCTAssertEqual(views[depth - 1].subviews.count, 1)
    }

    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 3 }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { "Row \(row)" }
    }

    func testButtonRowContextHighlightUsesRowBoundsAndDoesNotInterceptClicks() async throws {
        let window = window()
        defer { window.close() }
        let host = NSHostingView(rootView: VStack {
            Button("Repository") {}.frame(width: 240, height: 26).contextRowFocus()
            Button("Other") {}.frame(width: 240, height: 26).contextRowFocus()
        })
        window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        func markers(in view: NSView) -> [ContextRowMarker] {
            (view as? ContextRowMarker).map { [$0] } ?? view.subviews.flatMap { markers(in: $0) }
        }
        let marker = try XCTUnwrap(markers(in: host).first)
        let parent = try XCTUnwrap(marker.superview)
        let siblings = Set(parent.subviews.map(ObjectIdentifier.init))
        let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        let appearance = NativeFocusAppearance.forWindow(window)
        let responder = window.firstResponder
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        appearance.handle(event)
        let highlight = try XCTUnwrap(parent.subviews.first { !siblings.contains(ObjectIdentifier($0)) })
        XCTAssertEqual(highlight.frame, parent.convert(marker.bounds, from: marker))
        XCTAssertNil(highlight.hitTest(.zero))
        XCTAssertTrue(window.firstResponder === responder)
        appearance.handle(key(53, in: window))
        XCTAssertNil(highlight.superview)
    }

    func testContextClickHighlightsTargetWithoutChangingSelectionOrKeyboardFocus() throws {
        let window = window()
        defer { window.close() }
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let rows = Rows()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
        table.dataSource = rows; table.allowsMultipleSelection = true
        window.contentView?.addSubview(table)
        table.reloadData()
        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        let appearance = NativeFocusAppearance.forWindow(window)
        let originalResponder = window.firstResponder
        let point = table.convert(NSPoint(x: 40, y: table.rect(ofRow: 1).midY), to: nil)
        func click(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], at location: NSPoint? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location ?? point,
                modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        appearance.handle(try click(.rightMouseDown))
        XCTAssertEqual(appearance.contextRowFocus.highlightedRow, 1)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2]))
        XCTAssertTrue(window.firstResponder === originalResponder)
        XCTAssertFalse(appearance.isVisible, "Context highlighting must not enable keyboard focus rings")
        let highlight = try XCTUnwrap(table.subviews.last)
        XCTAssertEqual(highlight.frame, table.rect(ofRow: 1))
        XCTAssertNil(highlight.hitTest(NSPoint(x: 10, y: 10)), "The highlight must not intercept menu or selection clicks")

        appearance.handle(key(53, in: window))
        XCTAssertNil(appearance.contextRowFocus.highlightedRow)
        XCTAssertNil(highlight.superview)
        appearance.handle(try click(.leftMouseDown, flags: .control))
        XCTAssertEqual(appearance.contextRowFocus.highlightedRow, 1)
        appearance.handle(try click(.leftMouseDown))
        XCTAssertNil(appearance.contextRowFocus.highlightedRow)
        appearance.handle(try click(.rightMouseDown))
        appearance.handle(try click(.rightMouseDown, at: NSPoint(x: 40, y: 130)))
        XCTAssertNil(appearance.contextRowFocus.highlightedRow, "Empty space must not leave a stale target")
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func key(_ code: UInt16, in window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil,
                        characters: code == 48 ? "\t" : "\u{1b}",
                        charactersIgnoringModifiers: code == 48 ? "\t" : "\u{1b}",
                        isARepeat: false, keyCode: code)!
    }

    func testInitialTargetWaitsForTabAndTabRestoresOriginalStyles() throws {
        let window = window()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 240, height: 24))
        let button = NSButton(title: "Next", target: nil, action: nil)
        field.focusRingType = .default
        button.focusRingType = .exterior
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(button)
        let scope = NativeFocusCoordinator()
        scope.attach(to: window)
        scope.register(field, initial: true)
        drain()
        XCTAssertTrue(window.firstResponder === window, "Opening a presentation must not focus a control")
        XCTAssertEqual(field.focusRingType, .none)
        XCTAssertEqual(button.focusRingType, .none)

        let appearance = NativeFocusAppearance.forWindow(window)
        appearance.handle(key(48, in: window, flags: .shift))
        XCTAssertTrue(appearance.isVisible)
        XCTAssertEqual(field.focusRingType, .default)
        XCTAssertEqual(button.focusRingType, .exterior)
    }

    func testMouseHidesRingsWithoutEndingTextEditingAndEscapeClearsFocus() throws {
        let window = window()
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 20, y: 80, width: 240, height: 24))
        field.stringValue = "keep my draft"
        window.contentView?.addSubview(field)
        let scope = NativeFocusCoordinator()
        scope.attach(to: window)
        scope.register(field, initial: true)
        drain()
        window.makeFirstResponder(field)
        let appearance = NativeFocusAppearance.forWindow(window)
        appearance.handle(key(48, in: window))
        let editor = window.firstResponder
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        appearance.handle(click)
        XCTAssertFalse(appearance.isVisible)
        XCTAssertTrue(window.firstResponder === editor)

        appearance.handle(key(48, in: window))
        appearance.handle(key(53, in: window))
        drain()
        XCTAssertFalse(appearance.isVisible)
        XCTAssertTrue(window.firstResponder === window)
        XCTAssertEqual(field.stringValue, "keep my draft")
        appearance.handle(key(48, in: window))
        window.sendEvent(key(48, in: window))
        XCTAssertTrue(appearance.isVisible)
        XCTAssertFalse(window.firstResponder === window, "Tab must re-enter the key-view loop after cancellation")
    }

    func testWindowStateIsSharedButDoesNotLeakIntoOtherPresentations() {
        let first = window(), second = window()
        defer { first.close(); second.close() }
        let a = NativeFocusAppearance.forWindow(first)
        let b = NativeFocusAppearance.forWindow(second)
        XCTAssertTrue(a === NativeFocusAppearance.forWindow(first))
        a.handle(key(48, in: first))
        XCTAssertTrue(a.isVisible)
        XCTAssertFalse(b.isVisible)
        b.handle(key(48, in: first))
        XCTAssertFalse(b.isVisible, "A foreign window event must be ignored")
    }

    func testEditorTabAndShortcutRecordingDoNotEnableNavigationRings() {
        let window = window()
        defer { window.close() }
        let editor = ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80), textContainer: nil)
        window.contentView?.addSubview(editor)
        let appearance = NativeFocusAppearance.forWindow(window)
        window.makeFirstResponder(editor)
        appearance.handle(key(48, in: window))
        XCTAssertFalse(appearance.isVisible)
        appearance.handle(key(48, in: window, flags: .control))
        XCTAssertTrue(appearance.isVisible)
        appearance.handle(key(53, in: window))
        drain()

        let recorder = ShortcutRecorder.RecorderView(frame: NSRect(x: 0, y: 90, width: 150, height: 24))
        window.contentView?.addSubview(recorder)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        appearance.handle(key(48, in: window))
        XCTAssertFalse(appearance.isVisible, "Recording a Tab shortcut is input, not focus navigation")
    }

    func testNewControlsAdoptCurrentModeAndIntentionallyHiddenRingsStayHidden() {
        let window = window()
        defer { window.close() }
        let appearance = NativeFocusAppearance.forWindow(window)
        let field = NSTextField(), hidden = NSTextField()
        field.focusRingType = .default
        hidden.focusRingType = .none
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(hidden)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        XCTAssertEqual(field.focusRingType, .none)
        appearance.handle(key(48, in: window))
        XCTAssertEqual(field.focusRingType, .default)
        XCTAssertEqual(hidden.focusRingType, .none)
    }

    func testDeferredFocusRequestCannotStealFocusBeforeTab() {
        let window = window()
        defer { window.close() }
        let field = NSTextField()
        window.contentView?.addSubview(field)
        let scope = NativeFocusCoordinator()
        scope.attach(to: window)
        scope.register(field, request: UUID())
        drain()
        XCTAssertTrue(window.firstResponder === window)
        window.sendEvent(key(48, in: window))
        XCTAssertTrue(window.firstResponder === field.currentEditor() || window.firstResponder === field)
        XCTAssertTrue(NativeFocusAppearance.isVisible(in: window))
    }

    private func drain() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
