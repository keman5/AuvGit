import XCTest
@testable import GitCore

final class StaticComparisonPreviewTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        return (root, GitRepository(url: root))
    }
    func testDecodedPDFAndSVGStillRouteToStaticPreview() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in [("Preview.PDF", "%PDF-1.7\nASCII document"), ("Preview.SVG", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
            let snapshot = try await repository.fileComparison(path: name)
            XCTAssertNotNil(snapshot.worktree.text)
            XCTAssertTrue(snapshot.requiresStaticPreview)
            let preview = try await repository.comparisonPreview(target: .worktree(path: name, untracked: true))
            XCTAssertTrue(preview.requiresStaticPreview)
        }
    }
    func testBinaryStagedWorktreeAndHistoricalRevisionMapping() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        let original = Data([0, 1, 2]), staged = Data([0, 3, 4]), worktree = Data([0, 5, 6])
        try original.write(to: file); try await repository.stage(paths: ["image.png"]); try await repository.commit(message: "base")
        try staged.write(to: file); try await repository.stage(paths: ["image.png"])
        try worktree.write(to: file)
        let stagedPreview = try await repository.comparisonPreview(target: .staged(path: "image.png"))
        XCTAssertEqual(stagedPreview.head.data, original); XCTAssertEqual(stagedPreview.worktree.data, staged)
        let workingPreview = try await repository.comparisonPreview(target: .worktree(path: "image.png", untracked: false))
        XCTAssertEqual(workingPreview.head.data, staged); XCTAssertEqual(workingPreview.worktree.data, worktree)
        XCTAssertTrue(workingPreview.requiresStaticPreview)
        try await repository.commit(message: "staged")
        let historical = try await repository.comparisonPreview(target: .commit(hash: "HEAD", path: "image.png"))
        XCTAssertEqual(historical.head.data, original); XCTAssertEqual(historical.worktree.data, staged)
    }
    func testOversizedBinaryMetadataAndLargeUTF8StreamingEligibility() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        FileManager.default.createFile(atPath: file.path, contents: Data([0, 1]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(FileComparisonLimits.previewBytes + 1)); try handle.close()
        let binary = try await repository.fileComparison(path: "large")
        XCTAssertNil(binary.worktree.data); XCTAssertNil(binary.worktree.characterCount)
        XCTAssertEqual(binary.worktree.byteCount, FileComparisonLimits.previewBytes + 1)
        XCTAssertTrue(binary.worktree.isBinary); XCTAssertFalse(binary.worktree.canStreamText)
        try await repository.stage(paths: ["large"])
        let stagedBinary = try await repository.comparisonPreview(target: .staged(path: "large"))
        XCTAssertNil(stagedBinary.worktree.data)
        XCTAssertEqual(stagedBinary.worktree.byteCount, FileComparisonLimits.previewBytes + 1)
        XCTAssertTrue(stagedBinary.worktree.isBinary)
        // The 4 KiB sample ends partway through a multibyte character.
        let text = Data((String(repeating: "a", count: 4095) + "中\n").utf8)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: text)
        var remaining = FileComparisonLimits.previewBytes + 1 - text.count
        let chunk = Data(repeating: 97, count: 1024 * 1024)
        while remaining > 0 { let count = min(remaining, chunk.count); try writer.write(contentsOf: chunk.prefix(count)); remaining -= count }
        try writer.close()
        let largeText = try await repository.fileComparison(path: "large")
        XCTAssertTrue(largeText.worktree.canStreamText); XCTAssertNil(largeText.worktree.data)
        let reader = try await repository.streamingWorktree(path: "large")
        let page = try await reader.page(maximumBytes: 4096)
        XCTAssertTrue(page.text.hasPrefix(String(repeating: "a", count: 4095)))
        XCTAssertEqual(page.totalBytes, UInt64(FileComparisonLimits.previewBytes + 1))
    }
    func testPrefixReadIsExactBoundedAndReportsFailures() async throws {
        let (root, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["config", "alias.prefix", "!printf '%8192s' ''; sleep 30"])
        let start = Date()
        let output = try await GitProcess.run(at: root, arguments: ["prefix"], timeout: 1, outputPrefixBytes: 4096)
        XCTAssertEqual(output.data.count, 4096)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        _ = try await GitProcess.run(at: root, arguments: ["config", "alias.delayed", "!sleep 30"])
        do { _ = try await GitProcess.run(at: root, arguments: ["delayed"], timeout: 0.2, outputPrefixBytes: 4096); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        do { _ = try await GitProcess.run(at: root, arguments: ["cat-file", "blob", "missing"], timeout: 1, outputPrefixBytes: 4096); XCTFail("Expected Git error") }
        catch { XCTAssertNotNil((error as? GitError)?.exitCode) }
    }
    func testDecodedTextReportsCharactersSeparatelyFromBytes() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("中文".utf8).write(to: root.appendingPathComponent("text"))
        let preview = try await repository.fileComparison(path: "text")
        XCTAssertEqual(preview.worktree.byteCount, 6); XCTAssertEqual(preview.worktree.characterCount, 2)
    }
}
