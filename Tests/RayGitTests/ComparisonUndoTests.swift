import XCTest
import AppKit
@testable import RayGit

@MainActor
final class ComparisonUndoTests: XCTestCase {
    private func editor(_ source: String) -> UndoableComparisonTextView {
        let view = UndoableComparisonTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: nil)
        view.isRichText = false; view.string = source; view.isEditable = true
        XCTAssertNotNil(view.textStorage)
        XCTAssertNotNil(view.layoutManager)
        XCTAssertEqual(view.string, source)
        return view
    }
    func testTypingAndProgrammaticReplacementAreIndependentNativeUndoSteps() async {
        let view = editor("original")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertText(" typed", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "original typed")
        view.replaceAsUndoableEdit("auto merge")
        XCTAssertEqual(view.string, "auto merge")
        view.editingUndoManager.undo()
        XCTAssertEqual(view.string, "original typed")
        view.editingUndoManager.undo()
        XCTAssertEqual(view.string, "original")
        view.editingUndoManager.redo()
        XCTAssertEqual(view.string, "original typed")
        view.editingUndoManager.redo()
        XCTAssertEqual(view.string, "auto merge")
        XCTAssertEqual(view.editingUndoManager.groupingLevel, 0)
    }
    func testTwoToolbarReplacementsInOneEventUndoSeparately() async {
        let view = editor("start")
        view.replaceAsUndoableEdit("first")
        XCTAssertEqual(view.string, "first")
        view.replaceAsUndoableEdit("second")
        XCTAssertEqual(view.string, "second")
        view.editingUndoManager.undo(); XCTAssertEqual(view.string, "first")
        view.editingUndoManager.undo(); XCTAssertEqual(view.string, "start")
        view.editingUndoManager.redo(); XCTAssertEqual(view.string, "first")
        view.editingUndoManager.redo(); XCTAssertEqual(view.string, "second")
    }
    func testBusyReplacementPreservesUndoAndTemporaryReadOnlyState() async {
        let view = editor("before")
        view.replaceAsUndoableEdit("edited")
        XCTAssertEqual(view.string, "edited")
        view.isEditable = false
        view.replaceAsUndoableEdit("external draft")
        XCTAssertEqual(view.string, "external draft")
        XCTAssertFalse(view.isEditable)
        view.isEditable = true
        view.editingUndoManager.undo(); XCTAssertEqual(view.string, "edited")
        view.editingUndoManager.undo(); XCTAssertEqual(view.string, "before")
        view.editingUndoManager.redo(); XCTAssertEqual(view.string, "edited")
        view.isEditable = false; view.isEditable = true
        XCTAssertTrue(view.editingUndoManager.canRedo)
    }
    func testPartialConflictReplacementIsOneOperationWithUnicode() async {
        let view = editor("前\n<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n後")
        let original = view.string
        let source = original as NSString
        let range = source.range(of: "<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n")
        view.replaceAsUndoableEdit("a\n", range: range, actionName: "Resolve Conflict")
        XCTAssertEqual(view.string, "前\na\n後")
        XCTAssertEqual(view.editingUndoManager.undoActionName, "Resolve Conflict")
        view.editingUndoManager.undo(); XCTAssertEqual(view.string, original)
        view.editingUndoManager.redo(); XCTAssertEqual(view.string, "前\na\n後")
    }
}
