import AppKit
import XCTest
@testable import AuvGit

@MainActor
final class NativeSelectAllTests: XCTestCase {
    func testEditorsSelectEntireDocumentWithoutChangingFocusOrContent() throws {
        let window = makeWindow()
        defer { window.close() }
        let appearance = NativeFocusAppearance.forWindow(window)
        let editors: [NSTextView] = [
            CommitPlaceholderTextView(frame: .zero),
            ComparisonTextView(frame: .zero, textContainer: nil),
            ReadOnlyDiffTextView(frame: .zero),
            NSTextView(frame: .zero)
        ]
        for editor in editors {
            window.contentView = editor
            editor.isSelectable = true
            editor.string = "提交说明 🐈\nsecond line\n"
            if editor is ReadOnlyDiffTextView { editor.isEditable = false }
            XCTAssertTrue(window.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: 2, length: 1))
            let original = editor.string
            XCTAssertTrue(appearance.handle(try key(in: window)))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: original.utf16.count))
            XCTAssertEqual(editor.string, original)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertFalse(appearance.isVisible, "Selecting text must not enable keyboard focus rings")
        }
    }

    func testFieldEditorsSelectAllWithDisabledSceneMenu() throws {
        let window = makeWindow()
        defer { window.close() }
        let appearance = NativeFocusAppearance.forWindow(window)
        let originalMenu = NSApp.mainMenu
        let menu = NSMenu()
        let item = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.autoenablesItems = false
        item.isEnabled = false
        menu.addItem(item)
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = originalMenu }
        for field in [NSTextField(), NSSecureTextField()] {
            window.contentView?.addSubview(field)
            field.frame = NSRect(x: 0, y: 0, width: 250, height: 24)
            field.stringValue = "a complete search query"
            field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 4, length: 0))
            // AppKit consumes a disabled menu equivalent without selecting text.
            _ = menu.performKeyEquivalent(with: try key(in: window))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 4, length: 0))
            XCTAssertTrue(appearance.handle(try key(in: window, flags: [.command, .capsLock])))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: field.stringValue.utf16.count))
            XCTAssertTrue(window.firstResponder === editor)
            window.makeFirstResponder(window)
            field.removeFromSuperview()
        }
    }

    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 4 }
    }

    func testSelectAllUsesFocusedTableWithoutRememberedFileScope() throws {
        let window = makeWindow()
        defer { window.close() }
        let appearance = NativeFocusAppearance.forWindow(window)
        let rows = Rows()
        let table = WorkspacePreviewTable(frame: window.contentView!.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.allowsMultipleSelection = true
        table.dataSource = rows
        window.contentView?.addSubview(table)
        table.reloadData()
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(appearance.handle(try key(in: window)))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integersIn: 0..<4))
        XCTAssertTrue(window.firstResponder === table)
        table.allowsMultipleSelection = false
        XCTAssertFalse(appearance.handle(try key(in: window)))
    }

    func testSelectAllRespectsWindowSheetAndShortcutOwnership() throws {
        let window = makeWindow(), other = makeWindow(), sheet = makeWindow()
        defer { window.close(); other.close(); sheet.close() }
        let appearance = NativeFocusAppearance.forWindow(window)
        let editor = NSTextView(frame: .zero)
        window.contentView = editor
        editor.string = "keep selection"
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertFalse(appearance.handle(try key(in: other)))
        for flags: NSEvent.ModifierFlags in [[], .control, [.command, .shift], [.command, .option]] {
            XCTAssertFalse(appearance.handle(try key(in: window, flags: flags)))
        }
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        window.beginSheet(sheet)
        XCTAssertFalse(appearance.handle(try key(in: window)))
        window.endSheet(sheet)
        let button = KeyViewProxy.Button(title: "Button", target: nil, action: nil)
        window.contentView?.addSubview(button)
        XCTAssertTrue(window.makeFirstResponder(button))
        XCTAssertFalse(appearance.handle(try key(in: window)), "Do not activate a text field when a button owns input")
        let terminal = RepositoryTerminalView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(terminal)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertFalse(appearance.handle(try key(in: window)), "Terminal key handling belongs to SwiftTerm")
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func key(in window: NSWindow, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                      characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }
}
