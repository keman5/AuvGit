import XCTest
import GitCore
@testable import RayGit

final class AICommitInputPolicyTests: XCTestCase {
    func testRememberedScopeCanBeChangedAndForgotten() throws {
        let name = "AICommitScopeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(AICommitScopeChoice.remembered(defaults: defaults))
        AICommitScopeChoice.save(.workspace, remember: true, defaults: defaults)
        XCTAssertEqual(AICommitScopeChoice.remembered(defaults: defaults), .workspace)
        AICommitScopeChoice.save(.staged, remember: true, defaults: defaults)
        XCTAssertEqual(AICommitScopeChoice.remembered(defaults: defaults), .staged)
        AICommitScopeChoice.save(.workspace, remember: false, defaults: defaults)
        XCTAssertNil(AICommitScopeChoice.remembered(defaults: defaults))
        XCTAssertTrue(AICommitInputPolicy.patchPrompt("patch", scope: .workspace).contains("unstaged, and untracked"))
        XCTAssertFalse(AICommitInputPolicy.patchPrompt("patch", scope: .workspace).contains("based only on the staged patch"))
    }

    @MainActor
    func testGenerateWithEmptyIndexReportsStagingRequirement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        try Data("unstaged content".utf8).write(to: root.appendingPathComponent("unstaged.txt"))
        let store = RepositoryStore(persistsSession: false)
        store.repository = repository
        store.repositoryURL = repository.url
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

    @MainActor
    func testGenerationRefreshesChangedInputAndPreservesManualDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        let file = root.appendingPathComponent("example.txt")
        try Data("initial\n".utf8).write(to: file)
        _ = try await repository.workflowRead(["add", "."])
        let store = RepositoryStore(persistsSession: false)
        store.repository = repository
        store.repositoryURL = repository.url
        for scope in AICommitScope.allCases {
            var calls = 0
            store.commitMessage = "Draft"
            let controller = AICommitController { prompt, _ in
                calls += 1
                if calls == 1 {
                    try Data("latest-\(scope.rawValue)\n".utf8).write(to: file)
                    if scope == .staged { _ = try await repository.workflowRead(["add", "."]) }
                    return "Outdated result"
                }
                XCTAssertTrue(prompt.contains("latest-\(scope.rawValue)"))
                return "Latest result"
            }
            controller.generate(store: store, scope: scope)
            for _ in 0..<500 where controller.isLoading { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(controller.isLoading)
            XCTAssertNil(controller.error)
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(store.commitMessage, "Latest result")
        }
        let controller = AICommitController { _, _ in
            store.commitMessage = "Manually edited"
            return "Must not overwrite"
        }
        controller.generate(store: store, scope: .workspace)
        for _ in 0..<500 where controller.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(controller.isLoading)
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(store.commitMessage, "Manually edited")
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
