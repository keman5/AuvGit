import XCTest
@testable import GitCore
final class DiffParserTests: XCTestCase {
    func testRootAdditionAndDeletion() {
        let add = DiffParser.parse("--- /dev/null\n+++ b/file\n@@ -0,0 +1,2 @@\n+ one\n+two\n")
        XCTAssertEqual(add.lines.suffix(2).map(\.newNumber), [1, 2]); XCTAssertNil(add.lines.last?.oldNumber)
        XCTAssertEqual(add.lines[3].text, " one")
        let remove = DiffParser.parse("@@ -1,2 +0,0 @@\n-a\n-b\n")
        XCTAssertEqual(remove.lines.suffix(2).map(\.oldNumber), [1, 2]); XCTAssertNil(remove.lines.last?.newNumber)
    }
    func testCountersAndNoNewlineMetadata() {
        let diff = DiffParser.parse("@@ -3 +7 @@ name\n same\n-old\n+new\n\\ No newline at end of file\n@@ -20,1 +30,1 @@\n z\n")
        XCTAssertEqual(diff.lines[1].oldNumber, 3); XCTAssertEqual(diff.lines[1].newNumber, 7)
        XCTAssertEqual(diff.lines[2].oldNumber, 4); XCTAssertEqual(diff.lines[3].newNumber, 8)
        XCTAssertEqual(diff.lines[4].kind, .metadata); XCTAssertEqual(diff.lines.last?.newNumber, 30)
        XCTAssertEqual(diff.hunks.map(\.lineIndex), [0, 5])
    }
    func testFileHeadersOutsideHunks() {
        let diff = DiffParser.parse("diff --git a/a b/a\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/b b/b\n--- a/b\n+++ b/b\n")
        XCTAssertEqual(diff.lines.last?.kind, .metadata)
    }
    func testBinaryEmptyAndLimit() {
        XCTAssertTrue(DiffParser.parse("Binary files a/a and b/a differ\n").isBinary)
        XCTAssertTrue(DiffParser.parse("").lines.isEmpty)
        let bounded = DiffParser.parse("a\nb\nc", maximumLines: 2)
        XCTAssertEqual(bounded.lines.count, 2); XCTAssertTrue(bounded.isTruncated)
    }
}
