import XCTest
import GitCore
@testable import AuvGit

final class ExternalComparisonConfigurationTests: XCTestCase {
    func testBeyondCompareTemplatesKeepBaseAndOutputInCorrectPositions() throws {
        let files = ["left": "/tmp/left file", "right": "/tmp/right file", "base": "/tmp/base file", "result": "/tmp/result file"]
        let compare = try ExternalDiffArguments.expand(ExternalDiffArguments.parse(ExternalComparisonConfiguration.compareArguments), files: files)
        XCTAssertEqual(compare, ["-solo", "-ro", files["left"]!, files["right"]!])
        let merge = try ExternalDiffArguments.expand(ExternalDiffArguments.parse(ExternalComparisonConfiguration.mergeArguments), files: files)
        XCTAssertEqual(merge, ["-solo", files["left"]!, files["right"]!, files["base"]!, files["result"]!])
    }
}
