import AppKit
import XCTest
@testable import AuvGit

@MainActor
final class ComparisonCaretTests: XCTestCase {
    func testReadOnlyCaretRequiresFocusAndCollapsedSelection() {
        let caret = NSRange(location: 3, length: 0)
        XCTAssertTrue(ComparisonCaret.isVisible(isSelectable: true, isFocused: true, isKeyWindow: true, selection: caret))
        XCTAssertFalse(ComparisonCaret.isVisible(isSelectable: true, isFocused: false, isKeyWindow: true, selection: caret))
        XCTAssertFalse(ComparisonCaret.isVisible(isSelectable: true, isFocused: true, isKeyWindow: false, selection: caret))
        XCTAssertFalse(ComparisonCaret.isVisible(isSelectable: false, isFocused: true, isKeyWindow: true, selection: caret))
        XCTAssertFalse(ComparisonCaret.isVisible(isSelectable: true, isFocused: true, isKeyWindow: true, selection: NSRange(location: 3, length: 2)))
        XCTAssertFalse(ComparisonCaret.isVisible(isSelectable: true, isFocused: true, isKeyWindow: true, selection: NSRange(location: NSNotFound, length: 0)))
    }

    func testSelectingAndFocusingReadOnlyPanesNeverEnablesEditing() {
        _ = NSApplication.shared
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 300, height: 120))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        // NSTextView's designated nil-container initializer does not create a
        // text system. DiffPane's convenience initializer does; supply the
        // equivalent explicit stack here and retain its storage for the test.
        for view in [ComparisonTextView(frame: frame, textContainer: nil), ReadOnlyDiffTextView(frame: frame, textContainer: container)] as [NSTextView] {
            view.isEditable = false
            view.isSelectable = true
            view.string = "one\ntwo"
            XCTAssertEqual(view.string, "one\ntwo", "The fixture must have a live text system")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            XCTAssertTrue(window.makeFirstResponder(view))
            view.setSelectedRange(NSRange(location: 4, length: 0))
            XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
            XCTAssertFalse(view.isEditable)
            XCTAssertEqual(view.shouldDrawInsertionPoint, window.isKeyWindow)
            let firstCaret = ComparisonCaret.rect(in: view)
            XCTAssertNotNil(firstCaret)
            XCTAssertGreaterThan(firstCaret?.height ?? 0, 0)
            XCTAssertEqual(firstCaret?.width, 1.5)
            view.setSelectedRange(NSRange(location: 5, length: 0))
            XCTAssertGreaterThan(ComparisonCaret.rect(in: view)?.minX ?? 0, firstCaret?.minX ?? 0,
                                 "The drawn caret must follow the real character position")
            view.setSelectedRange(NSRange(location: 4, length: 0))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
            view.keyDown(with: event)
            XCTAssertEqual(view.string, "one\ntwo", "Typing must remain blocked in read-only panes")
            let pasteboard = NSPasteboard.general
            let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            pasteboard.clearContents()
            pasteboard.setString("replacement", forType: .string)
            view.paste(nil)
            pasteboard.clearContents()
            if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) }
            XCTAssertEqual(view.string, "one\ntwo", "Paste must remain blocked in read-only panes")
            view.setSelectedRange(NSRange(location: 4, length: 3))
            XCTAssertFalse(view.shouldDrawInsertionPoint)
            XCTAssertFalse(view.isEditable)
            XCTAssertEqual(view.string, "one\ntwo")
            window.close()
        }
    }
}
