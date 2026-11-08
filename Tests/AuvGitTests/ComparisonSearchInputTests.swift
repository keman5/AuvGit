import AppKit
import SwiftUI
import XCTest
@testable import AuvGit

/// Exercise the native IME contract in unshown windows, without switching input sources.
@MainActor
final class ComparisonSearchInputTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var query = "已有"
        @Published var matches = 0
        var navigations = 0
        var dismissals = 0
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        var body: some View {
            VStack {
                ComparisonSearchField(text: $state.query, placeholder: "Find",
                    onNavigate: { _ in state.navigations += 1 }, onEscape: { state.dismissals += 1 })
                Text(String(state.matches))
            }.frame(width: 400, height: 80)
        }
    }

    func testSearchResultUpdatesPreserveMarkedTextAndOnlyPublishCommittedChinese() throws {
        let state = State()
        let (window, host, field, editor) = try fixture(state)
        defer { window.close() }
        let delegate = try XCTUnwrap(field.delegate as? ComparisonSearchField.Coordinator)
        for index in 1...8 {
            let pending = String(repeating: "zhongwen", count: index)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.setMarkedText(pending, selectedRange: NSRange(location: pending.utf16.count, length: 0),
                replacementRange: NSRange(location: state.query.utf16.count, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(state.query, "已有" + String(repeating: "中文", count: index - 1), "Unconfirmed IME text must not start a search")
            let composed = editor.string, marked = editor.markedRange()
            state.matches += 1
            drain(host)
            XCTAssertEqual(editor.string, composed, "A completed older search must not rewrite the field editor")
            XCTAssertEqual(editor.markedRange(), marked)
            editor.insertText("中文", replacementRange: editor.markedRange())
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertEqual(state.query, "已有" + String(repeating: "中文", count: index))
        }
        XCTAssertFalse(window.isVisible)
    }

    func testReturnAndEscapeBelongToIMEWhileComposing() throws {
        let state = State()
        let (window, _, field, editor) = try fixture(state)
        defer { window.close() }
        let delegate = try XCTUnwrap(field.delegate as? ComparisonSearchField.Coordinator)
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        for selector in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: selector))
        }
        XCTAssertEqual(state.navigations, 0)
        XCTAssertEqual(state.dismissals, 0)
        editor.unmarkText()
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(state.navigations, 1)
        XCTAssertEqual(state.dismissals, 1)
        XCTAssertFalse(window.isVisible)
    }

    private func fixture(_ state: State) throws -> (NSWindow, NSHostingView<Fixture>, NSTextField, NSTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: Fixture(state: state))
        window.contentView = host
        drain(host)
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(fields(host).first { $0.isEditable })
        NativeFocusAppearance.forWindow(window).preserveExplicitFocus()
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        return (window, host, field, editor)
    }
    private func drain(_ view: NSView) {
        for _ in 0..<3 { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    }
}
