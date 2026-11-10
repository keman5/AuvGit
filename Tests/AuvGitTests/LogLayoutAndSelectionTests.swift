import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

/// Unshown windows only: changing selection must never activate the test app.
@MainActor
final class LogLayoutAndSelectionTests: XCTestCase {
    func testComparisonDefaultsTo300PointsAndRestoresManualHeight() throws {
        let suite = "LogLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func split() -> LogComparisonSplitView {
            let view = LogComparisonSplitView(defaults: defaults)
            view.addArrangedSubview(NSView()); view.addArrangedSubview(NSView())
            view.setFrameSize(NSSize(width: 900, height: 800)); view.layout()
            return view
        }
        let view = split()
        XCTAssertEqual(view.subviews[1].frame.height, 300, accuracy: 0.01)
        view.setPosition(400, ofDividerAt: 0)
        let adjusted = view.subviews[1].frame.height
        XCTAssertEqual(defaults.double(forKey: LogComparisonSplitView.heightKey), adjusted, accuracy: 0.01)
        view.setFrameSize(NSSize(width: 900, height: 540)); view.layout()
        XCTAssertGreaterThanOrEqual(view.subviews[0].frame.height, 300)
        view.setFrameSize(NSSize(width: 900, height: 950)); view.layout()
        XCTAssertEqual(view.subviews[1].frame.height, adjusted, accuracy: 0.01)
        XCTAssertEqual(split().subviews[1].frame.height, adjusted, accuracy: 0.01)
    }

    func testTemporaryStartupFrameDoesNotOverwriteSavedHeight() throws {
        let suite = "LogLayoutTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(420, forKey: LogComparisonSplitView.heightKey)
        let split = LogComparisonSplitView(defaults: defaults)
        split.addArrangedSubview(NSView()); split.addArrangedSubview(NSView())
        for height: CGFloat in [100, 600, 900] {
            split.setFrameSize(NSSize(width: 900, height: height)); split.layout()
        }
        XCTAssertEqual(split.subviews[1].frame.height, 420, accuracy: 0.01)
        XCTAssertEqual(defaults.double(forKey: LogComparisonSplitView.heightKey), 420)
        XCTAssertFalse(split.delegate === split)
    }

    func testMetadataDoesNotRepeatSubjectAndPreservesBody() {
        func commit(_ body: String) -> GitCommit {
            GitCommit(hash: "abc", parents: [], author: "Test", date: .distantPast, subject: "Subject", body: body, refs: [])
        }
        XCTAssertEqual(LogCommitMessage.body(commit("Subject\n")), "")
        XCTAssertEqual(LogCommitMessage.body(commit("Subject\n\nDetails\n\nSecond paragraph\n")), "Details\n\nSecond paragraph")
        XCTAssertEqual(LogCommitMessage.body(commit("Other message")), "Other message")
    }

    func testNativeAndSwiftUIRowsKeepEmphasisWithoutTakingFocus() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
        let row = NSTableRowView(frame: NSRect(x: 0, y: 70, width: 200, height: 24))
        let native = NativeSelectionRowView(frame: NSRect(x: 0, y: 100, width: 200, height: 24))
        content.addSubview(editor); content.addSubview(row); content.addSubview(native)
        row.isSelected = true; native.isSelected = true
        let appearance = NativeFocusAppearance.forWindow(window)
        appearance.preserveExplicitFocus()
        XCTAssertTrue(window.makeFirstResponder(editor))
        appearance.apply()
        for _ in 0..<3 {
            row.isEmphasized = false; native.isEmphasized = false
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
            XCTAssertTrue(row.isEmphasized)
            XCTAssertTrue(native.isEmphasized)
            XCTAssertTrue(row.isSelected); XCTAssertTrue(native.isSelected)
            XCTAssertTrue(window.firstResponder === editor)
        }
    }

    func testScopeCheckboxUsesSeparateColorAndNativeKeyboardAccessibility() throws {
        let button = LogScopeCheckbox.Button(checkboxWithTitle: "", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 22, height: 24)
        button.state = .on
        XCTAssertEqual(button.accessibilityRole(), .checkBox)
        var selected: Bool?
        button.changed = { selected = $0 }
        button.target = button; button.action = #selector(LogScopeCheckbox.Button.toggleScope)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        button.keyDown(with: space)
        XCTAssertEqual(selected, false)
        button.state = .on
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 22, pixelsHigh: 24, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        button.draw(button.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let color = try XCTUnwrap(bitmap.colorAt(x: 7, y: 9)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.greenComponent, color.blueComponent, "Scope checkboxes must remain distinct from blue selected rows")
    }

    func testScopeCheckboxCheckmarkRisesToTheRightInRenderedView() throws {
        let button = LogScopeCheckbox.Button(checkboxWithTitle: "", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 22, height: 24)
        button.appearance = NSAppearance(named: .aqua)
        button.state = .on
        let bitmap = try XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
        button.cacheDisplay(in: button.bounds, to: bitmap)
        func whitePixels(_ rows: Range<Int>) -> Int {
            var count = 0
            for y in rows {
                for x in 13..<17 {
                    let pixelX = Int((CGFloat(x) + 0.5) * CGFloat(bitmap.pixelsWide) / 22)
                    let pixelY = Int((CGFloat(y) + 0.5) * CGFloat(bitmap.pixelsHigh) / 24)
                    let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
                    if let color, min(color.redComponent, color.greenComponent, color.blueComponent) > 0.85 { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(whitePixels(7..<11), whitePixels(14..<18), "The long checkmark stroke must point upward, including in flipped AppKit controls")
    }

    func testRealSwiftUIListsKeepBothSelectionsWhenResponderMoves() async throws {
        struct Fixture: View {
            @State private var first: Int? = 1
            @State private var second: Int? = 2
            var body: some View {
                HStack {
                    List(selection: $first) { Text("Branch").tag(1) }
                    List(selection: $second) { Text("Commit").tag(2) }
                }.nativeFocusRoot()
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture())
        window.contentView = host
        let appearance = NativeFocusAppearance.forWindow(window)
        appearance.preserveExplicitFocus()
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let lists = tables(in: host)
        XCTAssertEqual(lists.count, 2)
        appearance.apply()
        for list in lists {
            XCTAssertTrue(window.makeFirstResponder(list))
            for table in lists {
                let row = try XCTUnwrap(table.rowView(atRow: table.selectedRow, makeIfNecessary: true))
                row.isEmphasized = false
                XCTAssertTrue(row.isEmphasized, "Both lists must keep their active selection palette")
                XCTAssertTrue(row.isSelected)
            }
            XCTAssertTrue(window.firstResponder === list)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testSelectionObserversReleaseRemovedSwiftUIRows() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let selection = PersistentListSelection()
        weak var released: NSTableRowView?
        autoreleasepool {
            let row = NSTableRowView(frame: .zero)
            window.contentView?.addSubview(row)
            selection.register(row)
            released = row
            row.removeFromSuperview()
        }
        selection.retainRows(in: window)
        XCTAssertNil(released, "Selection observers must not retain discarded/recycled rows")
    }
}
