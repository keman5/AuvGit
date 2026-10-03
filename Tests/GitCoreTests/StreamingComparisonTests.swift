import XCTest
@testable import GitCore

final class StreamingComparisonTests: XCTestCase {
    private func fixture(_ data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        return file
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
}
