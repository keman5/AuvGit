import XCTest
import GitCore
import AuvGitLocalization
@testable import AuvGit

final class PullResultNoticeTests: XCTestCase {
    func testReceiveTimeoutUsesLocalizedSummaryAndPreservesRawDiagnosticInLog() {
        let diagnostic = "fatal: unable to access '[remote] Recv failure: Operation timed out"
        let error = GitError(diagnostic)
        XCTAssertEqual(PullResultNotice(error: error).message, L10n.text("Git operation timed out", table: "OperationLog"))
        let record = GitCommandLog.userOperation(directory: URL(fileURLWithPath: "/tmp"), name: "Pull", started: Date(), error: diagnostic)
        XCTAssertEqual(record.fullError, diagnostic)
    }

    func testUnknownFailureRemainsSanitizedAndReadable() {
        let notice = PullResultNotice(error: GitError("Custom failure at https://user:secret@example.test/repo"))
        XCTAssertEqual(notice.message, "Custom failure at [remote]")
    }
}
