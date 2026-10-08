import XCTest
@testable import GitCore

final class StaticComparisonPreviewTests: XCTestCase {
    private func fixture() async throws -> (URL, GitRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        return (root, GitRepository(url: root))
    }
    func testWorkingTextDisplayRunsOnlyDiffAndKeepsBinaryFallback() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("text.swift")
        try Data("before\n".utf8).write(to: file)
        try await repository.stage(paths: ["text.swift"]); try await repository.commit(message: "before")
        try Data("after\n".utf8).write(to: file)
        let commands = PreviewCommands()
        let observer = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { note in
            if let record = note.object as? GitCommandRecord, record.directory == root.path { commands.append(record.command) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let result = try await repository.displayDiff(target: .worktree(path: "text.swift", untracked: false))
        XCTAssertNil(result.preview)
        XCTAssertTrue(result.text.contains("-before")); XCTAssertTrue(result.text.contains("+after"))
        XCTAssertEqual(commands.values.count, 1)
        XCTAssertTrue(commands.values.first?.contains("'diff'") == true)
        let format = ComparisonTextFormat(encoding: .utf16LE, lineEnding: .lf)
        try ComparisonTextDecoder.encode("decoded\n", format: format).write(to: file)
        let decoded = try await repository.displayDiff(target: .worktree(path: "text.swift", untracked: false))
        XCTAssertNil(decoded.preview); XCTAssertTrue(decoded.text.contains("+decoded"))
        try Data([0, 1, 2]).write(to: file)
        let binary = try await repository.displayDiff(target: .worktree(path: "text.swift", untracked: false))
        XCTAssertNotNil(binary.preview); XCTAssertEqual(binary.preview?.worktree.data, Data([0, 1, 2]))
        let invalidUTF8 = Data([0x89, 0x50, 0x4e, 0x47, 0xff])
        try invalidUTF8.write(to: file)
        let undecodable = try await repository.displayDiff(target: .worktree(path: "text.swift", untracked: false))
        XCTAssertNotNil(undecodable.preview); XCTAssertEqual(undecodable.preview?.worktree.data, invalidUTF8)
        XCTAssertTrue(undecodable.text.isEmpty)
    }
    func testUTF16BinaryGitPatchUsesDecodedDisplayOnlyForRealRevisions() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = "Encoded.custom", file = root.appendingPathComponent(path)
        let format = ComparisonTextFormat(encoding: .utf16LE, lineEnding: .lf)
        let before = try ComparisonTextDecoder.encode("let before = 1\n", format: format)
        let after = try ComparisonTextDecoder.encode("let after = 2\n", format: format)
        try before.write(to: file); try await repository.stage(paths: [path]); try await repository.commit(message: "before")
        try after.write(to: file)
        let working = try await repository.comparisonPreview(target: .worktree(path: path, untracked: false))
        let raw = try await repository.diff(target: .worktree(path: path, untracked: false))
        XCTAssertTrue(DiffParser.parse(raw).isBinary)
        let display = try await working.displayPatch(fallingBackFrom: raw)
        XCTAssertFalse(DiffParser.parse(display).isBinary)
        XCTAssertTrue(display.contains("-let before = 1")); XCTAssertTrue(display.contains("+let after = 2"))
        XCTAssertEqual(try Data(contentsOf: file), after)
        let native = try await repository.fileComparison(path: path)
        XCTAssertEqual(native.index.text, "let before = 1\n"); XCTAssertEqual(native.worktree.text, "let after = 2\n")
        XCTAssertTrue(native.worktree.isEditable)
        let nativePatch = try await native.worktreeDisplayPatch(fallingBackFrom: raw)
        XCTAssertTrue(nativePatch.contains("-let before = 1")); XCTAssertTrue(nativePatch.contains("+let after = 2"))
        try await repository.stage(paths: [path])
        let staged = try await repository.comparisonPreview(target: .staged(path: path))
        let stagedRaw = try await repository.diff(target: .staged(path: path))
        let stagedDisplay = try await staged.displayPatch(fallingBackFrom: stagedRaw)
        XCTAssertTrue(stagedDisplay.contains("+let after = 2"))
        try await repository.commit(message: "after")
        let historical = try await repository.comparisonPreview(target: .commit(hash: "HEAD", path: path))
        let historicalRaw = try await repository.diff(target: .commit(hash: "HEAD", path: path))
        let historicalDisplay = try await historical.displayPatch(fallingBackFrom: historicalRaw)
        XCTAssertTrue(historicalDisplay.contains("-let before = 1")); XCTAssertTrue(historicalDisplay.contains("+let after = 2"))
        try ComparisonTextDecoder.encode("let staged = 3\n", format: format).write(to: file)
        try await repository.stage(paths: [path])
        try ComparisonTextDecoder.encode("let working = 4\n", format: format).write(to: file)
        let differingIndex = try await repository.fileComparison(path: path)
        let worktreeRaw = try await repository.diff(target: .worktree(path: path, untracked: false))
        let worktreeDisplay = try await differingIndex.worktreeDisplayPatch(fallingBackFrom: worktreeRaw)
        XCTAssertTrue(worktreeDisplay.contains("-let staged = 3")); XCTAssertTrue(worktreeDisplay.contains("+let working = 4"))
        XCTAssertFalse(worktreeDisplay.contains("-let after = 2"))
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.custom"))
        let binaryTarget = DiffTarget.worktree(path: "binary.custom", untracked: true)
        let binary = try await repository.comparisonPreview(target: binaryTarget)
        let binaryRaw = try await repository.diff(target: binaryTarget)
        let binaryDisplay = try await binary.displayPatch(fallingBackFrom: binaryRaw)
        XCTAssertEqual(binaryDisplay, binaryRaw)
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
        let display = try await repository.displayDiff(target: .worktree(path: "large", untracked: true))
        XCTAssertEqual(display.preview?.worktree.byteCount, FileComparisonLimits.previewBytes + 1)
        XCTAssertTrue(display.text.isEmpty)
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

private final class PreviewCommands: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    func append(_ command: String) { lock.lock(); defer { lock.unlock() }; commands.append(command) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return commands }
}
