import XCTest
@testable import GitCore

final class FileComparisonTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "core.autocrlf", "false"]] {
            _ = try await GitProcess.run(at: url, arguments: args)
        }
        return (url, GitRepository(url: url))
    }
    func testThreeRevisionsSavingAndExternalChanges() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let path = "[literal] name\n.txt", file = url.appendingPathComponent(path)
        try Data("head\n".utf8).write(to: file)
        try await repo.stage(paths: [path]); try await repo.commit(message: "Initial")
        try Data("index\n".utf8).write(to: file); try await repo.stage(paths: [path])
        try Data("disk\n".utf8).write(to: file)
        let snapshot = try await repo.fileComparison(path: path)
        XCTAssertEqual(snapshot.head.text, "head\n"); XCTAssertEqual(snapshot.index.text, "index\n"); XCTAssertEqual(snapshot.worktree.text, "disk\n")
        let saved = try await repo.saveWorktree(path: path, text: "saved", expected: snapshot.worktree)
        XCTAssertEqual(saved.text, "saved")
        let after = try await repo.fileComparison(path: path)
        XCTAssertEqual(after.index.text, "index\n")
        try Data("external".utf8).write(to: file)
        do { _ = try await repo.saveWorktree(path: path, text: "overwrite", expected: saved); XCTFail("Must detect external writes") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
    }
    func testUnbornDeletedBinarySymlinkAndEncoding() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("text")
        let bytes = Data([0xef, 0xbb, 0xbf]) + Data("one\r\ntwo\r\n".utf8)
        try bytes.write(to: file)
        let initial = try await repo.fileComparison(path: "text")
        XCTAssertFalse(initial.head.exists); XCTAssertFalse(initial.index.exists)
        XCTAssertEqual(initial.worktree.text, "one\ntwo\n")
        _ = try await repo.saveWorktree(path: "text", text: "three\nfour", expected: initial.worktree)
        XCTAssertEqual(try Data(contentsOf: file), Data([0xef, 0xbb, 0xbf]) + Data("three\r\nfour".utf8))
        try await repo.stage(paths: ["text"]); try await repo.commit(message: "Initial")
        try FileManager.default.removeItem(at: file)
        let deleted = try await repo.fileComparison(path: "text")
        XCTAssertTrue(deleted.head.exists); XCTAssertTrue(deleted.index.exists); XCTAssertFalse(deleted.worktree.exists)
        try Data([1, 0, 2]).write(to: url.appendingPathComponent("binary"))
        let binary = try await repo.fileComparison(path: "binary")
        XCTAssertTrue(binary.worktree.isBinary); XCTAssertFalse(binary.worktree.isEditable)
        try Data([0xff, 0xfe, 0x61]).write(to: url.appendingPathComponent("invalid"))
        let invalid = try await repo.fileComparison(path: "invalid")
        XCTAssertFalse(invalid.worktree.isEditable)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("link"), withDestinationURL: url.appendingPathComponent("binary"))
        let link = try await repo.fileComparison(path: "link")
        XCTAssertFalse(link.worktree.isEditable)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("parent"), withDestinationURL: url)
        do { _ = try await repo.fileComparison(path: "parent/binary"); XCTFail("Must reject symlink parents") } catch { }
        do { _ = try await repo.fileComparison(path: ".git/config"); XCTFail("Must reject git internals") } catch { }
    }
    func testRenameLargeFilePermissionsAndModePreservation() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = url.appendingPathComponent("old"), renamed = url.appendingPathComponent("new")
        try Data("original\n".utf8).write(to: old)
        try await repo.stage(paths: ["old"]); try await repo.commit(message: "Initial")
        try FileManager.default.moveItem(at: old, to: renamed)
        try await repo.stage(paths: ["old", "new"])
        let snapshot = try await repo.fileComparison(path: "new")
        XCTAssertEqual(snapshot.head.text, "original\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renamed.path)
        let executable = try await repo.fileComparison(path: "new")
        _ = try await repo.saveWorktree(path: "new", text: "edited\n", expected: executable.worktree)
        let attributes = try FileManager.default.attributesOfItem(atPath: renamed.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: renamed.path)
        let readOnly = try await repo.fileComparison(path: "new")
        XCTAssertFalse(readOnly.worktree.isEditable)
        do { _ = try await repo.saveWorktree(path: "new", text: "fail", expected: readOnly.worktree); XCTFail("Must reject read-only files") } catch { }
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: url.appendingPathComponent("large"))
        let large = try await repo.fileComparison(path: "large")
        XCTAssertFalse(large.worktree.isEditable); XCTAssertNotNil(large.worktree.unavailableReason)
    }
    func testMixedLineEndingsAreReadOnly() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("mixed")
        let bytes = Data("first\r\nsecond\nthird\r\n".utf8)
        try bytes.write(to: file)
        let snapshot = try await repo.fileComparison(path: "mixed")
        XCTAssertEqual(snapshot.worktree.text, "first\nsecond\nthird\n")
        XCTAssertFalse(snapshot.worktree.isEditable)
        XCTAssertEqual(snapshot.worktree.unavailableReason, "Files with mixed line endings are read-only.")
        do {
            _ = try await repo.saveWorktree(path: "mixed", text: "changed\n", expected: snapshot.worktree)
            XCTFail("Must preserve mixed endings by refusing text-editor saves")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testConflictStagesAndExplicitResolution() async throws {
        let (url, repo) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = url.appendingPathComponent("conflict")
        try Data("base\n".utf8).write(to: file); try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "Base")
        _ = try await GitProcess.run(at: url, arguments: ["checkout", "-b", "other"])
        try Data("theirs\n".utf8).write(to: file); try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "Other")
        _ = try await GitProcess.run(at: url, arguments: ["checkout", "main"])
        try Data("ours\n".utf8).write(to: file); try await repo.stage(paths: ["conflict"]); try await repo.commit(message: "Main")
        _ = try await GitProcess.run(at: url, arguments: ["merge", "other"], allowedCodes: [1])
        let conflict = try await repo.fileComparison(path: "conflict")
        XCTAssertTrue(conflict.isConflict); XCTAssertEqual(conflict.base?.text, "base\n"); XCTAssertEqual(conflict.ours?.text, "ours\n"); XCTAssertEqual(conflict.theirs?.text, "theirs\n")
        do { try await repo.markResolved(path: "conflict", expected: conflict.worktree); XCTFail("Must reject markers") } catch { }
        let resolved = try await repo.saveWorktree(path: "conflict", text: "merged\n", expected: conflict.worktree)
        let beforeStage = try await repo.fileComparison(path: "conflict")
        XCTAssertTrue(beforeStage.isConflict)
        try await repo.markResolved(path: "conflict", expected: resolved)
        let afterStage = try await repo.fileComparison(path: "conflict")
        XCTAssertFalse(afterStage.isConflict); XCTAssertEqual(afterStage.index.text, "merged\n")
    }
}
