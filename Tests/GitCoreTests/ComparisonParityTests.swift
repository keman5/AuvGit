import XCTest
@testable import GitCore

final class ComparisonParityTests: XCTestCase {
    func testRulesRetainOriginalLineMapping() {
        let source = "LET x = 1\r\nnext\n", target = "letx=1\nNEXT\n"
        let rules = ComparisonRules(ignoreWhitespace: true, ignoreCase: true, ignoreLineEndings: true)
        let diff = TextLineDiff(source: source, target: target, rules: rules)
        XCTAssertTrue(diff.blocks().isEmpty)
        XCTAssertEqual(diff.sourceToTarget, [0, 1, 2])
        XCTAssertFalse(TextLineDiff(source: source, target: target).blocks().isEmpty)
    }
    func testNormalizedBuffersStillCompareTheirOriginalLineEndings() {
        let text = "same\nnext\n"
        let exact = ComparisonAlignment(texts: [text, text], endings: [.lf, .crlf])
        XCTAssertEqual(exact.bands.count, 3)
        let rules = ComparisonRules(ignoreLineEndings: true)
        XCTAssertTrue(TextLineDiff(source: rules.textKey(text, ending: .lf), target: rules.textKey(text, ending: .crlf), rules: rules).blocks().isEmpty)
        XCTAssertEqual(TextLineDiff(source: ComparisonRules().textKey(text, ending: .lf), target: ComparisonRules().textKey(text, ending: .crlf)).sourceChangedLines, [0, 1])
    }
    func testInnerLineAcceptKeepsOtherChangesAndUnicode() throws {
        let source = "🙂 old + stable + one", target = "🙂 new + stable + two"
        let cursor = (target as NSString).range(of: "new").location
        let edit = try XCTUnwrap(ComparisonTransfer.edit(source: source, target: target, selection: NSRange(location: cursor, length: 0), granularity: .innerLine))
        XCTAssertEqual(edit.applying(to: target), "🙂 old + stable + two")
    }
    func testMultilineAcceptSelectionKeepsUnselectedChange() throws {
        let source = "first old\nsecond old\nlast old", target = "first new\nsecond new\nlast new"
        let selection = NSRange(location: 0, length: "first new\nsecond new".utf16.count)
        let edit = try XCTUnwrap(ComparisonTransfer.edit(source: source, target: target, selection: selection, granularity: .selection))
        XCTAssertEqual(edit.applying(to: target), "first old\nsecond old\nlast new")
    }
    func testStageSourceSelectionKeepsOtherInnerLineChange() throws {
        let index = "let first = 1; second = 2\n", working = "let first = 100; second = 200\n"
        let selection = (working as NSString).range(of: "100")
        let edit = try XCTUnwrap(ComparisonTransfer.editFromSourceSelection(source: working, target: index, selection: selection, granularity: .selection))
        XCTAssertEqual(edit.applying(to: index), "let first = 100; second = 2\n")
    }
    func testStageMultipleSelectedLines() throws {
        let index = "a0\nb0\nc0\n", working = "a1\nb1\nc1\n"
        let edit = try XCTUnwrap(ComparisonTransfer.editFromSourceSelection(source: working, target: index, selection: NSRange(location: 0, length: 5), granularity: .selection))
        XCTAssertEqual(edit.applying(to: index), "a1\nb1\nc0\n")
    }
    func testApplyMissingLineAtEOFDoesNotConstructInvalidRange() throws {
        let source = "a\nnew", target = "a"
        let edit = try XCTUnwrap(ComparisonTransfer.edit(source: source, target: target, selection: NSRange(location: 1, length: 0), granularity: .line))
        XCTAssertEqual(edit.applying(to: target), source)
    }
    func testBoundedComparisonUsesConservativeFallbackOnlyWhenRequested() {
        let source = "a\nb\na\nb", target = "b\na\nb\na"
        let exact = TextLineDiff(source: source, target: target, maximumDetailedLines: 0)
        let bounded = TextLineDiff(source: source, target: target, maximumDetailedLines: 0, rules: .init(boundedComparison: true))
        XCTAssertFalse(exact.usedConservativeFallback)
        XCTAssertTrue(bounded.usedConservativeFallback)
    }
    func testDisplayFilteringLeavesRealChangesAndRemovesIgnoredHunk() {
        let patch = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-HELLO\n+hello\n@@ -3 +3 @@\n-old\n+new\n"
        let result = ComparisonRules(ignoreCase: true).filteringPatch(patch)
        XCTAssertFalse(result.contains("@@ -1")); XCTAssertTrue(result.contains("-old")); XCTAssertTrue(result.contains("+new"))
    }
    func testMultilineSelectionAcceptsSelectedDeletedLineEndings() throws {
        let target = "first\nsecond\n"
        let edit = try XCTUnwrap(ComparisonTransfer.edit(source: "", target: target, selection: NSRange(location: 0, length: target.utf16.count), granularity: .selection))
        XCTAssertEqual(edit.applying(to: target), "")
    }
    func testSourceSelectionStagesUnpairedAddedLineWithoutPairedChanges() throws {
        let source = "new first\nnew second\nkeep\n", target = "old first\nkeep\n"
        let selection = (source as NSString).range(of: "new second")
        let edit = try XCTUnwrap(ComparisonTransfer.editFromSourceSelection(source: source, target: target, selection: selection, granularity: .selection))
        XCTAssertEqual(edit.applying(to: target), "old first\nnew second\nkeep\n")
    }
    func testSourceSelectionStagesDeletedReplacementTailWithoutUnselectedPairedLine() throws {
        let source = "new first\nnew second\nkeep\n", target = "old first\nold second\nold third\nkeep\n"
        let selection = (source as NSString).range(of: "new second")
        let edit = try XCTUnwrap(ComparisonTransfer.editFromSourceSelection(source: source, target: target, selection: selection, granularity: .selection))
        XCTAssertEqual(edit.applying(to: target), "old first\nnew second\nkeep\n")
    }

}
