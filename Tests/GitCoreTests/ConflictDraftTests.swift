import XCTest
@testable import GitCore

final class ConflictDraftTests: XCTestCase {
    func testGeneratedDiff3ChoicesPreserveSurroundingText() async throws {
        let preview = try await MergePreview.create(base: "unchanged\nbase\ntail\n", ours: "unchanged\nours\ntail\n", theirs: "unchanged\ntheirs\ntail\n")
        XCTAssertTrue(preview.hasConflicts)
        XCTAssertEqual(ConflictDraft.blocks(in: preview.text).count, 1)
        XCTAssertEqual(ConflictDraft.accepting(.ours, block: 0, in: preview.text), "unchanged\nours\ntail\n")
        XCTAssertEqual(ConflictDraft.accepting(.theirs, block: 0, in: preview.text), "unchanged\ntheirs\ntail\n")
        XCTAssertEqual(ConflictDraft.accepting(.base, block: 0, in: preview.text), "unchanged\nbase\ntail\n")
        XCTAssertEqual(ConflictDraft.accepting(.oursThenTheirs, block: 0, in: preview.text), "unchanged\nours\ntheirs\ntail\n")
        XCTAssertEqual(ConflictDraft.accepting(.theirsThenOurs, block: 0, in: preview.text), "unchanged\ntheirs\nours\ntail\n")
    }
    func testChoosingDraftDoesNotResolveOrStageRealMerge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("conflict.txt")
        for arguments in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"]] {
            _ = try await GitProcess.run(at: directory, arguments: arguments)
        }
        let repository = GitRepository(url: directory)
        try Data("base\n".utf8).write(to: file)
        try await repository.stage(paths: ["conflict.txt"])
        try await repository.commit(message: "Base")
        _ = try await GitProcess.run(at: directory, arguments: ["checkout", "-b", "other"])
        try Data("theirs\n".utf8).write(to: file)
        try await repository.stage(paths: ["conflict.txt"])
        try await repository.commit(message: "Theirs")
        _ = try await GitProcess.run(at: directory, arguments: ["checkout", "main"])
        try Data("ours\n".utf8).write(to: file)
        try await repository.stage(paths: ["conflict.txt"])
        try await repository.commit(message: "Ours")
        _ = try await GitProcess.run(at: directory, arguments: ["merge", "other"], allowedCodes: [1])
        let snapshot = try await repository.fileComparison(path: "conflict.txt")
        XCTAssertTrue(snapshot.isConflict)
        let indexBefore = try await GitProcess.run(at: directory, arguments: ["ls-files", "--unmerged"])
        let diskBefore = try Data(contentsOf: file)
        let draft = try XCTUnwrap(ConflictDraft.accepting(.ours, block: 0, in: try XCTUnwrap(snapshot.worktree.text)))
        XCTAssertEqual(draft, snapshot.ours?.text)
        XCTAssertEqual(try Data(contentsOf: file), diskBefore)
        let indexAfter = try await GitProcess.run(at: directory, arguments: ["ls-files", "--unmerged"])
        XCTAssertEqual(indexAfter.text, indexBefore.text)
        var expected = snapshot.worktree
        for marker in ["==========\r\n", "=======\r\n", "<<<<<<<<<< unfinished\r\n"] {
            expected = try await repository.saveWorktree(path: "conflict.txt", text: marker, expected: expected)
            do {
                try await repository.markResolved(path: "conflict.txt", expected: expected)
                XCTFail("Must reject wide, CRLF, and incomplete conflict markers")
            } catch { }
            let unchangedIndex = try await GitProcess.run(at: directory, arguments: ["ls-files", "--unmerged"])
            XCTAssertEqual(unchangedIndex.text, indexBefore.text)
        }
        let saved = try await repository.saveWorktree(path: "conflict.txt", text: draft, expected: expected)
        let stillUnmerged = try await repository.fileComparison(path: "conflict.txt")
        XCTAssertTrue(stillUnmerged.isConflict)
        try await repository.markResolved(path: "conflict.txt", expected: saved)
        let resolved = try await repository.fileComparison(path: "conflict.txt")
        XCTAssertFalse(resolved.isConflict)
        XCTAssertEqual(resolved.index.text, "ours\n")
    }
    func testMultipleBlocksUnicodeCRLFAndMissingBase() {
        let block = "<<<<<<< ours\r\n甲😀\r\n=======\r\n乙\r\n>>>>>>> theirs\r\n"
        let text = "前😀\r\n" + block + "manual edit\r\n" + block + "tail"
        let blocks = ConflictDraft.blocks(in: text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].startLine, 2)
        XCTAssertEqual(blocks[0].endLine, 6)
        XCTAssertEqual(ConflictDraft.accepting(.theirs, block: 1, in: text), "前😀\r\n" + block + "manual edit\r\n乙\r\ntail")
        XCTAssertNil(ConflictDraft.accepting(.base, block: 0, in: text))
        XCTAssertNil(ConflictDraft.accepting(.ours, block: 2, in: text))
    }
    func testIncompleteNestedAndVariableWidthMarkers() {
        XCTAssertTrue(ConflictDraft.blocks(in: "<<<<<<< ours\na\n=======\nb\n").isEmpty)
        XCTAssertTrue(ConflictDraft.blocks(in: "<<<<<<< ours\n<<<<<<< nested\na\n=======\nb\n>>>>>>> theirs\n").isEmpty)
        let text = "<<<<<<<<<< ours\n\n==========\nb\n>>>>>>>>>> theirs"
        XCTAssertEqual(ConflictDraft.accepting(.ours, block: 0, in: text), "\n")
        XCTAssertEqual(ConflictDraft.accepting(.theirs, block: 0, in: text), "b\n")
        XCTAssertTrue(ConflictDraft.blocks(in: "<<<<<<<not a marker\na\n=======\nb\n>>>>>>> theirs").isEmpty)
    }
    func testUTF16CursorAndReplacementKeepOtherBlocks() throws {
        let first = "<<<<<<< ours\n甲😀\n=======\n乙\n>>>>>>> theirs\n"
        let second = "<<<<<<< ours\nA\n=======\nB\n>>>>>>> theirs"
        let text = "前😀\n" + first + "between\n" + second
        let blocks = ConflictDraft.blocks(in: text)
        XCTAssertEqual(ConflictDraft.blockIndex(atUTF16Offset: blocks[0].range.location, in: text), 0)
        XCTAssertNil(ConflictDraft.blockIndex(atUTF16Offset: NSMaxRange(blocks[0].range), in: text))
        XCTAssertEqual(ConflictDraft.blockIndex(atUTF16Offset: text.utf16.count, in: text), 1)
        XCTAssertNil(ConflictDraft.blockIndex(atUTF16Offset: -1, in: text))
        XCTAssertNil(ConflictDraft.blockIndex(atUTF16Offset: text.utf16.count + 1, in: text))
        let edit = try XCTUnwrap(ConflictDraft.replacement(accepting: .theirsThenOurs, block: 1, in: text))
        XCTAssertEqual(edit.range, blocks[1].range)
        XCTAssertEqual(edit.text, "B\nA\n")
        XCTAssertEqual((text as NSString).replacingCharacters(in: edit.range, with: edit.text), "前😀\n" + first + "between\nB\nA\n")
    }
    func testEmptySidesAndMarkerLikeContentWithWideMarkers() {
        let empty = "<<<<<<< ours\r\n=======\r\n>>>>>>> theirs"
        XCTAssertEqual(ConflictDraft.accepting(.oursThenTheirs, block: 0, in: empty), "")
        let text = "<<<<<<<<<< ours\n<<<<<<< content\n======= content\n||||||| content\n==========\n>>>>>>> content\n>>>>>>>>>> theirs\n"
        XCTAssertEqual(ConflictDraft.accepting(.ours, block: 0, in: text), "<<<<<<< content\n======= content\n||||||| content\n")
        XCTAssertEqual(ConflictDraft.accepting(.theirs, block: 0, in: text), ">>>>>>> content\n")
    }
    func testDamagedDiff3RejectsAllChoices() {
        for text in [
            "<<<<<<< ours\na\n||||||| base\nb\n||||||| duplicate\nc\n=======\nd\n>>>>>>> theirs\n",
            "<<<<<<< ours\na\n=======\nb\n||||||| misplaced\nc\n>>>>>>> theirs\n",
            "<<<<<<< ours\na\n=======\nb\n=======\nc\n>>>>>>> theirs\n",
            "<<<<<<< ours\na\n=======\nb\n>>>>>>> theirs\n<<<<<<< incomplete\nc"
        ] {
            XCTAssertTrue(ConflictDraft.blocks(in: text).isEmpty)
            XCTAssertNil(ConflictDraft.replacement(accepting: .ours, block: 0, in: text))
        }
    }
    func testZDiff3PreservesSharedContextOutsideConflict() {
        let text = "shared start\n<<<<<<< ours\nours\n||||||| base\nshared start\nbase\nshared end\n=======\ntheirs\n>>>>>>> theirs\nshared end\n"
        XCTAssertEqual(ConflictDraft.accepting(.oursThenTheirs, block: 0, in: text), "shared start\nours\ntheirs\nshared end\n")
        XCTAssertEqual(ConflictDraft.blocks(in: text).first?.base, "shared start\nbase\nshared end\n")
    }

    func testConservativeMarkerDetectionFlagsMalformedAndWideCRLFMarkers() {
        for text in ["<<<<<<< unfinished", "|||||||||| base\r\n", "==========\r\n", ">>>>>>>>>broken"] {
            XCTAssertTrue(ConflictDraft.hasConflictMarkers(in: text))
            XCTAssertTrue(ConflictDraft.blocks(in: text).isEmpty)
        }
        XCTAssertFalse(ConflictDraft.hasConflictMarkers(in: "normal < content\n===\n======= not a separator\n"))
    }

}
