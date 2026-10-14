import Foundation
import Testing
@testable import GitCore

// Match the GUI's single-operation flow; parallel fixtures can exhaust the blocking pipe reader pool.
@Suite(.serialized)
struct ConflictResolutionGateTests {
    @Test(arguments: [ConflictDraft.Side.ours, .theirs, .oursThenTheirs])
    func deletedSideCanBeChosenAndRecreated(side: ConflictDraft.Side) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        let file = root.appendingPathComponent("file")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        _ = try await repo.workflowRead(["switch", "-c", "other"])
        try "other\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Other")
        _ = try await repo.workflowRead(["switch", "main"])
        _ = try await repo.workflowRead(["rm", "--", "file"])
        try await repo.commit(message: "Delete")
        _ = try await GitProcess.run(at: root, arguments: ["merge", "other"], allowedCodes: [1])
        try await repo.resolveConflict(path: "file", side: side)
        #expect(!((try await repo.status()).contains(where: \.isConflict)))
        #expect(FileManager.default.fileExists(atPath: file.path) == (side != .ours))
        try await repo.recreateConflict(path: "file")
        #expect((try await repo.status()).contains(where: \.isConflict))
        await #expect(throws: GitError.self) { try await repo.commit(message: "Still unresolved") }
    }

    @Test(arguments: [ConflictDraft.Side.ours, .theirs, .oursThenTheirs, .theirsThenOurs])
    func explicitResolutionIsRequiredBeforeStagingAndCommit(side: ConflictDraft.Side) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(url: root)
        for args in [["init", "-b", "main"], ["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "merge.conflictStyle", "diff3"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        let file = root.appendingPathComponent("conflict.txt"), normal = root.appendingPathComponent("normal.txt")
        try Data("prefix\nbase\ntail\n".utf8).write(to: file)
        try Data("normal base\n".utf8).write(to: normal)
        try await repo.stage(paths: ["conflict.txt", "normal.txt"]); try await repo.commit(message: "Base")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "-b", "other"])
        try Data("prefix\ntheirs\ntail\n".utf8).write(to: file)
        try await repo.stage(paths: ["conflict.txt"]); try await repo.commit(message: "Theirs")
        _ = try await GitProcess.run(at: root, arguments: ["checkout", "main"])
        try Data("prefix\nours\ntail\n".utf8).write(to: file)
        try await repo.stage(paths: ["conflict.txt"]); try await repo.commit(message: "Ours")
        _ = try await GitProcess.run(at: root, arguments: ["merge", "other"], allowedCodes: [1])
        try Data("normal staged\n".utf8).write(to: normal)
        try await repo.stage(paths: ["normal.txt"])
        try Data("normal unstaged\n".utf8).write(to: normal)
        let before = try await GitProcess.run(at: root, arguments: ["ls-files", "--stage"])
        await #expect(throws: GitError.self) { try await repo.stage(paths: ["conflict.txt"]) }
        await #expect(throws: GitError.self) { try await repo.stage(paths: ["normal.txt", "conflict.txt"]) }
        await #expect(throws: GitError.self) { try await repo.commit(message: "Must not commit") }
        let unchanged = try await GitProcess.run(at: root, arguments: ["ls-files", "--stage"])
        #expect(unchanged.data == before.data)
        let snapshot = try await repo.fileComparison(path: "conflict.txt")
        let source = try #require(snapshot.worktree.text)
        let draft = try #require(ConflictDraft.accepting(side, block: 0, in: source))
        #expect(!ConflictDraft.hasConflictMarkers(in: draft))
        let saved = try await repo.saveWorktree(path: "conflict.txt", text: draft, expected: snapshot.worktree)
        await #expect(throws: GitError.self) { try await repo.stage(paths: ["conflict.txt"]) }
        try await repo.markResolved(path: "conflict.txt", expected: saved)
        let resolved = try await repo.fileComparison(path: "conflict.txt")
        #expect(!resolved.isConflict)
        #expect(resolved.index.text == draft)
        let expected: String
        switch side {
        case .ours: expected = "prefix\nours\ntail\n"
        case .theirs: expected = "prefix\ntheirs\ntail\n"
        case .oursThenTheirs: expected = "prefix\nours\ntheirs\ntail\n"
        case .theirsThenOurs: expected = "prefix\ntheirs\nours\ntail\n"
        default: throw GitError("Unexpected test choice")
        }
        #expect(draft == expected)
        #expect(try await repo.recreatableConflictPaths().contains("conflict.txt"))
        try await repo.recreateConflict(path: "conflict.txt")
        let recreated = try await repo.fileComparison(path: "conflict.txt")
        #expect(recreated.isConflict)
        #expect(recreated.ours?.data == snapshot.ours?.data)
        #expect(recreated.theirs?.data == snapshot.theirs?.data)
        await #expect(throws: GitError.self) { try await repo.stage(paths: ["conflict.txt"]) }
        try await repo.resolveConflict(path: "conflict.txt", side: side)
        let directlyResolved = try await repo.fileComparison(path: "conflict.txt")
        #expect(!directlyResolved.isConflict)
        #expect(directlyResolved.index.text == expected)
        try await repo.commit(message: "Resolved merge")
        let committed = try await GitProcess.run(at: root, arguments: ["show", "HEAD:conflict.txt"])
        let preserved = try await GitProcess.run(at: root, arguments: ["show", "HEAD:normal.txt"])
        #expect(committed.text == expected)
        #expect(preserved.text == "normal staged\n")
        #expect(try String(contentsOf: normal, encoding: .utf8) == "normal unstaged\n")
    }
}
