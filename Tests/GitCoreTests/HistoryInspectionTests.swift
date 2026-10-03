import XCTest
@testable import GitCore
final class HistoryInspectionTests: XCTestCase {
    func testStructuredBlameAndReflogUseTheirOwnDates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        _ = try await repo.workflowRead(["config", "user.name", "Japanese 日本語"]); _ = try await repo.workflowRead(["config", "user.email", "test@example.invalid"])
        try "first\n\tindented\n".write(to: root.appendingPathComponent("a file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["a file"]); try await repo.commit(message: "first")
        let hash = try await repo.workflowRevision("HEAD")
        let blame = try await repo.blameLines(path: "a file"); XCTAssertEqual(blame.map(\.line), [1,2]); XCTAssertEqual(blame[1].code, "\tindented"); XCTAssertEqual(blame[0].author, "Japanese 日本語"); XCTAssertEqual(blame[0].hash, hash)
        let logs = try await repo.reflogEntries(); XCTAssertTrue(logs.contains { $0.hash == hash && $0.action.contains("first") }); XCTAssertTrue(logs.allSatisfy { $0.date.timeIntervalSince1970 > 0 })
    }
}
