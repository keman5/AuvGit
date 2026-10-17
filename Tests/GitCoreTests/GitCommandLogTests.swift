import XCTest
@testable import GitCore

private final class CommandRecordCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [GitCommandRecord] = []
    func append(_ record: GitCommandRecord) { lock.lock(); records.append(record); lock.unlock() }
    var values: [GitCommandRecord] { lock.lock(); defer { lock.unlock() }; return records }
}
final class GitCommandLogTests: XCTestCase {
    func testUnchangedBranchAndRemoteEditsRunNoGitCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await GitProcess.run(at: directory, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: directory, arguments: ["remote", "add", "origin", "https://example.test/repo"])
        let repository = GitRepository(url: directory)
        let remotes = try await repository.remoteConfigurations()
        let remote = try XCTUnwrap(remotes.first)
        let capture = CommandRecordCapture()
        let observer = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { notification in
            if let record = notification.object as? GitCommandRecord, record.directory == directory.path { capture.append(record) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await repository.renameBranch(oldName: "main", newName: "main")
        try await repository.updateRemoteURL(expected: remote, fetchIndex: 0, fetchURL: remote.fetchURLs[0], pushURL: nil)
        try await repository.updateRemoteURL(expected: remote, fetchIndex: 0, fetchURL: remote.fetchURLs[0], pushURL: "")
        XCTAssertTrue(capture.values.isEmpty)
    }
    func testRemoteRejectionPreservesSanitizedReasonBeforeGenericHookSummary() {
        let diagnostic = "remote: Counting objects: 100% (10/10), done.\nremote: error: Force pushing to protected branch main is forbidden.\nremote: token=private\nTo https://user:private@host/repo\n! [remote rejected] main -> main (pre-receive hook declined)\nerror: failed to push some refs"
        XCTAssertEqual(GitFailureSummary.key(for: diagnostic), "Remote rejected the push")
        let summary = GitFailureSummary.message(for: diagnostic, localize: { "localized: " + $0 })
        XCTAssertEqual(summary, "localized: Remote rejected the push: error: Force pushing to protected branch main is forbidden. · [redacted]")
        XCTAssertFalse(summary?.contains("private") ?? true)
        XCTAssertEqual(GitFailureSummary.message(for: "! [remote rejected] main -> main (protected branch)", localize: { $0 }), "Remote rejected the push: ! [remote rejected] main -> main (protected branch)")
        XCTAssertEqual(GitFailureSummary.message(for: "remote: error: GH006: Protected branch update failed\nremote: Cannot force-push to this branch\n! [remote rejected] main -> main (pre-receive hook declined)", localize: { $0 }), "Remote rejected the push: error: GH006: Protected branch update failed · Cannot force-push to this branch")
        XCTAssertEqual(GitFailureSummary.key(for: "remote: error: GH013: Repository rule violations found\npre-receive hook declined"), "Remote rejected the push")
        XCTAssertEqual(GitFailureSummary.message(for: "pre-push hook failed", localize: { $0 }), "Git hook rejected the operation")
    }
    func testLongSanitizedOutputKeepsTailAndPreviewPrefix() {
        let source = "token=private\n" + String(repeating: "line\n", count: 20_000) + "END_OF_COMPLETE_LOG_OUTPUT"
        let safe = GitCommandLog.redact(source)
        let record = GitCommandRecord(date: Date(), directory: "", command: "git diff", output: safe, error: nil, duration: 0, exitCode: 0, operation: "diff")
        XCTAssertTrue(record.previewTruncated); XCTAssertTrue(record.fullOutputAvailable)
        XCTAssertEqual(record.output, String(record.fullOutput.prefix(32_768)))
        XCTAssertTrue(record.fullOutput.hasSuffix("END_OF_COMPLETE_LOG_OUTPUT"))
        XCTAssertFalse(record.fullOutput.contains("private"))
    }
    func testArchiveIsRemovedWhenRecordIsReleased() throws {
        func files() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("auvgit-log-") })
        }
        let before = try files()
        var record: GitCommandRecord? = GitCommandRecord(date: Date(), directory: "", command: "git diff", output: String(repeating: "x", count: 40_000), error: nil, duration: 0, exitCode: 0, operation: "diff")
        XCTAssertTrue(try XCTUnwrap(record).fullOutputAvailable)
        let created = try files().subtracting(before)
        XCTAssertEqual(created.count, 1)
        record = nil
        XCTAssertTrue(try files().isDisjoint(with: created))
    }
    func testAdditionalFailureCategoriesTakePriorityOverGenericConnection() {
        for diagnostic in ["fatal: unknown index entry format 0xbdef0000", "BUG: read-cache.c:340: unsupported ce_mode: 27573600000"] {
            XCTAssertEqual(GitFailureSummary.key(for: diagnostic), "Git index is corrupt; workspace changes are unavailable.")
        }
        XCTAssertEqual(GitFailureSummary.key(for: "unable to access: SSL certificate problem"), "TLS certificate verification failed")
        XCTAssertEqual(GitFailureSummary.key(for: "unable to access: proxy authentication failed"), "Proxy connection or authentication failed")
        XCTAssertEqual(GitFailureSummary.key(for: "Host key verification failed"), "SSH host key verification failed")
        XCTAssertEqual(GitFailureSummary.key(for: "gpg failed to sign the data"), "Commit signing failed")
        XCTAssertEqual(GitFailureSummary.key(for: "pre-receive hook declined"), "Git hook rejected the operation")
        XCTAssertEqual(GitFailureSummary.key(for: "git-lfs filter failed"), "Git LFS operation failed")
        XCTAssertEqual(GitFailureSummary.key(for: "No space left on device"), "Disk is full")
    }
    func testCommonFailureClassificationAndRedaction() {
        XCTAssertEqual(GitFailureSummary.key(for: "fatal: not a git repository (or any parent directory): .git"), "Not a Git repository")
        XCTAssertEqual(GitFailureSummary.key(for: "fatal: could not read Username: terminal prompts disabled"), "Authentication required")
        XCTAssertEqual(GitFailureSummary.key(for: "! [rejected] main -> main (non-fast-forward)"), "Remote and local branches have diverged")
        let safe = GitCommandLog.redact("https://user:private@host/repo token=private Authorization: Bearer private gho_private")
        XCTAssertFalse(safe.contains("private"))
    }
    func testRealCommandCaptureAndSensitiveConfigurationOmission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = CommandRecordCapture()
        let observer = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { notification in
            if let record = notification.object as? GitCommandRecord, record.directory == directory.path { capture.append(record) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try await GitProcess.run(at: directory, arguments: ["init"])
        _ = try await GitProcess.run(at: directory, arguments: ["config", "credential.helper", "!echo private-value"])
        do { _ = try await GitProcess.run(at: directory, arguments: ["rev-parse", "--verify", "missing"]); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(capture.values.count, 3)
        XCTAssertTrue(capture.values[0].command.contains("'init'"))
        XCTAssertTrue(capture.values[0].command.contains("'--no-pager'"))
        XCTAssertEqual(capture.values[0].operation, "init")
        XCTAssertEqual(capture.values[0].exitCode, 0)
        XCTAssertFalse(capture.values[0].output.isEmpty)
        XCTAssertFalse(capture.values[1].command.contains("private-value"))
        XCTAssertNotNil(capture.values[2].error)
        XCTAssertEqual(capture.values[2].exitCode, 128)
    }
}
