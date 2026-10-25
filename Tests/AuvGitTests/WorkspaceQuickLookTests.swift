import AppKit
import QuickLookUI
import SwiftUI
import GitCore
import XCTest
@testable import AuvGit

@MainActor
final class WorkspaceQuickLookTests: XCTestCase {
    func testForcedTextRulesSupportExtensionsNamesAndPatterns() {
        for name in ["file.SVG", "Dockerfile", ".env.local", "file.custom", "file.plist"] {
            XCTAssertTrue(TextPreviewPreferences.matches(URL(fileURLWithPath: "/tmp/" + name),
                formats: "svg, Dockerfile\n.env.*; *.custom .plist"), name)
        }
        XCTAssertFalse(TextPreviewPreferences.matches(URL(fileURLWithPath: "/tmp/photo.png"), formats: "svg Dockerfile"))
        XCTAssertFalse(TextPreviewPreferences.matches(URL(fileURLWithPath: "/tmp/file.txt"), formats: ""))
        for name in ["script.swift", "Detail.strings", "image.svg", "config.yaml", "Dockerfile", ".gitignore"] {
            XCTAssertTrue(TextPreviewPreferences.matches(URL(fileURLWithPath: "/tmp/" + name), formats: TextPreviewPreferences.defaultFormats))
        }
    }

    func testSavedRulesImmediatelyOverrideMediaClassificationWithoutAcceptingBinary() throws {
        let suite = "auv-preview-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("%PDF-1.4\ntext fixture\n".utf8).write(to: url)
        XCTAssertNil(try WorkspaceTextPreviewDocument.open(url, defaults: defaults))
        defaults.set("pdf", forKey: TextPreviewPreferences.key)
        XCTAssertNotNil(try WorkspaceTextPreviewDocument.open(url, defaults: defaults))
        defaults.set("", forKey: TextPreviewPreferences.key)
        XCTAssertNil(try WorkspaceTextPreviewDocument.open(url, defaults: defaults))
        defaults.set("pdf", forKey: TextPreviewPreferences.key)
        try Data([0, 1, 2, 255]).write(to: url)
        XCTAssertNil(try WorkspaceTextPreviewDocument.open(url, defaults: defaults))
    }

