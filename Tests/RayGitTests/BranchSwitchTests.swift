import XCTest
@testable import RayGit
@testable import GitCore

@MainActor
final class BranchSwitchTests: XCTestCase {
    private func fixture() async throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "file.txt"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        _ = try await GitProcess.run(at: root, arguments: ["branch", "other"])
        return GitRepository(url: root)
    }
    private func settle(_ store: RepositoryStore) async throws {
        for _ in 0..<500 {
            if !store.isBusy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Branch operation did not finish")
    }
    func testFreshStatusOverridesBothStaleCleanAndStaleDirtyCache() async throws {
        let repository = try await fixture()
        defer { try? FileManager.default.removeItem(at: repository.url) }
        let store = RepositoryStore(persistsSession: false)
        await store.open(repository.url)
        try "dirty\n".write(to: repository.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        store.files = []
        var prompts = 0
        store.switchBranch(to: "other") { _ in prompts += 1; return false }
        // A competing UI request must be rejected while the first check is pending.
        store.switchBranch(to: "missing") { _ in XCTFail("Competing switch was accepted"); return true }
        try await settle(store)
        XCTAssertEqual(prompts, 1)
        let unchanged = try await repository.currentBranch()
        XCTAssertEqual(unchanged, "main")
        try "base\n".write(to: repository.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        store.files = [GitFile(path: "stale.txt", indexStatus: "?", worktreeStatus: "?")]
        store.switchBranch(to: "other") { _ in prompts += 1; return false }
        try await settle(store)
        XCTAssertEqual(prompts, 1)
        let switched = try await repository.currentBranch()
        XCTAssertEqual(switched, "other")
        XCTAssertNil(store.error)
    }
    func testChangesAddedDuringConfirmationRequireAnotherDecision() async throws {
        let repository = try await fixture()
        defer { try? FileManager.default.removeItem(at: repository.url) }
        try "first".write(to: repository.url.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        var prompts = 0
        do {
            try await BranchSwitch.perform(repository: repository, branch: "other", isCurrentRepository: { true }) { files in
                prompts += 1
                if prompts == 1 {
                    try? "second".write(to: repository.url.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
                    return true
                }
                XCTAssertEqual(Set(files.map(\.path)), ["first.txt", "second.txt"])
                return false
            }
            XCTFail("Declined switch should cancel")
        } catch is CancellationError { }
        XCTAssertEqual(prompts, 2)
        let branch = try await repository.currentBranch()
        XCTAssertEqual(branch, "main")
    }
    func testApprovedDirtySwitchStillPreservesGitOverwriteProtection() async throws {
        let repository = try await fixture()
        defer { try? FileManager.default.removeItem(at: repository.url) }
        try await repository.checkout(branch: "other")
        let file = repository.url.appendingPathComponent("file.txt")
        try "other version\n".write(to: file, atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["file.txt"])
        try await repository.commit(message: "Other")
        try await repository.checkout(branch: "main")
        try "unsaved work\n".write(to: file, atomically: true, encoding: .utf8)
        do {
            try await BranchSwitch.perform(repository: repository, branch: "other", isCurrentRepository: { true }, confirmChanges: { _ in true })
            XCTFail("Git must refuse to overwrite dirty tracked content")
        } catch is GitError { }
        let branch = try await repository.currentBranch()
        XCTAssertEqual(branch, "main")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unsaved work\n")
    }
    func testRepositoryChangeWhileDialogIsOpenCancelsCapturedTarget() async throws {
        let repository = try await fixture()
        defer { try? FileManager.default.removeItem(at: repository.url) }
        try "dirty".write(to: repository.url.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        var current = true
        do {
            try await BranchSwitch.perform(repository: repository, branch: "other", isCurrentRepository: { current }) { _ in current = false; return true }
            XCTFail("A stale repository request must cancel")
        } catch is CancellationError { }
        let branch = try await repository.currentBranch()
        XCTAssertEqual(branch, "main")
    }
}
