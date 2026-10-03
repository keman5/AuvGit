import XCTest
@testable import GitCore
final class InteractiveRebaseTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rebase space " + UUID().uuidString)
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"]); _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "base"])
        return (root, repo)
    }
    private func commit(_ repo: GitRepository, path: String, message: String) async throws {
        try message.write(to: repo.url.appendingPathComponent(path), atomically: true, encoding: .utf8)
        try await repo.stage(paths: [path]); try await repo.commit(message: message)
    }
    func testGitGeneratedMergePlanPreservesTopologyAndRecoveryRef() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.workflowRevision("HEAD"), main = try await repo.currentBranch()
        try await repo.createBranch(name: "topic"); try await commit(repo, path: "topic", message: "topic")
        try await repo.checkout(branch: main); try await commit(repo, path: "main", message: "main")
        _ = try await repo.workflowRead(["merge", "--no-ff", "--no-edit", "topic"])
        let oldHead = try await repo.workflowRevision("HEAD")
        _ = try await repo.workflowRead(["update-ref", "ORIG_HEAD", base])
        let indexURL = try await repo.rebaseGitPath("index"); let index = try Data(contentsOf: indexURL)
        let reflog = try await repo.workflowRead(["reflog", "--format=%H %gs"])
        let plan = try await repo.generatedRebasePlan(onto: base)
        XCTAssertTrue(plan.todo.contains("merge -C")); XCTAssertTrue(plan.todo.contains("label")); XCTAssertTrue(plan.todo.contains("reset"))
        XCTAssertEqual(try Data(contentsOf: indexURL), index)
        let recovery = try await repo.workflowRevision("ORIG_HEAD"); XCTAssertEqual(recovery, base)
        let afterPreview = try await repo.workflowRevision("HEAD"); XCTAssertEqual(afterPreview, oldHead)
        let afterReflog = try await repo.workflowRead(["reflog", "--format=%H %gs"]); XCTAssertEqual(afterReflog, reflog)
        _ = try await repo.executeRebase(plan: plan, editedTodo: plan.todo, messages: [:], allowExec: false)
        let parents = try await repo.workflowRead(["show", "-s", "--format=%P", "HEAD"]).split(separator: " "); XCTAssertEqual(parents.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("topic").path)); XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("main").path))
        let messagePlan = try await repo.generatedRebasePlan(onto: base)
        let changed = messagePlan.todo.replacingOccurrences(of: "merge -C", with: "merge -c")
        let mergeLine = try XCTUnwrap(changed.components(separatedBy: "\n").firstIndex { $0.hasPrefix("merge -c") })
        _ = try await repo.executeRebase(plan: messagePlan, editedTodo: changed, messages: [mergeLine: "rebuilt merge\n\nfull merge body"], allowExec: false)
        let message = try await repo.workflowRead(["show", "-s", "--format=%B", "HEAD"])
        XCTAssertEqual(message.trimmingCharacters(in: .newlines), "rebuilt merge\n\nfull merge body")
    }
    func testMultilineRewordSquashExecAndInvalidPlanPreflight() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.workflowRevision("HEAD")
        try await commit(repo, path: "one", message: "one\n\nold body"); try await commit(repo, path: "two", message: "two")
        let plan = try await repo.generatedRebasePlan(onto: base)
        let rows = try await repo.log(); let first = rows[1].hash, second = rows[0].hash
        let edited = "reword \(first)\nsquash \(second)\nexec /usr/bin/touch '\(root.path)/exec-confirmed'\n"
        do { _ = try await repo.executeRebase(plan: plan, editedTodo: edited, messages: [:], allowExec: false); XCTFail("Exec was not confirmed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exec-confirmed").path))
        for invalid in ["pick \(first)\npick \(first)", "squash \(first)\npick \(second)", "unknown \(first)\ndrop \(second)"] {
            do { _ = try await repo.executeRebase(plan: plan, editedTodo: invalid, messages: [:], allowExec: true); XCTFail("Invalid todo accepted") } catch {}
            let head = try await repo.workflowRevision("HEAD"); XCTAssertEqual(head, plan.head)
        }
        _ = try await repo.executeRebase(plan: plan, editedTodo: edited, messages: [0: "reword subject\n\nreword body", 1: "squash subject\n\ncomplete squash body\nsecond paragraph"], allowExec: true)
        let message = try await repo.workflowRead(["show", "-s", "--format=%B", "HEAD"])
        XCTAssertEqual(message.trimmingCharacters(in: .newlines), "squash subject\n\ncomplete squash body\nsecond paragraph")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("exec-confirmed").path))
    }
    func testEmptyCommitGeneratedPlanCanExecuteAndActiveOperationIsRejected() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let base = try await repo.workflowRevision("HEAD")
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "empty retained"])
        let plan = try await repo.generatedRebasePlan(onto: base)
        _ = try await repo.executeRebase(plan: plan, editedTodo: plan.todo, messages: [:], allowExec: false)
        let rows = try await repo.log(); XCTAssertEqual(rows[0].subject, "empty retained")
        let paused = try await repo.generatedRebasePlan(onto: base)
        let todo = paused.todo.replacingOccurrences(of: "pick ", with: "edit ")
        _ = try await repo.executeRebase(plan: paused, editedTodo: todo, messages: [:], allowExec: false)
        do { _ = try await repo.generatedRebasePlan(onto: base); XCTFail("Active rebase overwritten") } catch {}
        _ = try await repo.advancedOperation(.rebaseAbort, first: "", second: "")
    }
    func testPlanRetainsPatchEquivalentUpstreamCommit() async throws {
        let (root, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let main = try await repo.currentBranch()
        try await repo.createBranch(name: "topic")
        try await commit(repo, path: "same", message: "same patch")
        try await repo.checkout(branch: main)
        try "same patch".write(to: root.appendingPathComponent("same"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["same"]); try await repo.commit(message: "upstream equivalent")
        let upstream = try await repo.workflowRevision("HEAD")
        try await repo.checkout(branch: "topic")
        let plan = try await repo.generatedRebasePlan(onto: upstream)
        XCTAssertTrue(plan.todo.contains("pick"))
        _ = try await repo.executeRebase(plan: plan, editedTodo: plan.todo, messages: [:], allowExec: false)
        let history = try await repo.log(ref: "topic")
        XCTAssertTrue(history.contains { $0.subject == "same patch" }); XCTAssertTrue(history.contains { $0.subject == "upstream equivalent" })
    }

}