    func testEditablePreviewUsesIBeamWithoutTakingFocus() throws {
        _ = NSApplication.shared
        let editor = WorkspacePreviewTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        editor.isEditable = true
        XCTAssertFalse(editor.acceptsFirstResponder)
        NSCursor.arrow.set()
        editor.cursorUpdate(with: try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved,
            location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)))
        XCTAssertEqual(NSCursor.current, NSCursor.iBeam)
        XCTAssertFalse(editor.acceptsFirstResponder)
        NSCursor.arrow.set()
    }

    func testFirstMouseClickEntersPreviewEditorAndEditsOnlyTheDraft() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("click here to edit\nsecond line\n".utf8).write(to: url)
        let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
        let controller = WorkspaceTextPreviewController(document: document, repositoryURL: nil) {}
        let window = try XCTUnwrap(controller.window as? WorkspaceTextPreviewWindow)
        defer { window.close() }
        controller.showWindow(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isEditingContent)
        let editor = controller.editor
        XCTAssertGreaterThan(editor.frame.width, 100, "Editor frame: \(editor.frame)")
        XCTAssertGreaterThan(editor.frame.height, 40, "Editor frame: \(editor.frame)")
        let point = editor.convert(NSPoint(x: 65, y: 20), to: nil)
        XCTAssertTrue(window.contentView?.hitTest(point) === editor, "Click must hit the editor; frame: \(editor.frame), hit: \(String(describing: window.contentView?.hitTest(point)))")
        let timestamp = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: timestamp + (type == .leftMouseUp ? 0.001 : 0),
                windowNumber: window.windowNumber, context: nil, eventNumber: type == .leftMouseDown ? 1_000_000 : 1_000_001, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: true)
        editor.mouseDown(with: try mouse(.leftMouseDown))
        XCTAssertTrue(window.isEditingContent, "The first click must focus the editor without requiring Tab or a second click")
        XCTAssertEqual(editor.string, document.text)
        // TextKit tracking also reads the physical pointer; exact caret placement is checked with native UI input.
        let expected = (editor.string as NSString).replacingCharacters(in: editor.selectedRange(), with: "X")
        editor.insertText("X", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, expected)
        XCTAssertTrue(document.isDirty)
        XCTAssertTrue(editor.string.contains("X"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "click here to edit\nsecond line\n")
    }

    func testTextFormatsOpenOriginalDocumentsWithoutChangingOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "\"hello\" = \"你好\";\n"
        for name in ["Detail.strings", "config.yaml", "script.swift", "unknown.custom", ".gitignore", "Dockerfile"] {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
            XCTAssertEqual(document.url, url)
            XCTAssertEqual(document.text, text)
            XCTAssertFalse(document.isDirty)
            XCTAssertEqual(try Data(contentsOf: url), Data(text.utf8))
        }
    }

    func testSavePreservesUTF16CRLFAndExecutablePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Localizable.strings")
        let text = "\"title\" = \"中文标题\";\n"
        let format = ComparisonTextFormat(encoding: .utf16LE, lineEnding: .crlf)
        try ComparisonTextDecoder.encode(text, format: format).write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.path)
        let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(original))
        document.text += "// edited\n"
        try document.save()
        XCTAssertFalse(document.isDirty)
        XCTAssertEqual(try Data(contentsOf: original), try ComparisonTextDecoder.encode(text + "// edited\n", format: format))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testBinaryMediaDirectoriesAndMissingFilesKeepNativePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("data.bin")
        try Data([0, 1, 2, 255]).write(to: binary)
        let pdf = root.appendingPathComponent("page.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdf)
        for url in [binary, pdf, root] { XCTAssertNil(try WorkspaceTextPreviewDocument.open(url)) }
        XCTAssertThrowsError(try WorkspaceTextPreviewDocument.open(root.appendingPathComponent("missing")))
    }

    func testSaveRejectsExternalModificationAndDeletion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("let value = 1\n".utf8).write(to: url)
        let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
        document.text = "let value = 2\n"
        try Data("let external = 3\n".utf8).write(to: url)
        XCTAssertThrowsError(try document.save())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let external = 3\n")
        XCTAssertTrue(document.isDirty)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try document.save())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSaveRejectsExternallyExpandedFileWithoutReadingItAll() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original\n".utf8).write(to: url)
        let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
        document.text = "my unsaved draft\n"
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 1_073_741_824)
        let start = Date()
        XCTAssertThrowsError(try document.save())
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "Reject file growth before reading a gigabyte on the UI thread")
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, 1_073_741_824)
        XCTAssertEqual(document.text, "my unsaved draft\n")
    }

    func testMonokaiHighlightsSourceWithoutChangingText() {
        let text = "let value = 42 // comment\nlet name = \"hello\"\n"
        let storage = NSTextStorage(string: text)
        MonokaiPreviewTheme.apply(SyntaxHighlighter.tokens(in: text, path: "sample.swift"), to: storage)
        for (word, kind) in [("let", SyntaxKind.keyword), ("42", .number), ("// comment", .comment), ("\"hello\"", .string)] {
            let index = (text as NSString).range(of: word).location
            XCTAssertEqual(storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, MonokaiPreviewTheme.color(for: kind))
        }
        XCTAssertEqual(storage.string, text)
    }

    func testEmptyTextCanBeEditedAndUTF8BOMIsPreserved() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        for encoding in [ComparisonEncoding.utf8, .utf8BOM] {
            let format = ComparisonTextFormat(encoding: encoding, lineEnding: .lf)
            try ComparisonTextDecoder.encode("", format: format).write(to: url)
            let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
            XCTAssertEqual(document.text, "")
            document.text = "你好\n"
            try document.save()
            XCTAssertEqual(try Data(contentsOf: url), try ComparisonTextDecoder.encode("你好\n", format: format))
        }
    }

    func testSpaceClosesPreviewBeforeEnteringEditor() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("preview".utf8).write(to: url)
        let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
        var closed = false
        let controller = WorkspaceTextPreviewController(document: document, repositoryURL: nil) { closed = true }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        window.sendEvent(space)
        XCTAssertTrue(closed)
        XCTAssertEqual(document.text, "preview")
    }

    func testPreviewStartsUnfocusedTabEntersEditorSpaceEditsAndCommandSSaves() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".swift")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("let value = 42\n".utf8).write(to: url)
        let document = try XCTUnwrap(WorkspaceTextPreviewDocument.open(url))
        var closed = false
        let controller = WorkspaceTextPreviewController(document: document, repositoryURL: nil) { closed = true }
        let window = try XCTUnwrap(controller.window as? WorkspaceTextPreviewWindow)
        defer { window.close() }
        controller.showWindow(nil)
        XCTAssertFalse(window.isEditingContent)
        XCTAssertFalse(controller.editor.acceptsFirstResponder)
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        window.sendEvent(try key(48, "\t"))
        XCTAssertTrue(window.isEditingContent)
        controller.editor.setSelectedRange(NSRange(location: 3, length: 0))
        window.sendEvent(try key(49, " "))
        XCTAssertFalse(closed)
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(controller.editor.string, "let  value = 42\n")
        XCTAssertTrue(window.performKeyEquivalent(with: try key(1, "s", .command)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "let  value = 42\n")
        XCTAssertFalse(document.isDirty)
        window.sendEvent(try key(53, "\u{1b}"))
        XCTAssertTrue(closed)
    }

    func testSpaceIsHandledOnlyWithoutModifiers() throws {
        final class Probe: WorkspacePreviewTable {
            var previews = 0
            override func togglePreview() { previews += 1 }
        }
        let table = Probe()
        func space(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        }
        table.keyDown(with: try space([]))
        XCTAssertEqual(table.previews, 1)
        table.keyDown(with: try space(.shift))
        XCTAssertEqual(table.previews, 1)
    }

    func testFilePreviewUsesNativeSelectionAndCurrentRepositoryAndRejectsLoadingState() {
        let firstRoot = URL(fileURLWithPath: "/tmp/first-preview")
        var parent = WorkspaceNativeFilesTable(rows: ["a.png", "b.pdf"].map { .init(path: $0, file: nil) }, files: [],
            repository: GitRepository(url: firstRoot), selection: .constant([]), isBusy: false, sortOrder: .constant([]),
            onAction: { _, _ in }, onCompare: { _ in })
        let coordinator = parent.makeCoordinator()
        let table = WorkspaceNativeFilesTable.FileTable()
        table.addTableColumn(NSTableColumn(identifier: .init("filename")))
        table.dataSource = coordinator; coordinator.table = table
        table.allowsMultipleSelection = true
        coordinator.update(parent)
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertEqual(coordinator.previewURLs(), [firstRoot.appendingPathComponent("a.png"), firstRoot.appendingPathComponent("b.pdf")])
        parent = WorkspaceNativeFilesTable(rows: [.init(path: "new.txt", file: nil)], files: [],
            repository: GitRepository(url: URL(fileURLWithPath: "/tmp/second-preview")), selection: .constant(["new.txt"]),
            isBusy: false, sortOrder: .constant([]), onAction: { _, _ in }, onCompare: { _ in })
        coordinator.update(parent)
        XCTAssertEqual(coordinator.previewURLs().map(\.path), ["/tmp/second-preview/new.txt"])
        parent.isReady = false; coordinator.update(parent)
        XCTAssertEqual(coordinator.previewURLs(), [])
    }

    func testBothFileViewsParticipateInSystemPreviewResponderChain() {
        let tables: [NSTableView] = [WorkspaceNativeFilesTable.FileTable(), WorkspaceTreeTable.TreeTable()]
        for table in tables {
            XCTAssertTrue(table is QLPreviewPanelDataSource)
            XCTAssertTrue(table is QLPreviewPanelDelegate)
        }
    }
}
