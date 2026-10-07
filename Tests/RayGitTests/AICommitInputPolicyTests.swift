import XCTest
import GitCore
@testable import RayGit

final class AICommitInputPolicyTests: XCTestCase {
    @MainActor
    func testGenerateWithEmptyIndexReportsStagingRequirement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        try Data("unstaged content".utf8).write(to: root.appendingPathComponent("unstaged.txt"))
        let store = RepositoryStore(persistsSession: false)
        store.repository = repository
        store.repositoryURL = root
        store.commitMessage = "Existing draft"
        let controller = AICommitController()

        controller.generate(store: store)
        XCTAssertTrue(controller.isLoading)
        for _ in 0..<200 where controller.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(controller.isLoading)
        XCTAssertEqual(controller.error, aiCommitText("No staged changes"))
        XCTAssertEqual(store.commitMessage, "Existing draft")
        let index = try await repository.workflowRead(["ls-files", "--stage"])
        XCTAssertTrue(index.isEmpty)
    }

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
