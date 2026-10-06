import XCTest
@testable import RayGit

final class AICommitInputPolicyTests: XCTestCase {
    func testPersistedLimitsAndBounds() throws {
        let name = "AICommitInputPolicyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AICommitInputPolicy.loadLimit(defaults: defaults), 120)
        AICommitInputPolicy.saveLimit(500, defaults: defaults)
        XCTAssertEqual(AICommitInputPolicy.loadLimit(defaults: defaults), 500)
        AICommitInputPolicy.saveLimit(Int.max, defaults: defaults)
        XCTAssertEqual(AICommitInputPolicy.loadLimit(defaults: defaults), 4000)
        defaults.set(-1, forKey: AICommitInputPolicy.limitKey)
        XCTAssertEqual(AICommitInputPolicy.loadLimit(defaults: defaults), 30)
    }
    func testSummaryPromptContainsMetadataWithoutPatchClaims() {
        let prompt = AICommitInputPolicy.summaryPrompt(status: "M\tFile.swift", stat: "1 file changed, 2 insertions(+)")
        XCTAssertTrue(prompt.contains("M\tFile.swift"))
        XCTAssertTrue(prompt.contains("2 insertions(+)"))
        XCTAssertTrue(prompt.contains("The patch has not been supplied"))
        XCTAssertTrue(prompt.contains("do not infer code behavior"))
        XCTAssertFalse(prompt.contains("<staged-patch>"))
    }
}
