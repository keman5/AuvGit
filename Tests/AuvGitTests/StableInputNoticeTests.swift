import AppKit
import SwiftUI
import XCTest
@testable import AuvGit

@MainActor
final class StableInputNoticeTests: XCTestCase {
    func testNativePromptAndTypedTextKeepTheSameDrawingRect() {
        let cell = StableSingleLineCell(textCell: "")
        cell.font = .systemFont(ofSize: 13)
        cell.usesSingleLineMode = true
        cell.placeholderString = "Author"
        for height: CGFloat in [20, 24, 30] {
            let bounds = NSRect(x: 0, y: 0, width: 140, height: height)
            let prompt = cell.drawingRect(forBounds: bounds)
            cell.stringValue = "Sample author"
            XCTAssertEqual(cell.drawingRect(forBounds: bounds), prompt)
            cell.stringValue = ""
            XCTAssertEqual(cell.drawingRect(forBounds: bounds), prompt)
            XCTAssertLessThanOrEqual(prompt.height, bounds.height)
        }
    }
    func testNativeSubmitUpdatesBindingAndRunsOnlyOnReturn() {
        var text = "", submissions = 0
        let input = HistorySearchField(text: Binding(get: { text }, set: { text = $0 }), placeholder: "Hash", accessibilityLabel: "Hash", onSubmit: { submissions += 1 })
        let coordinator = input.makeCoordinator()
        let field = NSTextField(string: "abc123")
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "abc123")
        XCTAssertFalse(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(submissions, 0)
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submissions, 1)
    }
    func testRoundedInputReservesBezelHeightForEnteredText() {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: StableTextField("Clone URL", text: .constant("https://example.com/repository.git")))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 24)
        let plain = NSHostingView(rootView: StableTextField("Filter", text: .constant(""), rounded: false))
        XCTAssertGreaterThanOrEqual(plain.fittingSize.height, 20)
    }

    func testFocusedRoundedFieldEditorFitsChineseAndDescenders() throws {
        _ = NSApplication.shared
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 300, height: 24))
        field.cell = StableSingleLineCell(textCell: "")
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        container.addSubview(field)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = container
        defer { window.close() }
        for value in ["/tmp/中文目录/gyp-保留路径", "gyp"] {
            field.stringValue = value
            XCTAssertTrue(window.makeFirstResponder(field))
            field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            let layout = try XCTUnwrap(editor.layoutManager)
            let textContainer = try XCTUnwrap(editor.textContainer)
            layout.ensureLayout(for: textContainer)
            let used = layout.usedRect(for: textContainer).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
            XCTAssertGreaterThan(used.height, 0)
            XCTAssertGreaterThanOrEqual(editor.visibleRect.maxY + 0.5, used.maxY, "Focused editor clips glyph descenders")
            XCTAssertLessThanOrEqual(editor.visibleRect.minY - 0.5, used.minY, "Focused editor clips glyph tops")
            window.makeFirstResponder(nil)
        }
    }

}
