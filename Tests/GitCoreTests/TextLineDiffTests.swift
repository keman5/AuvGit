import XCTest
@testable import GitCore

final class TextLineDiffTests: XCTestCase {
    func testRepeatedLineDeletion() {
        let diff = TextLineDiff(source: "a\nx\nx\nb", target: "a\nx\nb")
        XCTAssertEqual(diff.sourceChangedLines.count, 1)
        XCTAssertTrue(diff.targetChangedLines.isEmpty)
        XCTAssertEqual(diff.sourceToTarget[3], 2)
    }
    func testReorderingIsNotEqual() {
        let diff = TextLineDiff(source: "a\nb\nc", target: "b\na\nc")
        XCTAssertFalse(diff.sourceChangedLines.isEmpty)
        XCTAssertFalse(diff.targetChangedLines.isEmpty)
        XCTAssertEqual(diff.sourceToTarget[2], 2)
    }
    func testMovedBlock() {
        let diff = TextLineDiff(source: "a\nb\nc\nd\ne", target: "a\nd\nb\nc\ne")
        XCTAssertFalse(diff.sourceChangedLines.isEmpty)
        XCTAssertFalse(diff.targetChangedLines.isEmpty)
        XCTAssertEqual(diff.sourceToTarget[0], 0)
        XCTAssertEqual(diff.sourceToTarget[4], 4)
    }
    func testInsertionAndDeletion() {
        let diff = TextLineDiff(source: "a\nb\nc", target: "a\nx\nc\nd")
        XCTAssertEqual(diff.sourceChangedLines, [1])
        XCTAssertEqual(diff.targetChangedLines, [1, 3])
        XCTAssertEqual(diff.sourceToTarget[2], 2)
    }
    func testBlankLinesAreSignificant() {
        let diff = TextLineDiff(source: "a\n\n\nb", target: "a\n\nb")
        XCTAssertEqual(diff.sourceChangedLines.count, 1)
        XCTAssertTrue(diff.targetChangedLines.isEmpty)
    }
    func testFinalLFIsSignificant() {
        let diff = TextLineDiff(source: "a", target: "a\n")
        XCTAssertTrue(diff.sourceChangedLines.isEmpty)
        XCTAssertEqual(diff.targetChangedLines, [1])
    }
    func testEqualText() {
        let diff = TextLineDiff(source: "a\n\n", target: "a\n\n")
        XCTAssertTrue(diff.sourceChangedLines.isEmpty)
        XCTAssertTrue(diff.targetChangedLines.isEmpty)
        XCTAssertEqual(diff.sourceToTarget, [0, 1, 2])
    }
    func testFallbackConservativelyMarksUnresolvedMiddle() {
        let diff = TextLineDiff(source: "start\na\nb\nc\nend", target: "start\nc\nb\na\nend", maximumDetailedLines: 0)
        XCTAssertTrue(diff.usedConservativeFallback)
        XCTAssertEqual(diff.sourceChangedLines, [1, 2, 3])
        XCTAssertEqual(diff.targetChangedLines, [1, 2, 3])
        XCTAssertEqual(diff.sourceToTarget[4], 4)
    }
}
