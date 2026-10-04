import XCTest
@testable import GitCore

final class AICommitDraftGuardTests: XCTestCase {
    func testGeneratedDraftOnlyAppliesToOriginalContext() {
        let repository = URL(fileURLWithPath: "/tmp/one")
        let guardValue = AICommitDraftGuard(repository: repository, stagedIdentity: "100644 blob\tfile\0", originalDraft: "User draft")
        XCTAssertNil(guardValue.rejection(repository: repository, stagedIdentity: "100644 blob\tfile\0", draft: "User draft", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: URL(fileURLWithPath: "/tmp/two"), stagedIdentity: "100644 blob\tfile\0", draft: "User draft", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: repository, stagedIdentity: "100644 other\tfile\0", draft: "User draft", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: repository, stagedIdentity: "100644 blob\tfile\0", draft: "Edited during generation", isBusy: false))
        XCTAssertNotNil(guardValue.rejection(repository: repository, stagedIdentity: "100644 blob\tfile\0", draft: "User draft", isBusy: true))
        XCTAssertNotNil(guardValue.rejection(repository: nil, stagedIdentity: "100644 blob\tfile\0", draft: "User draft", isBusy: false))
    }
}
