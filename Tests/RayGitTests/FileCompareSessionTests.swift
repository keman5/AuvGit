import XCTest
@testable import GitCore
@testable import RayGit

@MainActor
final class FileCompareSessionTests: XCTestCase {
    private let path = "conflict.txt"

    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = GitRepository(url: root)
        for args in [
            ["init", "-b", "main"], ["config", "user.name", "Session Fixture"],
            ["config", "user.email", "session@example.invalid"], ["config", "commit.gpgsign", "false"],
            ["config", "core.hooksPath", root.appendingPathComponent("disabled-hooks").path],
            ["config", "core.autocrlf", "false"], ["config", "rerere.enabled", "false"],
            ["config", "merge.conflictStyle", "diff3"]
        ] { _ = try await GitProcess.run(at: root, arguments: args) }
        func write(_ choice: String) throws {
            let text = (1...3).map { section in
                "section \(section)\n\(choice) \(section)\n" + (0..<10).map { "unchanged \(section).\($0)\n" }.joined()
            }.joined()
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        try write("base")
        try await repository.stage(paths: [path]); try await repository.commit(message: "Base")
        _ = try await GitProcess.run(at: root, arguments: ["switch", "-c", "incoming"])
        try write("theirs")
        try await repository.stage(paths: [path]); try await repository.commit(message: "Incoming")
        _ = try await GitProcess.run(at: root, arguments: ["switch", "main"])
        try write("ours")
        try await repository.stage(paths: [path]); try await repository.commit(message: "Local")
        _ = try await GitProcess.run(at: root, arguments: ["merge", "incoming"], allowedCodes: [1])
        return (root, repository)
    }

    private func retainedSources(_ session: FileCompareSession, _ original: FileComparisonSnapshot, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(session.snapshot?.isConflict == true, file: file, line: line)
        XCTAssertEqual(session.snapshot?.head.data, original.head.data, file: file, line: line)
        XCTAssertEqual(session.snapshot?.index.data, original.index.data, file: file, line: line)
        XCTAssertEqual(session.snapshot?.worktree.data, original.worktree.data, file: file, line: line)
        XCTAssertEqual(session.snapshot?.base?.data, original.base?.data, file: file, line: line)
        XCTAssertEqual(session.snapshot?.ours?.data, original.ours?.data, file: file, line: line)
        XCTAssertEqual(session.snapshot?.theirs?.data, original.theirs?.data, file: file, line: line)
    }

    func testSaveAndResolveKeepOriginalSourcesAndAllowUndoDraftThenRepeatSave() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repository, path: path)
        await session.reload()
        let original = try XCTUnwrap(session.snapshot)
        let originalDraft = session.draft
        XCTAssertEqual(ConflictDraft.blocks(in: originalDraft).count, 3)
        let resolved = try XCTUnwrap(original.ours?.text)
        session.draft = resolved
        let saved = await session.save()
        XCTAssertTrue(saved, session.error ?? "save failed")
        XCTAssertFalse(session.isDirty)
        retainedSources(session, original)
        await session.stage(resolve: true)
        XCTAssertNil(session.error)
        XCTAssertFalse(session.isDirty)
        retainedSources(session, original)
        let staged = try await repository.fileComparison(path: path)
        XCTAssertFalse(staged.isConflict)
        XCTAssertEqual(staged.index.text, resolved)
        XCTAssertEqual(session.savedWorktree?.text, resolved)

        // This is the text restored by native editor undo after resolution.
        session.draft = originalDraft
        XCTAssertTrue(session.isDirty)
        let savedUndo = await session.save()
        XCTAssertTrue(savedUndo, session.error ?? "undo draft save failed")
        XCTAssertFalse(session.isDirty)
        retainedSources(session, original)
        await session.stage(resolve: true)
        XCTAssertNotNil(session.error, "Restored conflict markers must block staging")
        let rejected = try await repository.fileComparison(path: path)
        XCTAssertEqual(rejected.index.text, resolved)
        XCTAssertEqual(rejected.worktree.text, originalDraft)

        // A second resolution must compare against the current stage-0 index,
        // while the immutable original stages remain visible in this session.
        let secondResolution = try XCTUnwrap(original.theirs?.text) + "manual edit after resolution\n"
        session.draft = secondResolution
        await session.stage(resolve: true)
        XCTAssertNil(session.error)
        XCTAssertFalse(session.isDirty)
        retainedSources(session, original)
        let second = try await repository.fileComparison(path: path)
        XCTAssertEqual(second.index.text, secondResolution)
        XCTAssertEqual(second.worktree.text, secondResolution)
        XCTAssertEqual(session.savedWorktree?.text, secondResolution)
    }

    func testExternalDiskWriteAfterResolutionBlocksSaveAndPreservesDraft() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repository, path: path)
        await session.reload()
        session.draft = try XCTUnwrap(session.snapshot?.ours?.text)
        await session.stage(resolve: true)
        XCTAssertNil(session.error)
        try Data("external disk change\n".utf8).write(to: root.appendingPathComponent(path))
        let draft = "new editor change\n"
        session.draft = draft
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(session.isDirty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8), "external disk change\n")
    }

    func testExternalIndexWriteAfterResolutionBlocksStageAndPreservesBothSides() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repository, path: path)
        await session.reload()
        session.draft = try XCTUnwrap(session.snapshot?.ours?.text)
        await session.stage(resolve: true)
        XCTAssertNil(session.error)
        let saved = try XCTUnwrap(session.savedWorktree?.data)
        let file = root.appendingPathComponent(path)
        try Data("external staged content\n".utf8).write(to: file)
        try await repository.stage(paths: [path])
        try saved.write(to: file)
        await session.stage(resolve: true)
        XCTAssertNotNil(session.error, "Retained original sources must not disable the live index guard")
        let current = try await repository.fileComparison(path: path)
        XCTAssertEqual(current.index.text, "external staged content\n")
        XCTAssertEqual(current.worktree.data, saved)
        XCTAssertEqual(session.savedWorktree?.data, saved)
        XCTAssertFalse(session.isDirty)
    }

    func testAlreadyChangedIndexRejectsSaveBeforeChangingDiskOrCleanBaseline() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = FileCompareSession(repository: repository, path: path)
        await session.reload()
        session.draft = try XCTUnwrap(session.snapshot?.ours?.text)
        await session.stage(resolve: true)
        XCTAssertNil(session.error)
        let clean = try XCTUnwrap(session.savedWorktree?.data)
        let file = root.appendingPathComponent(path)
        try Data("external staged content\n".utf8).write(to: file)
        try await repository.stage(paths: [path])
        try clean.write(to: file)
        let draft = "new editor content\n"
        session.draft = draft
        let saved = await session.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(try Data(contentsOf: file), clean, "A known stale index must be rejected before writing the draft")
        XCTAssertEqual(session.savedWorktree?.data, clean)
        XCTAssertEqual(session.draft, draft)
        XCTAssertTrue(session.isDirty)
        let current = try await repository.fileComparison(path: path)
        XCTAssertEqual(current.index.text, "external staged content\n")
    }

}
