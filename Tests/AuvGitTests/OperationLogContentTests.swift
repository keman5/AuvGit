import XCTest
@testable import AuvGit
import GitCore

final class OperationLogContentTests: XCTestCase {
    func testCombinedPreviewIsBoundedWithoutTruncatingFullExport() async throws {
        let value = String(repeating: "child output\n", count: 2_000)
        let records = (0..<8).map { _ in GitCommandLog.applicationFailure(directory: nil, message: value) }
        let snapshot = OperationLogSnapshot(records: records, exitLabel: "Exit", expiredMessage: "Expired", captureLimitMessage: "Limit")
        let loader = OperationLogContentLoader()
        let preview = try await loader.preview(snapshot)
        XCTAssertLessThanOrEqual(preview.text.count, 32_768)
        XCTAssertTrue(preview.truncated)
        XCTAssertTrue(preview.fullOutputAvailable)
        let full = try await loader.load(snapshot)
        XCTAssertTrue(full.complete)
        XCTAssertEqual(full.text.components(separatedBy: value).count - 1, records.count)
        XCTAssertGreaterThan(full.pages.count, 1)
    }
    func testPagesPreserveUnicodeAndBoundNativeLayout() {
        let source = String(repeating: "👨‍👩‍👦 café\n", count: 10_000)
        let pages = OperationLogContent.pages(for: source)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), source)
        XCTAssertTrue(pages.allSatisfy { $0.count <= 32_768 })
    }

    func testBackgroundLoaderReadsFullArchiveAndIncludesChildren() async throws {
        let large = String(repeating: "sanitized output\n", count: 5_000)
        let parent = GitCommandLog.applicationFailure(directory: nil, message: large)
        let child = GitCommandLog.applicationFailure(directory: nil, message: "child token=private-value")
        let snapshot = OperationLogSnapshot(records: [parent, child], exitLabel: "Exit status", expiredMessage: "Expired", captureLimitMessage: "Capture limit")
        let loader = OperationLogContentLoader()
        let loaded = try await loader.load(snapshot)
        XCTAssertTrue(loaded.complete)
        XCTAssertTrue(loaded.text.contains(large))
        XCTAssertTrue(loaded.text.contains("child [redacted]"))
        XCTAssertFalse(loaded.text.contains("private-value"))
        XCTAssertEqual(loaded.pages.joined(), loaded.text)
        let cached = try await loader.load(snapshot)
        XCTAssertEqual(cached.text, loaded.text)
    }

    func testCancelledLoadDoesNotProduceContent() async {
        let task = Task {
            try Task.checkCancellation()
            return try await OperationLogContentLoader().load(OperationLogSnapshot(records: [], exitLabel: "Exit", expiredMessage: "Expired", captureLimitMessage: "Limit"))
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
