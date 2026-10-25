import XCTest
@testable import GitCore

final class LargeTextSearchTests: XCTestCase {
    func testDenseUnicodeLineUsesExactByteOffsetsAndCapsMatches() async throws {
        let prefix = String(repeating: "前", count: 250_000)
        let start = Date()
        let result = try await LargeTextSearch.text(prefix + String(repeating: "😀hit中", count: 10_001), options: LargeTextSearchOptions(query: "hit"))
        XCTAssertEqual(result.hits.count, LargeTextSearch.maximumMatches)
        XCTAssertTrue(result.isLimited)
        for (index, hit) in result.hits.enumerated() {
            XCTAssertEqual(hit.matchOffset, UInt64(750_004 + index * 10))
            XCTAssertEqual(hit.range, NSRange(location: 250_002 + index * 6, length: 3))
            XCTAssertEqual(hit.matchByteLength, 3)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Dense matches must not repeatedly scan a long prefix")
        let zeroWidth = try await LargeTextSearch.text("前😀hit中hit", options: LargeTextSearchOptions(query: "(?=hit)", regularExpression: true))
        XCTAssertEqual(zeroWidth.hits.map(\.matchOffset), [7, 13])
        XCTAssertEqual(zeroWidth.hits.map(\.matchByteLength), [0, 0])
    }
    func testEmptyQueryDoesNotScanAnOverlongLine() async throws {
        let result = try await LargeTextSearch.text(String(repeating: "a", count: LargeTextSearch.maximumLineBytes + 1), options: LargeTextSearchOptions(query: ""))
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(result.isLimited)
    }
    func testStreamingChunkBoundaryUnicodeAndExactCursor() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let content = String(repeating: "a", count: 65_530) + "中 Needle\nneedle\n"
        try Data(content.utf8).write(to: url)
        let result = try await LargeTextSearch.file(url, options: LargeTextSearchOptions(query: "Needle", caseSensitive: true))
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits[0].cursor.line, 1)
        XCTAssertEqual(result.hits[0].matchOffset, 65_534)
        XCTAssertEqual(result.hits[0].range, NSRange(location: 65_532, length: 6))
        let location = result.hits[0].pageLocation(maximumBytes: 128 * 1024)
        XCTAssertEqual(location.cursor.offset, 0)
        XCTAssertEqual(location.range, result.hits[0].range)
        XCTAssertEqual(location.firstColumn, 1)
        let reader = try StreamingTextFile(url: url)
        let page = try await reader.page(at: location.cursor)
        XCTAssertTrue(page.text.hasPrefix("aaaa"))
        XCTAssertEqual((page.text as NSString).substring(with: location.range), "Needle")
    }
    func testLineRegexCaseAndExplicitResourceLimits() async throws {
        let regex = try await LargeTextSearch.text("ab 42\nab 7\nAB 9\n", options: LargeTextSearchOptions(query: "^ab [0-9]+$", caseSensitive: true, regularExpression: true))
        XCTAssertEqual(regex.hits.map { $0.cursor.line }, [1, 2])
        let capped = try await LargeTextSearch.text(String(repeating: "hit\n", count: LargeTextSearch.maximumMatches + 1), options: LargeTextSearchOptions(query: "hit"))
        XCTAssertEqual(capped.hits.count, LargeTextSearch.maximumMatches); XCTAssertTrue(capped.isLimited)
        do {
            _ = try await LargeTextSearch.text(String(repeating: "a", count: LargeTextSearch.maximumLineBytes + 1), options: LargeTextSearchOptions(query: "a"))
            XCTFail("Overlong lines must be reported rather than silently omitted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1 MiB")) }
    }
    func testCancellationStopsDetachedSearch() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LargeTextSearch.text(String(repeating: "ordinary line\n", count: 100_000), options: LargeTextSearchOptions(query: "absent"))
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
    func testLargeCompactPatchRetainsRealLateLineNumbers() async throws {
        let count = 120_000
        let prefix = String(repeating: "unchanged source line\n", count: count)
        let patch = try await LargeTextComparison.patch(source: prefix + "original\n", target: prefix + "modified\n")
        let parsed = DiffParser.parse(patch)
        XCTAssertEqual(parsed.lines.first(where: { $0.kind == .deletion })?.oldNumber, count + 1)
        XCTAssertEqual(parsed.lines.first(where: { $0.kind == .addition })?.newNumber, count + 1)
        XCTAssertFalse(parsed.isTruncated)
    }
    func testStreamingCompactUsesIndexAndWorktreeSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        let repository = GitRepository(url: root), file = root.appendingPathComponent("large.txt")
        let prefix = String(repeating: "same line\n", count: 30_000)
        try Data((prefix + "head\n").utf8).write(to: file); try await repository.stage(paths: ["large.txt"]); try await repository.commit(message: "base")
        try Data((prefix + "index\n").utf8).write(to: file); try await repository.stage(paths: ["large.txt"])
        try Data((prefix + "disk\n").utf8).write(to: file)
        let index = try await repository.streamingDiff(path: "large.txt", revision: .index)
        let disk = try await repository.streamingDiff(path: "large.txt", revision: .worktree)
        XCTAssertTrue(index.contains("-head\n+index"))
        XCTAssertTrue(disk.contains("-index\n+disk"))
        XCTAssertFalse(disk.contains("-head\n"))
    }
    func testSearchPageKeepsOriginalLineAndColumnOffset() {
        let page = TextPager.pageFromLine("one\ntwo needle\nthree\n", firstLine: 2, columnOffset: 4)
        XCTAssertEqual(page.firstLine, 2)
        XCTAssertTrue(page.text.hasPrefix("needle"))
    }
    func testNormalSearchPageRetainsPrefixAndUnicodeColumn() async throws {
        let text = "first\n前文 needle tail\nlast\n"
        let search = try await LargeTextSearch.text(text, options: LargeTextSearchOptions(query: "needle"))
        let hit = try XCTUnwrap(search.hits.first), location = hit.pageLocation(maximumUTF16: 100_000)
        let page = TextPager.pageFromLine(text, firstLine: hit.cursor.line, columnOffset: location.firstColumn - 1)
        XCTAssertTrue(page.text.hasPrefix("前文 needle"))
        XCTAssertEqual((page.text as NSString).substring(with: location.range), "needle")
        XCTAssertEqual(location.range.location, 3)
        XCTAssertEqual(page.firstLine, 2)
        let continued = hit.pageLocation(maximumUTF16: 4)
        XCTAssertEqual(continued.firstColumn, 4)
        XCTAssertEqual(continued.range.location, 0)
        XCTAssertEqual(continued.cursor.offset, hit.matchOffset)
    }
}
