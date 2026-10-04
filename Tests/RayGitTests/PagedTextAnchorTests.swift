import XCTest
@testable import RayGit

final class PagedTextAnchorTests: XCTestCase {
    func testSearchPageContinuesFromItsActualSourcePosition() {
        XCTAssertEqual(PagedTextAnchor.after(String(repeating: "line\n", count: 500), firstLine: 20_000, firstColumn: 1), PagedTextAnchor(line: 20_500, column: 1))
    }
    func testPartialUnicodeLineRetainsColumnAndResetsAfterNewline() {
        XCTAssertEqual(PagedTextAnchor.after("😀tail", firstLine: 20_000, firstColumn: 17), PagedTextAnchor(line: 20_000, column: 23))
        XCTAssertEqual(PagedTextAnchor.after("tail\r\nnext", firstLine: 20_000, firstColumn: 17), PagedTextAnchor(line: 20_001, column: 5))
    }
}
