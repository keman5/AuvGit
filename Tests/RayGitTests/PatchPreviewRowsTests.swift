import XCTest
import GitCore
@testable import RayGit

final class PatchPreviewRowsTests: XCTestCase {
    func testMissingFinalNewlineMetadataDoesNotSplitReplacementAlignment() {
        let patch = "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"
        let rows = PatchPreviewRows.make(DiffParser.parse(patch), sideBySide: true, compact: true)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.left?.text, "old")
        XCTAssertEqual(rows.first?.right?.text, "new")
    }
    func testMetadataFilteredByKindButIdenticalCodeTextRetained() {
        let patch = "diff --git a/file b/file\nnew file mode 100644\n--- /dev/null\n+++ b/file\n@@ -0,0 +1,2 @@\n+new file mode 100644\n+@@ real source\n"
        let rows = PatchPreviewRows.make(DiffParser.parse(patch), sideBySide: true, compact: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { $0.right?.text }, ["new file mode 100644", "@@ real source"])
        XCTAssertEqual(rows.compactMap { $0.right?.newNumber }, [1, 2])
        XCTAssertTrue(rows.allSatisfy { $0.left == nil })
    }
    func testCompactRetainsRealNumbersAndTrailingOneSidedChanges() {
        let patch = "@@ -40,4 +70,4 @@\n before\n-old\n+new\n unchanged\n-after\n@@ -90,0 +120,1 @@\n+tail\n"
        let rows = PatchPreviewRows.make(DiffParser.parse(patch), sideBySide: true, compact: true)
        XCTAssertFalse(rows.contains { $0.left?.kind == .context || $0.right?.kind == .context })
        XCTAssertEqual(rows.compactMap { $0.left?.oldNumber }, [41, 43])
        XCTAssertEqual(rows.compactMap { $0.right?.newNumber }, [71, 120])
        XCTAssertEqual(rows.last?.right?.text, "tail")
        XCTAssertNil(rows.last?.left)
        XCTAssertEqual(rows.last?.hunk, 1)
    }
    func testFullAndCompactUseIdenticalChangedLinePairing() {
        let diff = DiffParser.parse("@@ -7,3 +7,4 @@\n context\n-one\n-two\n+one changed\n+two changed\n+extra\n")
        let full = PatchPreviewRows.make(diff, sideBySide: true, compact: false).filter(\.isChange)
        let compact = PatchPreviewRows.make(diff, sideBySide: true, compact: true)
        XCTAssertEqual(full.map { $0.left?.oldNumber }, compact.map { $0.left?.oldNumber })
        XCTAssertEqual(full.map { $0.right?.newNumber }, compact.map { $0.right?.newNumber })
        XCTAssertEqual(compact.compactMap { $0.left?.text }, ["one", "two"])
        XCTAssertEqual(compact.compactMap { $0.right?.text }, ["one changed", "two changed", "extra"])
    }
}
