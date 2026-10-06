import XCTest
@testable import GitCore

final class StreamingComparisonTests: XCTestCase {
    private func fixture(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return file
    }
    func testSparseLineNavigationUsesExactUTF8OffsetsAndClamps() async throws {
        let prefix = "😀第一行\n" + String(repeating: "line\n", count: 9_000)
        let text = prefix + String(repeating: "é", count: 80_000) + "\nlast\n"
        let file = try fixture(Data(text.utf8)); defer { try? FileManager.default.removeItem(at: file) }
        let reader = try StreamingTextFile(url: file)
        let count = try await reader.lineCount()
        XCTAssertEqual(count, 9_004)
        let late = try await reader.cursor(atLine: 9_002)
        XCTAssertEqual(late.offset, UInt64(prefix.utf8.count))
        let page = try await reader.page(at: late, maximumBytes: 20)
        XCTAssertTrue(page.text.hasPrefix("éé")); XCTAssertEqual(page.cursor.line, 9_002)
        let start = try await reader.cursor(atLine: -1)
        XCTAssertEqual(start, .start)
        let end = try await reader.cursor(atLine: Int.max)
        XCTAssertEqual(end.line, count); XCTAssertEqual(end.offset, UInt64(text.utf8.count))
        try Data("modified".utf8).write(to: file)
        do { _ = try await reader.lineCount(); XCTFail("Cached index must validate the snapshot") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }
    func testLineIndexCancellationAndEmptyFile() async throws {
        let file = try fixture(Data()); defer { try? FileManager.default.removeItem(at: file) }
        let reader = try StreamingTextFile(url: file)
        let count = try await reader.lineCount(); XCTAssertEqual(count, 1)
        let cursor = try await reader.cursor(atLine: 10); XCTAssertEqual(cursor, .start)
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.cursor(atLine: 1)
        }
        do { _ = try await canceled.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testUTF8BoundaryAndLongLineReconstructExactText() async throws {
        let original = "😀你好abcdefghij" + String(repeating: "é😀", count: 500) + "\nlast\n"
        let file = try fixture(Data(original.utf8)); defer { try? FileManager.default.removeItem(at: file) }
        let reader = try StreamingTextFile(url: file)
        var cursor = StreamingCursor.start, reconstructed = "", count = 0
        while true {
            let page = try await reader.page(at: cursor, maximumBytes: 7)
            XCTAssertLessThanOrEqual(page.text.utf8.count, 7)
            reconstructed += page.text; count += 1
            guard let next = page.next else { break }
            XCTAssertGreaterThan(next.offset, cursor.offset)
            cursor = next
        }
        XCTAssertGreaterThan(count, 100)
        XCTAssertEqual(reconstructed, original)
    }
    func testLinePaginationBOMAndEmptyFile() async throws {
        let file = try fixture(Data([0xef, 0xbb, 0xbf]) + Data("one\ntwo\nthree".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        let reader = try StreamingTextFile(url: file)
        let first = try await reader.page(maximumLines: 2)
        XCTAssertEqual(first.text, "one\ntwo\n")
        let cursor = try XCTUnwrap(first.next)
        XCTAssertEqual(cursor.line, 3)
        let second = try await reader.page(at: cursor)
        XCTAssertEqual(second.text, "three"); XCTAssertNil(second.next)
        let empty = try fixture(Data()); defer { try? FileManager.default.removeItem(at: empty) }
        let emptyReader = try StreamingTextFile(url: empty)
        let page = try await emptyReader.page()
        XCTAssertEqual(page.text, ""); XCTAssertNil(page.next)
    }
    func testChangedFileMustReload() async throws {
        let file = try fixture(Data("original\n".utf8)); defer { try? FileManager.default.removeItem(at: file) }
        let reader = try StreamingTextFile(url: file)
        try Data("replacement text\n".utf8).write(to: file, options: .atomic)
        do { _ = try await reader.page(); XCTFail("Expected stale snapshot rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }
    func testAbove32MBIsReadInBoundedPages() async throws {
        let file = try fixture(Data()); defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        let chunk = Data(repeating: 120, count: 1024 * 1024)
        for _ in 0..<33 { try handle.write(contentsOf: chunk) }
        try handle.close()
        let reader = try StreamingTextFile(url: file)
        let page = try await reader.page()
        XCTAssertEqual(page.totalBytes, 33 * 1024 * 1024)
        XCTAssertEqual(page.text.utf8.count, 128 * 1024)
        XCTAssertEqual(page.next?.offset, 128 * 1024)
    }
    func testUnknownEncodingAndSymlinkAreRejected() async throws {
        let file = try fixture(Data([0xff, 0xfe, 0x61, 0])); defer { try? FileManager.default.removeItem(at: file) }
        let reader = try StreamingTextFile(url: file)
        do { _ = try await reader.page(); XCTFail("UTF-16 must require another viewer") } catch {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: file)
        let repository = GitRepository(url: directory)
        do { _ = try await repository.streamingWorktree(path: "link"); XCTFail("Must reject links") } catch {}
    }
    func testImmutableHistoricalBlobAbove32MBAndCancelledExportCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: directory, arguments: args) }
        let file = directory.appendingPathComponent("large.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        let chunk = Data(repeating: 120, count: 1024 * 1024)
        for _ in 0..<33 { try writer.write(contentsOf: chunk) }
        try writer.close()
        for args in [["add", "large.txt"], ["commit", "-m", "large history"]] { _ = try await GitProcess.run(at: directory, arguments: args) }
        try Data("small worktree\n".utf8).write(to: file)
        let repository = GitRepository(url: directory)
        let available = try await repository.availableStreamingRevisions(path: "large.txt")
        XCTAssertTrue(available.contains(.head)); XCTAssertTrue(available.contains(.index))
        let headReader = try await repository.streamingContent(path: "large.txt", revision: .head)
        let page = try await headReader.page()
        XCTAssertEqual(page.totalBytes, 33 * 1024 * 1024)
        XCTAssertEqual(page.text.utf8.count, 128 * 1024)
        let indexReader = try await repository.streamingContent(path: "large.txt", revision: .index)
        let indexPage = try await indexReader.page(maximumBytes: 16)
        XCTAssertEqual(indexPage.text, String(repeating: "x", count: 16))
        // Updating the live index after export cannot alter its immutable streamed snapshot.
        _ = try await GitProcess.run(at: directory, arguments: ["add", "large.txt"])
        let stillOriginal = try await indexReader.page(maximumBytes: 16)
        XCTAssertEqual(stillOriginal.text, indexPage.text)
        _ = try await GitProcess.run(at: directory, arguments: ["config", "alias.slowexport", "!printf partial; sleep 30"])
        let export = directory.appendingPathComponent("cancelled-export")
        let task = Task { try await GitProcess.runToFile(at: directory, arguments: ["slowexport"], outputFile: export) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: export.path) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        task.cancel()
        do { try await task.value; XCTFail("Expected export cancellation") } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        let existing = directory.appendingPathComponent("existing")
        try Data("preserve".utf8).write(to: existing)
        do { try await GitProcess.runToFile(at: directory, arguments: ["status"], outputFile: existing); XCTFail("Expected exclusive output rejection") } catch {}
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "preserve")
    }

}
