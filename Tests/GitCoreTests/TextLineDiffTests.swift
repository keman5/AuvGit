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
    func testLowDetailBudgetStillRetainsExactUnchangedAnchors() {
        let diff = TextLineDiff(source: "start\na\nb\nc\nend", target: "start\nc\nb\na\nend", maximumDetailedLines: 0)
        XCTAssertFalse(diff.usedConservativeFallback)
        XCTAssertEqual(diff.sourceChangedLines.count, 2)
        XCTAssertEqual(diff.targetChangedLines.count, 2)
        XCTAssertEqual(diff.sourceToTarget[4], 4)
    }
    func testSixThousandLinesWithThreeSparseChangesHaveThreeBands() {
        let lines = (1...6_000).map { "const item\($0) = \($0);" }
        var changed = lines
        let positions = [79, 2_999, 5_799]
        for index in positions { changed[index] += " // modified" }
        let source = lines.joined(separator: "\n"), target = changed.joined(separator: "\n")
        let diff = TextLineDiff(source: source, target: target)
        XCTAssertEqual(diff.sourceChangedLines, Set(positions))
        XCTAssertEqual(diff.targetChangedLines, Set(positions))
        XCTAssertEqual(diff.blocks().count, 3)
        XCTAssertFalse(diff.usedConservativeFallback)
        for index in lines.indices { XCTAssertEqual(diff.sourceToTarget[index], index) }
        let alignment = ComparisonAlignment(texts: [source, target])
        XCTAssertEqual(alignment.bands.count, lines.count)
        XCTAssertTrue(alignment.bands.allSatisfy { $0[0] == $0[1] && $0[0].count == 1 })
    }
    func testSparseInsertionDeletionMappingAndRepeatedLineRemainder() {
        let lines = (1...6_000).map { "line \($0)" }
        var target = lines
        target.remove(at: 5_000); target.insert("added", at: 80)
        let diff = TextLineDiff(source: lines.joined(separator: "\n"), target: target.joined(separator: "\n"))
        XCTAssertEqual(diff.sourceChangedLines, [5_000]); XCTAssertEqual(diff.targetChangedLines, [80])
        XCTAssertEqual(diff.sourceToTarget[3_000], 3_001)
        XCTAssertEqual(diff.sourceToTarget[5_500], 5_500)
        let repeated = Array(repeating: "same", count: 6_000)
        var modified = repeated
        modified[79] = "first"; modified[5_799] = "last"
        let repeatedDiff = TextLineDiff(source: repeated.joined(separator: "\n"), target: modified.joined(separator: "\n"))
        XCTAssertEqual(repeatedDiff.sourceChangedLines.count, 2)
        XCTAssertEqual(repeatedDiff.targetChangedLines, [79, 5_799])
        XCTAssertFalse(repeatedDiff.usedConservativeFallback)
    }

}
