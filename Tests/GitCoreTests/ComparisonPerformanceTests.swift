import XCTest
@testable import GitCore

private final class ComparisonCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ command: String) { lock.lock(); stored.append(command); lock.unlock() }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
final class ComparisonPerformanceTests: XCTestCase {
    func testImmutableBlobIsReadOnceAndPartialSnapshotAvoidsRepositoryReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: root, arguments: args) }
        let repo = GitRepository(url: root), file = root.appendingPathComponent("source.unusual")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["source.unusual"]); try await repo.commit(message: "base")
        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let capture = ComparisonCommandCapture()
        let observer = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { note in
            if let record = note.object as? GitCommandRecord, record.directory == root.path { capture.append(record.command) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let snapshot = try await repo.fileComparison(path: "source.unusual")
        XCTAssertEqual(snapshot.head.data, snapshot.index.data)
        XCTAssertEqual(capture.commands.filter { $0.contains("'cat-file' 'blob'") }.count, 1)
        XCTAssertEqual(capture.commands.filter { $0.contains("'cat-file' '-s'") }.count, 1)
        let before = capture.commands.count
        let partial = try await repo.partialStaging(path: "source.unusual", unstage: false, snapshot: snapshot)
        let reads = Array(capture.commands.dropFirst(before))
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(reads[0].contains("diff"))
        XCTAssertNil(partial.unavailableReason); XCTAssertFalse(partial.hunks.isEmpty)
        try "changed after snapshot\n".write(to: file, atomically: true, encoding: .utf8)
        do { try await repo.applyPartialStaging(partial, selectedLines: Set(partial.hunks.flatMap { $0.lines.filter(\.isChange).map(\.id) })); XCTFail("Stale snapshot must still be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }
    func testGenericSyntaxAndContentDetectionAreIndependentOfExtension() {
        let source = "let value = \"hello\"; // note\nvalue = 42\n"
        for path in ["source.vue", "build.gradle", "Dockerfile", "file.custom"] {
            let tokens = SyntaxHighlighter.tokens(in: source, path: path)
            XCTAssertTrue(tokens.contains { $0.kind == .keyword })
            XCTAssertTrue(tokens.contains { $0.kind == .string })
            XCTAssertTrue(tokens.contains { $0.kind == .number })
            XCTAssertTrue(tokens.contains { $0.kind == .comment })
        }
        XCTAssertEqual(ComparisonTextDecoder.decode(Data(source.utf8)).text, source)
        XCTAssertNil(ComparisonTextDecoder.decode(Data([0, 97])).text)
        XCTAssertNil(ComparisonTextDecoder.decode(Data([0xff, 0x81])).text)
    }
}
