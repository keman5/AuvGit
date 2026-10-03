import XCTest
@testable import GitCore

final class FileManagementTests: XCTestCase {
    func testTreeRenameLiteralIgnoreAndProtectedPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await GitProcess.run(at: dir, arguments: ["init"])
        let repo = GitRepository(url: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("source".utf8).write(to: dir.appendingPathComponent("folder/file"))
        try Data("wild".utf8).write(to: dir.appendingPathComponent("literal[1]* name "))
        try Data("other".utf8).write(to: dir.appendingPathComponent("literal1X name "))
        var tree = try await repo.workspaceTree()
        XCTAssertEqual(tree.first { $0.path == "folder" }?.children.first?.path, "folder/file")
        try await repo.renameWorkspaceFile(path: "folder/file", destination: "folder/renamed")
        do { try await repo.renameWorkspaceFile(path: "folder/renamed", destination: "literal1X name "); XCTFail("prevent overwrite") } catch { }
        do { try await repo.renameWorkspaceFile(path: "folder/renamed", destination: "../escape"); XCTFail("prevent traversal") } catch { }
        try await repo.ignoreWorkspacePath("literal[1]* name ", directory: false)
        try await repo.ignoreWorkspacePath("folder", directory: true)
        let ignored = try await repo.ignoredWorkspacePaths()
        XCTAssertTrue(ignored.contains("literal[1]* name ")); XCTAssertTrue(ignored.contains("folder/renamed")); XCTAssertFalse(ignored.contains("literal1X name "))
        tree = try await repo.workspaceTree(); XCTAssertFalse(tree.contains { $0.path == "folder" })
        let expected = try Data(contentsOf: dir.appendingPathComponent(".gitignore"))
        try await repo.saveGitignore(text: "# updated\n", expected: expected)
        do { try await repo.saveGitignore(text: "overwrite", expected: expected); XCTFail("stale ignore edit") } catch { }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("folder"))
        do { try await repo.renameWorkspaceFile(path: "link/renamed", destination: "moved"); XCTFail("symlink parent") } catch { }
    }
    func testTrashAndRestoreWithoutOverwrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = GitRepository(url: dir), file = dir.appendingPathComponent("trash file")
        try Data("original".utf8).write(to: file)
        let trashed = try await repo.trashWorkspaceFile(path: "trash file")
        defer { try? FileManager.default.removeItem(at: trashed.trashURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("new".utf8).write(to: file)
        do { try await repo.restoreWorkspaceFile(trashed); XCTFail("restore must not overwrite") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        try FileManager.default.removeItem(at: file); try await repo.restoreWorkspaceFile(trashed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }
}
