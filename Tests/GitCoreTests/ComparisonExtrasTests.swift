import XCTest
@testable import GitCore

final class ComparisonExtrasTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"], ["config", "core.autocrlf", "false"]] { _ = try await GitProcess.run(at: dir, arguments: args) }
        return (dir, GitRepository(url: dir))
    }
    func testUTF16BothEndiansSavePreservesBOMCRLFAndIndex() async throws {
        let (dir, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        for encoding in [ComparisonEncoding.utf16LE, .utf16BE] {
            let path = encoding.rawValue, url = dir.appendingPathComponent(path)
            let format = ComparisonTextFormat(encoding: encoding, lineEnding: .crlf)
            let initial = try ComparisonTextDecoder.encode("你好\noriginal\n", format: format)
            try initial.write(to: url); try await repo.stage(paths: [path])
            let snapshot = try await repo.fileComparison(path: path)
            XCTAssertTrue(snapshot.worktree.isEditable)
            XCTAssertEqual(snapshot.worktree.text, "你好\noriginal\n")
            _ = try await repo.saveWorktree(path: path, text: "改动\nnext\n", expected: snapshot.worktree)
            XCTAssertEqual(try Data(contentsOf: url), try ComparisonTextDecoder.encode("改动\nnext\n", format: format))
            let after = try await repo.fileComparison(path: path)
            XCTAssertEqual(after.index.data, initial)
            try await repo.saveIndex(path: path, text: "索引\n", expected: after.index)
            let indexed = try await repo.fileComparison(path: path)
            XCTAssertEqual(indexed.index.data, try ComparisonTextDecoder.encode("索引\n", format: format))
        }
    }
    func testExplicitConversionMixedEndingsLatin1ContinuedEditingAndExternalChange() async throws {
        let (dir, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("text")
        try Data("one\r\ntwo\n".utf8).write(to: file)
        let mixed = try await repo.fileComparison(path: "text")
        XCTAssertFalse(mixed.worktree.isEditable)
        let converted = try await repo.convertWorktree(path: "text", text: mixed.worktree.text!, format: ComparisonTextFormat(encoding: .utf16BE, lineEnding: .crlf), expected: mixed.worktree)
        XCTAssertTrue(converted.isEditable)
        XCTAssertEqual(ComparisonTextDecoder.format(of: converted.data!).encoding, .utf16BE)
        let latin = try await repo.convertWorktree(path: "text", text: "café\n", format: ComparisonTextFormat(encoding: .latin1, lineEnding: .crlf), expected: converted)
        XCTAssertTrue(latin.isEditable)
        XCTAssertEqual(latin.text, "café\n")
        let editedLatin = try await repo.saveWorktree(path: "text", text: "déjà\n", expected: latin, format: ComparisonTextFormat(encoding: .latin1, lineEnding: .crlf))
        XCTAssertEqual(try Data(contentsOf: file), "déjà\r\n".data(using: .isoLatin1))
        do { _ = try await repo.saveWorktree(path: "text", text: "😀", expected: editedLatin, format: ComparisonTextFormat(encoding: .latin1, lineEnding: .crlf)); XCTFail("Must refuse unrepresentable save") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), "déjà\r\n".data(using: .isoLatin1), "Lossless encoding refusal must preserve original bytes")
        try Data("external".utf8).write(to: file)
        do { _ = try await repo.convertWorktree(path: "text", text: "overwrite", format: ComparisonTextFormat(encoding: .utf8, lineEnding: .lf), expected: latin); XCTFail("Expected external change rejection") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external")
        XCTAssertThrowsError(try ComparisonTextDecoder.encode("😀", format: ComparisonTextFormat(encoding: .latin1, lineEnding: .lf)))
        let binary = ComparisonTextDecoder.decode(Data([0xff, 0xfe, 0, 0, 65, 0]))
        XCTAssertTrue(binary.isBinary); XCTAssertNil(binary.text)
        XCTAssertNil(ComparisonTextDecoder.decode(Data([0xff, 0xfe, 0x61])).text, "An incomplete UTF-16 code unit must not be silently truncated")
        XCTAssertNil(ComparisonTextDecoder.decode(Data([0xff, 0xfe, 0, 0xd8])).text, "An unpaired surrogate must remain read-only")
        try Data("CR\rLF\n".utf8).write(to: file)
        let mixedCR = try await repo.fileComparison(path: "text")
        XCTAssertFalse(mixedCR.worktree.isEditable, "Mixed CR/LF requires an explicit normalization")
    }
    func testStagedRenamePartialUnstageKeepsRenameIdentity() async throws {
        let (dir, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = (1...30).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try Data(original.utf8).write(to: dir.appendingPathComponent("old name"))
        try await repo.stage(paths: ["old name"]); try await repo.commit(message: "base")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("old name"), to: dir.appendingPathComponent("new name"))
        let edited = original.replacingOccurrences(of: "line2\n", with: "changed2\n").replacingOccurrences(of: "line25\n", with: "changed25\n")
        try Data(edited.utf8).write(to: dir.appendingPathComponent("new name"))
        try await repo.stage(paths: ["old name", "new name"])
        let partial = try await repo.partialStaging(path: "new name", unstage: true)
        XCTAssertNil(partial.unavailableReason)
        let chosen = Set(partial.hunks.flatMap(\.lines).filter { $0.text == "-changed2" || $0.text == "+line2" }.map(\.id))
        XCTAssertEqual(chosen.count, 2)
        try await repo.applyPartialStaging(partial, selectedLines: chosen)
        let after = try await repo.fileComparison(path: "new name")
        XCTAssertEqual(after.index.text, edited.replacingOccurrences(of: "changed2\n", with: "line2\n"))
        let entries = try await GitProcess.run(at: dir, arguments: ["ls-files", "-z"])
        XCTAssertEqual(entries.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }, ["new name"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("new name"), encoding: .utf8), edited)
    }
    func testMissingOriginalRenameIdentityThenPartialStage() async throws {
        let (dir, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = (1...20).map { "line\($0)" }.joined(separator: "\n") + "\n"
        try Data(original.utf8).write(to: dir.appendingPathComponent("old"))
        try await repo.stage(paths: ["old"]); try await repo.commit(message: "base")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("old"), to: dir.appendingPathComponent("new"))
        let edited = original.replacingOccurrences(of: "line2\n", with: "chosen\n").replacingOccurrences(of: "line18\n", with: "other\n")
        try Data(edited.utf8).write(to: dir.appendingPathComponent("new"))
        let snapshot = try await repo.fileComparison(path: "new")
        try await repo.prepareRenameIdentity(path: "new", originalPath: "old", expected: snapshot)
        let identity = try await repo.fileComparison(path: "new")
        XCTAssertEqual(identity.index.text, original)
        XCTAssertEqual(identity.worktree.text, edited)
        let partial = try await repo.partialStaging(path: "new", unstage: false)
        let chosen = Set(partial.hunks.flatMap(\.lines).filter { $0.text == "-line2" || $0.text == "+chosen" }.map(\.id))
        try await repo.applyPartialStaging(partial, selectedLines: chosen)
        let after = try await repo.fileComparison(path: "new")
        XCTAssertEqual(after.index.text, original.replacingOccurrences(of: "line2\n", with: "chosen\n"))
        XCTAssertEqual(after.worktree.text, edited)
    }
    func testRestoreDeletedExecutableDetectsHEADChangeAndSymlink() async throws {
        let (dir, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("script")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try await repo.stage(paths: ["script"]); try await repo.commit(message: "base")
        try FileManager.default.removeItem(at: file)
        let deleted = try await repo.fileComparison(path: "script")
        XCTAssertEqual(deleted.head.gitMode, "100755")
        try await repo.restoreComparedVersion(path: "script", source: deleted.head, expected: deleted, resolve: false)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o111, 0o111)
        let current = try await repo.fileComparison(path: "script")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dir.appendingPathComponent("outside"))
        do { try await repo.restoreComparedVersion(path: "script", source: current.head, expected: current, resolve: false); XCTFail("Must reject symlink substitution") } catch {}
        try FileManager.default.removeItem(at: file)
        let snapshot = try await repo.fileComparison(path: "script")
        _ = try await GitProcess.run(at: dir, arguments: ["update-ref", "-d", "HEAD"])
        do { try await repo.restoreComparedVersion(path: "script", source: snapshot.head, expected: snapshot, resolve: false); XCTFail("HEAD change must invalidate the chosen source") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testModifyDeleteConflictCanRestoreOrDeleteResolution() async throws {
        for keep in [true, false] {
            let (dir, repo) = try await fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("file")
            try Data("base\n".utf8).write(to: file); try await repo.stage(paths: ["file"]); try await repo.commit(message: "base")
            _ = try await GitProcess.run(at: dir, arguments: ["checkout", "-b", "other"])
            try Data("theirs\n".utf8).write(to: file); try await repo.stage(paths: ["file"]); try await repo.commit(message: "edit")
            _ = try await GitProcess.run(at: dir, arguments: ["checkout", "main"])
            try FileManager.default.removeItem(at: file); try await repo.stage(paths: ["file"]); try await repo.commit(message: "delete")
            _ = try await GitProcess.run(at: dir, arguments: ["merge", "other"], allowedCodes: [0, 1])
            let snapshot = try await repo.fileComparison(path: "file")
            XCTAssertTrue(snapshot.isConflict)
            if keep { try await repo.restoreComparedVersion(path: "file", source: snapshot.theirs!, expected: snapshot, resolve: true) }
            else { try await repo.deleteComparedFile(path: "file", expected: snapshot, resolve: true) }
            let stages = try await GitProcess.run(at: dir, arguments: ["ls-files", "-u"])
            XCTAssertTrue(stages.data.isEmpty)
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), keep)
        }
    }
    func testArgumentTemplateNeverSplitsOrExecutesShellAndRejectsUnknownSlots() throws {
        let files = ["left": "/tmp/a space\n$(echo bad)", "right": "/tmp/b", "base": "/tmp/base", "result": "/tmp/result"]
        let template = try ExternalDiffArguments.parse("[\"--left={left}\",\"{base}\",\"{right}\",\"{result}\",\"$(touch /tmp/nope)\"]")
        let expanded = try ExternalDiffArguments.expand(template, files: files)
        XCTAssertEqual(expanded.count, 5)
        XCTAssertEqual(expanded[0], "--left=" + files["left"]!)
        XCTAssertEqual(expanded[4], "$(touch /tmp/nope)")
        XCTAssertThrowsError(try ExternalDiffArguments.expand(["{missing}"], files: files))
        XCTAssertThrowsError(try ExternalDiffArguments.parse("not an array"))
    }
}
