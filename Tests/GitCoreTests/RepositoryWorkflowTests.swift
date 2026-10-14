import XCTest
@testable import GitCore
final class RepositoryWorkflowTests: XCTestCase {
    func testReferenceCompareBlamePartialStashAndReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        try "first\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["a file"]); try await repo.commit(message: "first")
        try "second\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["a file"]); try await repo.commit(message: "second")
        let diff = try await repo.compareReferences("HEAD~1", "HEAD"); XCTAssertTrue(diff.contains("+second"))
        let blame = try await repo.blameText(path: "a file", revision: "HEAD"); XCTAssertTrue(blame.contains("Tester"))
        try "third\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try "keep\n".write(to: root.appendingPathComponent("other"), atomically: true, encoding: .utf8)
        _ = try await repo.advancedOperation(.partialStash, first: "a file", second: "partial")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a file"), encoding: .utf8), "second\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
        _ = try await repo.advancedOperation(.resetSoft, first: "HEAD~1", second: "")
        let status = try await repo.status(); XCTAssertTrue(status.contains { $0.path == "a file" && $0.isStaged })
        do { _ = try await repo.compareReferences("--all", "HEAD"); XCTFail("Option revision accepted") } catch { }
        do { _ = try await repo.blameText(path: "../outside", revision: "HEAD"); XCTFail("Traversal accepted") } catch { }
    }
    func testCloneAndRemotePreviewWithLocalBareRepository() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bare = parent.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: parent, arguments: ["init", "--bare", bare.path])
        let repo = try await GitRepository.clone(source: bare.path, destination: parent.appendingPathComponent("clone"))
        let remotes = try await repo.advancedOperation(.remoteList, first: "", second: "")
        XCTAssertTrue(remotes.contains("origin"))
        _ = try await repo.advancedOperation(.remoteAdd, first: "second", second: bare.path)
        _ = try await repo.advancedOperation(.remoteRemove, first: "second", second: "")
        let after = try await repo.advancedOperation(.remoteList, first: "", second: "")
        XCTAssertFalse(after.contains("second"))
    }
}

extension RepositoryWorkflowTests {
    func testStashRenamePreservesEveryObjectOrderAndTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        try "base".write(to: root.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["a"]); try await repo.commit(message: "base")
        for i in 1...3 { try "change \(i)".write(to: root.appendingPathComponent("a"), atomically: true, encoding: .utf8); try await repo.stash(message: "stash \(i)") }
        let before = try await repo.workflowRead(["stash", "list", "--format=%H %gt"])
        _ = try await repo.renameStash(reference: "stash@{1}", message: "renamed")
        let after = try await repo.workflowRead(["stash", "list", "--format=%H %gt"])
        XCTAssertEqual(before, after)
        let stashes = try await repo.stashes(); XCTAssertEqual(stashes.count, 3); XCTAssertEqual(stashes[1].subject, "renamed"); XCTAssertTrue(stashes[0].subject.contains("stash 3")); XCTAssertTrue(stashes[2].subject.contains("stash 1"))
        do { _ = try await repo.renameStash(reference: "stash@{9}", message: "bad"); XCTFail("Invalid stash accepted") } catch { }
        let final = try await repo.workflowRead(["stash", "list", "--format=%H %gt"]); XCTAssertEqual(before, final)
    }
}

extension RepositoryWorkflowTests {
    func testInteractiveRebaseDropFixupAndInvalidPlans() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        for i in 0...3 { try "\(i)".write(to: root.appendingPathComponent("file\(i)"), atomically: true, encoding: .utf8); try await repo.stage(paths: ["file\(i)"]); try await repo.commit(message: "commit \(i)") }
        let rows = try await repo.log(); let head = rows[0].hash, base = rows[3].hash
        let plan = "pick \(rows[2].hash) first\nfixup \(rows[1].hash) second\ndrop \(rows[0].hash) third\n"
        for invalid in ["pick \(rows[2].hash)\n", "pick \(rows[2].hash)\npick \(rows[2].hash)\ndrop \(rows[0].hash)", "drop \(rows[2].hash)\nfixup \(rows[1].hash)\ndrop \(rows[0].hash)"] {
            do { _ = try await repo.interactiveRebase(onto: base, plan: invalid); XCTFail("Invalid plan accepted") } catch { }
            let current = try await repo.workflowRevision("HEAD"); XCTAssertEqual(current, head)
        }
        try "dirty".write(to: root.appendingPathComponent("untracked"), atomically: true, encoding: .utf8)
        do { _ = try await repo.interactiveRebase(onto: base, plan: plan); XCTFail("Dirty rebase accepted") } catch { }
        try FileManager.default.removeItem(at: root.appendingPathComponent("untracked"))
        _ = try await repo.interactiveRebase(onto: base, plan: plan)
        let after = try await repo.log(); XCTAssertEqual(after.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("file2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file3").path))
    }
}

