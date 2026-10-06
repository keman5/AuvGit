import XCTest
@testable import GitCore

final class HistoryResetTests: XCTestCase {
    func testModesPreserveIndexAndWorktreeAsAdvertised() async throws {
        for mode in GitResetMode.allCases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try await GitRepository.initialize(at: root)
            _ = try await repo.workflowRead(["config", "user.name", "Tester"])
            _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
            for content in ["first", "second"] {
                try content.write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
                try await repo.stage(paths: ["file"]); try await repo.commit(message: content)
            }
            let target = try await repo.workflowRevision("HEAD~1")
            let context = try await repo.resetContext()
            _ = try await repo.reset(to: target, mode: mode, expected: context)
            let head = try await repo.workflowRevision("HEAD")
            let index = try await repo.workflowRead(["show", ":file"])
            XCTAssertEqual(head, target)
            XCTAssertEqual(index, mode == .soft ? "second" : "first")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file"), encoding: .utf8), [.mixed, .soft].contains(mode) ? "second" : "first")
        }
    }

    func testStaleBranchAndActiveOperationCannotReset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Tester"])
        _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "first"])
        let target = try await repo.workflowRevision("HEAD")
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "second"])
        let context = try await repo.resetContext()
        _ = try await repo.workflowRead(["switch", "-c", "other"])
        do { _ = try await repo.reset(to: target, mode: .hard, expected: context); XCTFail("Stale branch accepted") } catch { }
        var current = try await repo.workflowRevision("HEAD"); XCTAssertEqual(current, context.head)
        let marker = root.appendingPathComponent(".git/MERGE_HEAD")
        try target.write(to: marker, atomically: true, encoding: .utf8)
        do { _ = try await repo.reset(to: target, mode: .hard); XCTFail("Active merge accepted") } catch { }
        current = try await repo.workflowRevision("HEAD"); XCTAssertEqual(current, context.head)
        try FileManager.default.removeItem(at: marker)
        _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "third"])
        do { _ = try await repo.reset(to: target, mode: .hard, expected: context); XCTFail("Stale HEAD accepted") } catch { }
        current = try await repo.workflowRevision("HEAD"); XCTAssertNotEqual(current, context.head)
    }
}
