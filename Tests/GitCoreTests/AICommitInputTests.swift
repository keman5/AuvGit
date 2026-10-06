import XCTest
@testable import GitCore

final class AICommitInputTests: XCTestCase {
    func testBoundedReadRejectsPartialPatchAndAllowsExplicitLargerLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        try Data(String(repeating: "staged content\n", count: 200).utf8).write(to: root.appendingPathComponent("staged.txt"))
        _ = try await repository.workflowRead(["add", "staged.txt"])
        let arguments = ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color"]
        do {
            _ = try await repository.aiCommitRead(arguments, maximumBytes: 100)
            XCTFail("Partial patch must not be returned")
        } catch AICommitInputError.exceedsLimit {}
        let patch = try await repository.aiCommitRead(arguments, maximumBytes: 10_000)
        XCTAssertTrue(patch.contains("staged content"))
        let exact = try await repository.aiCommitRead(arguments, maximumBytes: patch.utf8.count)
        XCTAssertEqual(exact, patch)
        let status = try await repository.aiCommitRead(["diff", "--cached", "--name-status"], maximumBytes: 100)
        XCTAssertTrue(status.contains("staged.txt"))
        XCTAssertFalse(status.contains("staged content"))
    }
}
