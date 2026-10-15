import AppKit
import XCTest
@testable import AuvGit

@MainActor
final class WindowShellStartupTests: XCTestCase {
    func testHeldWorkspacePresentationBlocksMouseKeyboardAndAccessibilityUntilRestored() throws {
        final class FocusableChild: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let split = WorkspaceSplitView(compact: false)
        let child = FocusableChild()
        [child, NSView(), NSView()].forEach { split.addArrangedSubview($0) }
        window.contentView = split
        split.layoutSubtreeIfNeeded()
        let point = split.convert(NSPoint(x: child.bounds.midX, y: child.bounds.midY), from: child)
        let parentPoint = split.convert(point, to: split.superview)
        XCTAssertTrue(split.hitTest(parentPoint) === child)
        XCTAssertTrue(window.makeFirstResponder(child))

        split.holdsPreviousPresentation = true
        XCTAssertTrue(split.hitTest(parentPoint) === split)
        XCTAssertTrue(window.firstResponder === split)
        XCTAssertFalse(split.isAccessibilityEnabled())
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x",
            charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        split.keyDown(with: key)
        XCTAssertTrue(window.firstResponder === split)

        split.holdsPreviousPresentation = false
        XCTAssertTrue(split.hitTest(parentPoint) === child)
        XCTAssertTrue(split.isAccessibilityEnabled())
        XCTAssertTrue(window.makeFirstResponder(child))
    }

    func testChangingShellTitleDoesNotRelayoutTheProjectPanels() async throws {
        final class Panels: NSView {
            var layouts = 0
            override func layout() { layouts += 1; super.layout() }
        }
        _ = NSApplication.shared
        let panels = Panels(frame: NSRect(x: 0, y: 0, width: 1080, height: 780))
        let frame = EightPointFrameView(content: panels)
        let window = NSWindow(contentRect: panels.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = frame
        let bridge = TitlebarToolbarSupport.TitlebarView()
        bridge.hidesNativeToolbar = true; bridge.shellWindowTitle = "First"
        panels.addSubview(bridge)
        try await Task.sleep(for: .milliseconds(20))
        frame.layoutSubtreeIfNeeded()
        let count = panels.layouts
        bridge.shellWindowTitle = "Second"
        for _ in 0..<3 { bridge.scheduleToolbarConfiguration() }
        try await Task.sleep(for: .milliseconds(20))
        frame.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.title, "Second")
        XCTAssertEqual(panels.layouts, count)
        func labels(_ view: NSView) -> [String] {
            if let label = view as? NSTextField { return [label.stringValue] }
            return view.subviews.flatMap(labels)
        }
        XCTAssertTrue(labels(frame).contains("Second"))
    }
    func testPlaceholderIsInvisibleBeforeDeferredShellRestoresItsFrame() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["window.frameMode", "window.shellFrame.v1"]
        let previous = keys.map { defaults.object(forKey: $0) }
        let original = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1080, height: 820),
                                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        original.isReleasedWhenClosed = false
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) { window.close() }
            original.close()
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set("borderless", forKey: keys[0])
        let saved = NSRect(x: 180, y: 160, width: 1100, height: 760)
        defaults.set(NSStringFromRect(saved), forKey: keys[1])
        let expected = try XCTUnwrap(WindowShellGeometry.restore(saved, minimum: NSSize(width: 1000, height: 714),
                                                                screens: NSScreen.screens.map(\.visibleFrame)))
        var installations = 0
        let bridge = TitlebarToolbarSupport.TitlebarView()
        bridge.shellContent = { _ in installations += 1; return NSView() }
        original.contentView?.addSubview(bridge)
        XCTAssertEqual(original.alphaValue, 0, "Hide the placeholder synchronously, before the first ordering")
        XCTAssertEqual(installations, 0, "Keep toolbar creation deferred until SwiftUI has configured it")
        original.makeKeyAndOrderFront(nil)
        for _ in 0..<20 where installations == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let shell = try XCTUnwrap(NSApp.windows.first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible })
        XCTAssertEqual(shell.frame, expected)
        XCTAssertEqual(shell.alphaValue, 1)
        XCTAssertFalse(original.isVisible)
        bridge.scheduleToolbarConfiguration()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(installations, 1)
    }

    func testNativeAndShellWindowsStayVisibleDuringToolbarConfiguration() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "window.frameMode")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            if let previous { defaults.set(previous, forKey: "window.frameMode") }
            else { defaults.removeObject(forKey: "window.frameMode") }
        }
        defaults.set("native", forKey: "window.frameMode")
        let bridge = TitlebarToolbarSupport.TitlebarView()
        bridge.shellContent = { _ in NSView() }
        window.contentView?.addSubview(bridge)
        XCTAssertEqual(window.alphaValue, 1)
        defaults.set("borderless", forKey: "window.frameMode")
        bridge.hidesNativeToolbar = true
        bridge.scheduleToolbarConfiguration()
        XCTAssertEqual(window.alphaValue, 1)
    }
}
