import XCTest
@testable import GitCore

final class RepositoryContextTests: XCTestCase {
    func testRemoteUpdatesPreserveOtherURLsRemotesAndRefspecsAndRejectStaleSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func git(_ arguments: [String]) async throws -> String { try await GitProcess.run(at: directory, arguments: arguments).text }
        _ = try await git(["init"])
        _ = try await git(["remote", "add", "origin", "https://example.test/old"])
        _ = try await git(["config", "--add", "remote.origin.url", "https://example.test/secondary"])
        _ = try await git(["config", "--add", "remote.origin.pushurl", "ssh://example.test/push"])
        _ = try await git(["config", "--add", "remote.origin.pushurl", "ssh://example.test/secondary"])
        _ = try await git(["remote", "add", "other", "https://other.test/repo"])
        let refspec = try await git(["config", "--get-all", "remote.origin.fetch"])
        let repository = GitRepository(url: directory)
        let initial = try await repository.remoteConfigurations()
        let origin = try XCTUnwrap(initial.first { $0.name == "origin" })
        try await repository.updateRemoteURL(expected: origin, fetchIndex: 0, fetchURL: "https://example.test/new?x=$safe", pushURL: "ssh://example.test/newpush")
        let updated = try await repository.remoteConfigurations()
        XCTAssertEqual(updated.first { $0.name == "origin" }?.fetchURLs, ["https://example.test/new?x=$safe", "https://example.test/secondary"])
        XCTAssertEqual(updated.first { $0.name == "origin" }?.pushURLs, ["ssh://example.test/newpush", "ssh://example.test/secondary"])
        XCTAssertEqual(updated.first { $0.name == "other" }, initial.first { $0.name == "other" })
        let actualRefspec = try await git(["config", "--get-all", "remote.origin.fetch"])
        XCTAssertEqual(actualRefspec, refspec)
        do { try await repository.updateRemoteURL(expected: origin, fetchIndex: 0, fetchURL: "stale", pushURL: nil); XCTFail("Stale snapshot must not overwrite") } catch { }
    }
    func testIgnoreSnapshotMissingUTF8SymlinkAndStaleSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = GitRepository(url: directory), file = directory.appendingPathComponent(".gitignore")
        let missing = try await repository.gitignoreSnapshot(); XCTAssertNil(missing)
        try await repository.saveGitignore(text: "first\n", expected: missing)
        let snapshot = try await repository.gitignoreSnapshot()
        try Data("external\n".utf8).write(to: file)
        do { try await repository.saveGitignore(text: "overwrite", expected: snapshot); XCTFail("Must protect newer content") } catch { }
        try FileManager.default.removeItem(at: file)
        let destination = directory.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: destination)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: destination)
        do { _ = try await repository.gitignoreSnapshot(); XCTFail("Must reject symlink read") } catch { }
        do { try await repository.saveGitignore(text: "overwrite", expected: nil); XCTFail("Must reject symlink save") } catch { }
        XCTAssertEqual(try Data(contentsOf: destination), Data("untouched".utf8))
    }
}