extension RepositoryWorkflowTests {
    func testMergeConflictAbortAndContinue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        try "base\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "base")
        let branch = try await repo.currentBranch()
        try await repo.createBranch(name: "topic")
        try "topic\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "topic")
        try await repo.checkout(branch: branch)
        try "main\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "main")
        for action in [RepositoryWorkflow.mergeAbort, .mergeContinue] {
            do { _ = try await repo.advancedOperation(.merge, first: "topic", second: ""); XCTFail("Expected conflict") } catch { }
            let status = try await repo.status(); XCTAssertTrue(status.contains { $0.isConflict })
            if action == .mergeContinue {
                try "resolved\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
                let snapshot = try await repo.fileComparison(path: "file")
                try await repo.markResolved(path: "file", expected: snapshot.worktree)
            }
            _ = try await repo.advancedOperation(action, first: "", second: "")
            let clean = try await repo.status(); XCTAssertTrue(clean.isEmpty)
        }
        let rows = try await repo.log(); XCTAssertEqual(rows[0].parents.count, 2)
        let base = rows.last!.hash
        let plan = try await repo.advancedOperation(.rebasePlan, first: base, second: "")
        XCTAssertTrue(plan.contains("merge -C"))
    }
    func testAuthorFilterPrecedesPagination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        for (i, author) in ["Alice", "Bob", "Alice"].enumerated() {
            _ = try await repo.workflowRead(["config", "user.name", author])
            try "\(i)".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
            try await repo.stage(paths: ["file"]); try await repo.commit(message: "commit \(i)")
        }
        let rows = try await repo.log(limit: 1, skip: 1, author: "Alice")
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0].subject, "commit 0")
    }
}

extension RepositoryWorkflowTests {
    func testInteractiveRebaseRewordAndEditStopContinue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        for i in 0...2 { try "\(i)".write(to: root.appendingPathComponent("file\(i)"), atomically: true, encoding: .utf8); try await repo.stage(paths: ["file\(i)"]); try await repo.commit(message: "commit \(i)") }
        let rows = try await repo.log(); let base = rows[2].hash
        _ = try await repo.interactiveRebase(onto: base, plan: "reword \(rows[1].hash) rewritten subject\nedit \(rows[0].hash) stop\n")
        let intermediate = try await repo.log(); XCTAssertTrue(intermediate.contains { $0.subject == "rewritten subject" })
        try "amended".write(to: root.appendingPathComponent("file2"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file2"]); try await repo.commit(message: "edited commit", amend: true)
        _ = try await repo.advancedOperation(.rebaseContinue, first: "", second: "")
        let final = try await repo.log(); XCTAssertEqual(final[0].subject, "edited commit")
    }
}

extension RepositoryWorkflowTests {
    func testTagManagementLocalBarePreviewPublishAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = root.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", bare.path])
        let repo = try await GitRepository.initialize(at: root.appendingPathComponent("local"))
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        _ = try await repo.workflowRead(["remote", "add", "origin", bare.path])
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "base"])
        try await repo.createManagedTag(name: "v1", revision: "HEAD", message: "release", signed: false)
        let tags = try await repo.managedTags(); XCTAssertEqual(tags.map(\.name), ["v1"]); XCTAssertEqual(tags[0].message, "release")
        _ = try await repo.synchronizeTag(name: "v1", remote: "origin", delete: false, preview: true)
        let absent = try await GitProcess.run(at: bare, arguments: ["show-ref", "--verify", "refs/tags/v1"], allowedCodes: [0, 128]); XCTAssertNotEqual(absent.code, 0)
        _ = try await repo.synchronizeTag(name: "v1", remote: "origin", delete: false, preview: false)
        _ = try await GitProcess.run(at: bare, arguments: ["show-ref", "--verify", "refs/tags/v1"])
        _ = try await repo.synchronizeTag(name: "v1", remote: "origin", delete: true, preview: true)
        _ = try await GitProcess.run(at: bare, arguments: ["show-ref", "--verify", "refs/tags/v1"])
        _ = try await repo.synchronizeTag(name: "v1", remote: "origin", delete: true, preview: false)
        let deleted = try await GitProcess.run(at: bare, arguments: ["show-ref", "--verify", "refs/tags/v1"], allowedCodes: [0, 128]); XCTAssertNotEqual(deleted.code, 0)
    }
}

extension RepositoryWorkflowTests {
    func testManagedTagsSeparateCommitHashesFromTagObjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        try "content".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "base")
        let head = try await repo.workflowRevision("HEAD")
        try await repo.createManagedTag(name: "annotated", revision: "HEAD", message: "annotation", signed: false)
        try await repo.createManagedTag(name: "lightweight", revision: "HEAD", message: "", signed: false)
        _ = try await repo.workflowRead(["tag", "-a", "nested", "-m", "nested annotation", "annotated"])
        let blob = try await repo.workflowRead(["rev-parse", "HEAD:file"]).trimmingCharacters(in: .newlines)
        _ = try await repo.workflowRead(["tag", "blob", blob])
        let tags = try await repo.managedTags()
        let annotated = try XCTUnwrap(tags.first { $0.name == "annotated" })
        XCTAssertEqual(annotated.commitHash, head)
        XCTAssertNotEqual(annotated.objectHash, head)
        let tagObject = try await repo.workflowRead(["rev-parse", "refs/tags/annotated"]).trimmingCharacters(in: .newlines)
        XCTAssertEqual(annotated.objectHash, tagObject)
        let lightweight = try XCTUnwrap(tags.first { $0.name == "lightweight" })
        XCTAssertEqual(lightweight.commitHash, head); XCTAssertEqual(lightweight.objectHash, head)
        XCTAssertEqual(tags.first { $0.name == "nested" }?.commitHash, head)
        let blobTag = try XCTUnwrap(tags.first { $0.name == "blob" })
        XCTAssertNil(blobTag.commitHash); XCTAssertEqual(blobTag.objectHash, blob)
    }
}
