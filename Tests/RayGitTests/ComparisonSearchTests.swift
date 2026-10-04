import XCTest
import AppKit
@testable import RayGit

@MainActor
final class ComparisonSearchTests: XCTestCase {
    func testLiteralCaseAndUTF16Ranges() throws {
        let options = ComparisonSearchOptions(query: "Ab")
        XCTAssertEqual(try ComparisonSearch.matches(in: "🙂ab AB", options: options).get(), [NSRange(location: 2, length: 2), NSRange(location: 5, length: 2)])
        XCTAssertEqual(try ComparisonSearch.matches(in: "🙂ab AB", options: ComparisonSearchOptions(query: "AB", caseSensitive: true)).get(), [NSRange(location: 5, length: 2)])
        XCTAssertEqual(try ComparisonSearch.replacing(in: "🙂ab AB", options: options, replacement: "$1", all: true).get(), "🙂$1 $1")
    }
    func testRegexCapturesKeepLookbehindContextAndLineAnchors() throws {
        let options = ComparisonSearchOptions(query: "(?<=foo)(bar)", regularExpression: true)
        XCTAssertEqual(try ComparisonSearch.replacing(in: "🙂foobar foobar", options: options, replacement: "<$1>", all: true).get(), "🙂foo<bar> foo<bar>")
        let multiline = ComparisonSearchOptions(query: "^let (\\w+)", regularExpression: true)
        XCTAssertEqual(try ComparisonSearch.replacing(in: "let first\nlet second", options: multiline, replacement: "var $1", all: true).get(), "var first\nvar second")
    }
    func testZeroWidthReplacementTerminatesAndInvalidRegexReturnsFailure() throws {
        let options = ComparisonSearchOptions(query: "(?=a)", regularExpression: true)
        XCTAssertEqual(try ComparisonSearch.matches(in: "aa", options: options).get().count, 2)
        XCTAssertEqual(try ComparisonSearch.replacing(in: "aa", options: options, replacement: "-", all: true).get(), "-a-a")
        if case .success = ComparisonSearch.replacing(in: "unchanged", options: ComparisonSearchOptions(query: "[", regularExpression: true), replacement: "oops", all: true) { XCTFail("Invalid regex must not produce a replacement") }
    }
    func testReplaceAllUsesOneNativeUndoGroupAndInvalidExpressionNeverEdits() async {
        _ = NSApplication.shared
        let original = "🙂one one\nOne\n"
        var draft = original
        let commands = ComparisonEditingCommands()
        let editor = ComparisonEditor(columns: [ComparisonEditorColumn(id: "head", title: "HEAD", text: original, isEditable: false, message: nil), ComparisonEditorColumn(id: "worktree", title: "Result", text: original, isEditable: true, message: nil, preservesUndo: true)], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, value in draft = value }, editingCommands: commands)
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)); split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor); coordinator.split = split; coordinator.update(editor)
        let window = NSWindow(contentRect: split.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = split; defer { window.close() }
        split.resetDistribution(); coordinator.alignDisplay()
        XCTAssertNotNil(commands.replaceSearch(options: ComparisonSearchOptions(query: "[", regularExpression: true), replacement: "invalid", all: true))
        XCTAssertEqual(draft, original)
        XCTAssertNil(commands.replaceSearch(options: ComparisonSearchOptions(query: "one"), replacement: "two", all: true))
        XCTAssertEqual(draft, "🙂two two\ntwo\n")
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        _ = CompactComparisonProjection(columns: [ComparisonEditorColumn(id: "head", title: "HEAD", text: original, isEditable: false, message: nil), ComparisonEditorColumn(id: "worktree", title: "Result", text: draft, isEditable: true, message: nil)], conflict: false)
        XCTAssertEqual(draft, "🙂two two\ntwo\n")
        commands.undo()
        XCTAssertEqual(draft, original)
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 1_000_000) }
        commands.redo()
        XCTAssertEqual(draft, "🙂two two\ntwo\n")
    }
    func testCompactProjectionKeepsActualLineNumbersAndInsertionBands() {
        let columns = [ComparisonEditorColumn(id: "head", title: "HEAD", text: "same\nold\ntail\n", isEditable: false, message: nil), ComparisonEditorColumn(id: "worktree", title: "Result", text: "same\nnew\ninserted\ntail\n", isEditable: true, message: nil)]
        let compact = CompactComparisonProjection(columns: columns, conflict: false)
        XCTAssertEqual(compact.bands.flatMap { $0.columns[0] }.map(\.number), [2])
        XCTAssertEqual(compact.bands.flatMap { $0.columns[1] }.map(\.number), [2, 3])
        XCTAssertEqual(compact.bands.flatMap { $0.columns[1] }.map(\.text), ["new", "inserted"])
        XCTAssertTrue(compact.bands.contains { $0.columns[0].isEmpty && !$0.columns[1].isEmpty })
    }
}
