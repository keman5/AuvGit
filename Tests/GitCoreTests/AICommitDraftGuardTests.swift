import XCTest
@testable import GitCore

final class AICommitDraftGuardTests: XCTestCase {
    func testGeneratedDraftOnlyAppliesToOriginalContext() {
        let repository = URL(fileURLWithPath: "/tmp/one")
        let guardValue = AICommitDraftGuard(repository: repository, originalDraft: "User draft")
        XCTAssertNil(guardValue.rejection(repository: repository, draft: "User draft", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: URL(fileURLWithPath: "/tmp/two"), draft: "User draft", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: repository, draft: "Edited during generation", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: repository, draft: "User draft", isBusy: true))
        XCTAssertNotNil(guardValue.rejection(repository: nil, draft: "User draft", isBusy: false))
    }
}
