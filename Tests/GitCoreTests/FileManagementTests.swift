import XCTest
@testable import GitCore

final class FileManagementTests: XCTestCase {
    func testLargeWorkspaceTreeIndexesEachPathAndPreservesHierarchyAndOrder() {
        let flat = (0..<6_000).map { String(format: "file%04d", $0) }
        let paths = Set(flat + ["nested/b/deep.txt", "nested/a.txt", "nested/b/z.txt", "nested-prefix/file", "unicode/你好.txt", "literal name\n.txt"])
        let started = Date()
        let tree = GitRepository.workspaceTree(paths: paths)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.1, "Tree indexing must avoid a full path scan for each child")
        XCTAssertEqual(tree.count, 6_004)
        XCTAssertEqual(tree.map(\.path), (flat + ["nested", "nested-prefix", "unicode", "literal name\n.txt"]).sorted())
        XCTAssertTrue(tree.filter { $0.path.hasPrefix("file") }.allSatisfy { !$0.isDirectory && $0.children.isEmpty })
        let nested = tree.first { $0.path == "nested" }
        XCTAssertEqual(nested?.children.map(\.path), ["nested/a.txt", "nested/b"])
        XCTAssertEqual(nested?.children.last?.children.map(\.path), ["nested/b/deep.txt", "nested/b/z.txt"])
        XCTAssertEqual(tree.first { $0.path == "nested-prefix" }?.children.map(\.path), ["nested-prefix/file"])
        XCTAssertEqual(tree.first { $0.path == "unicode" }?.children.first?.path, "unicode/你好.txt")
        print("Workspace tree index 6000 flat paths plus nested hierarchy: \(elapsed * 1000)ms")
    }

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
    func testDiscardWorkspaceDeletesOnlySelectedUntrackedFilesAndPreservesIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        let repo = GitRepository(url: root)
        try Data("staged version".utf8).write(to: root.appendingPathComponent("tracked"))
        _ = try await GitProcess.run(at: root, arguments: ["add", "--", "tracked"])
        let stagedBefore = try await GitProcess.run(at: root, arguments: ["show", ":tracked"])
        try Data("unstaged version".utf8).write(to: root.appendingPathComponent("tracked"))
        for name in ["selected-new", "keep-new"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        do { try await repo.discardWorkspace(paths: ["tracked", "selected-new", "missing"]); XCTFail("Validate the whole batch before restoring or deleting anything") } catch { }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked"), encoding: .utf8), "unstaged version")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("selected-new").path))
        try await repo.discardWorkspace(paths: ["tracked", "selected-new"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("selected-new").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("keep-new").path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("tracked")), stagedBefore.data)
        let stagedAfter = try await GitProcess.run(at: root, arguments: ["show", ":tracked"])
        XCTAssertEqual(stagedAfter.data, stagedBefore.data)
        let entries = try await repo.status()
        XCTAssertTrue(entries.contains { $0.path == "tracked" && $0.isStaged && !$0.isUnstaged })
    }
    func testDiscardWorkspaceValidatesAllPathsBeforeMutationAndRejectsSymlinksAndIgnoredFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        let repo = GitRepository(url: root)
        try Data("keep".utf8).write(to: root.appendingPathComponent("new"))
        try Data("ignored\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try Data("keep ignored".utf8).write(to: root.appendingPathComponent("ignored"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("new"))
        for invalid in ["link", "ignored", "missing", "../outside", ".git/config"] {
            do { try await repo.discardWorkspace(paths: ["new", invalid]); XCTFail("Unsafe target must be rejected: \(invalid)") } catch { }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new"), encoding: .utf8), "keep")
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("ignored"), encoding: .utf8), "keep ignored")
    }
    func testPermanentDeletionRejectsProtectedAndSymbolicPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = GitRepository(url: dir)
        try Data("keep".utf8).write(to: dir.appendingPathComponent("keep"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: dir.appendingPathComponent("keep"))
        for path in ["", ".", "../keep", ".git", "link"] {
            do { try await repo.permanentlyDeleteWorkspaceFile(path: path); XCTFail("Must reject protected path: \(path)") } catch { }
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("keep"), encoding: .utf8), "keep")
        try await repo.permanentlyDeleteWorkspaceFile(path: "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("keep").path))
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
