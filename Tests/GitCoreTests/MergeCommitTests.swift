import XCTest
@testable import GitCore

final class MergeCommitTests: XCTestCase {
    func testMergeCherryPickAndRevertRespectExplicitParent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) async throws -> String { try await GitProcess.run(at: directory, arguments: arguments).text.trimmingCharacters(in: .whitespacesAndNewlines) }
        for arguments in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] { _ = try await git(arguments) }
        try "base".write(to: directory.appendingPathComponent("base"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "base"])
        let base = try await git(["rev-parse", "HEAD"])
        _ = try await git(["switch", "-c", "topic"])
        try "topic".write(to: directory.appendingPathComponent("topic"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "topic"])
        let topic = try await git(["rev-parse", "HEAD"])
        _ = try await git(["switch", "main"])
        try "main".write(to: directory.appendingPathComponent("main"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "."]); _ = try await git(["commit", "-m", "main"])
        let firstParent = try await git(["rev-parse", "HEAD"])
        _ = try await git(["merge", "--no-ff", "topic", "-m", "merge"])
        let merge = try await git(["rev-parse", "HEAD"])
        let repo = GitRepository(url: directory)
        for parent in [nil, 0, 3, -1] as [Int?] {
            do { try await repo.cherryPick(hash: merge, mainline: parent); XCTFail("Invalid parent accepted") } catch { }
            do { try await repo.revert(hash: merge, mainline: parent); XCTFail("Invalid parent accepted") } catch { }
            let unchanged = try await git(["rev-parse", "HEAD"])
            XCTAssertEqual(unchanged, merge)
        }
        try await repo.revert(hash: merge, mainline: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("main").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("topic").path))
        _ = try await git(["switch", "-c", "pick-first", firstParent])
        try await repo.cherryPick(hash: merge, mainline: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("topic").path))
        _ = try await git(["switch", "-c", "pick-second", topic])
        try await repo.cherryPick(hash: merge, mainline: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("main").path))
        _ = try await git(["switch", "-c", "plain", base])
        do { try await repo.cherryPick(hash: topic, mainline: 1); XCTFail("Mainline accepted for plain commit") } catch { }
    }
}
