import XCTest
@testable import GitCore

final class StashTimestampTests: XCTestCase {
    func testStashCreationTimesRemainAttachedWhenRenamed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-stash-date-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.hooksPath", root.appendingPathComponent("no-hooks").path]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        let repository = GitRepository(url: root)
        let empty = try await repository.stashes()
        XCTAssertTrue(empty.isEmpty)
        let file = root.appendingPathComponent("file.txt")
        try Data("base\n".utf8).write(to: file)
        try await repository.stage(paths: ["file.txt"])
        try await repository.commit(message: "Base")
        for (timestamp, message) in [(1_700_000_000, "first"), (1_700_003_600, "second")] {
            try Data((message + "\n").utf8).write(to: file)
            _ = try await GitProcess.run(at: root, arguments: ["stash", "push", "-m", message], environmentOverrides: ["GIT_COMMITTER_DATE": "@\(timestamp) +0000"])
        }
        let stashes = try await repository.stashes()
        XCTAssertEqual(stashes.map(\.ref), ["stash@{0}", "stash@{1}"])
        XCTAssertEqual(stashes.map { $0.createdDate?.timeIntervalSince1970 }, [1_700_003_600, 1_700_000_000])
        _ = try await repository.renameStash(reference: "stash@{1}", message: "renamed")
        let renamed = try await repository.stashes()
        XCTAssertEqual(renamed.map(\.createdDate), stashes.map(\.createdDate))
        XCTAssertEqual(renamed[1].subject, "renamed")
        XCTAssertEqual(renamed.map(\.hash), stashes.map(\.hash))
    }

    func testCachedStashesWithoutDateStillDecode() throws {
        let data = Data(#"{"ref":"stash@{0}","subject":"Saved work","hash":"abc"}"#.utf8)
        let stash = try JSONDecoder().decode(GitStash.self, from: data)
        XCTAssertNil(stash.createdDate)
        let dated = GitStash(ref: stash.ref, subject: stash.subject, hash: stash.hash, createdDate: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try JSONDecoder().decode(GitStash.self, from: JSONEncoder().encode(dated)), dated)
    }
}
