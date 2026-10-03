import XCTest
@testable import GitCore
final class SessionPersistenceTests: XCTestCase {
    func testSessionRoundTripPreservesIndependentDraftsAndDeepSelections() throws {
        var first = RepositoryViewState(); first.commitMessage = "subject\n\nbody 日本語"; first.amend = true; first.historyAuthor = "Alice"; first.historySearch = "body"; first.historyRef = "topic"; first.historyPath = "folder/file"; first.selectedPaths = ["a file", "line\nname"]; first.selectedCommit = String(repeating: "a", count: 40); first.selectedCommitPath = "old/file"; first.mode = "history"
        var second = RepositoryViewState(); second.commitMessage = "another draft"; second.fileFilter = "file"
        var session = RepositorySession(); session.openRepositories = ["/missing/repository", "/accessible/repository"]; session.activeRepository = session.openRepositories[0]; session.repositories = [session.openRepositories[0]: first, session.openRepositories[1]: second]
        let decoded = try RepositorySession.decode(session.encoded()); XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.firstAccessibleRepository { $0 == "/accessible/repository" }, "/accessible/repository")
        XCTAssertEqual(decoded.repositories["/missing/repository"]?.commitMessage, first.commitMessage)
        XCTAssertEqual(decoded.repositories["/accessible/repository"]?.commitMessage, "another draft")
    }
    func testNormalizationAndMalformedSessionsDoNotBecomeEmptyDrafts() throws {
        var session = RepositorySession(); session.openRepositories = ["/one", "/one", "relative", "/two"]; session.activeRepository = "/unknown"
        let decoded = try RepositorySession.decode(session.encoded()); XCTAssertEqual(decoded.openRepositories, ["/one", "/two"]); XCTAssertEqual(decoded.activeRepository, "/one")
        XCTAssertThrowsError(try RepositorySession.decode(Data("broken".utf8)))
        session.schemaVersion = 999; XCTAssertThrowsError(try RepositorySession.decode(session.encoded()))
    }
    func testCorruptedPrimaryRecoversValidBackupWithoutReplacingDraft() throws {
        var state = RepositoryViewState(); state.commitMessage = "saved full draft\n\nbody"; state.amend = true
        var valid = RepositorySession(); valid.openRepositories = ["/recover"]; valid.activeRepository = "/recover"; valid.repositories["/recover"] = state
        let backup = try valid.encoded(), corrupt = Data("partial write".utf8)
        let recovery = RepositorySession.recover(primary: corrupt, backup: backup)
        XCTAssertEqual(recovery.session, valid); XCTAssertEqual(recovery.source, backup); XCTAssertEqual(recovery.corruptPrimary, corrupt)
        XCTAssertEqual(recovery.session.repositories["/recover"]?.commitMessage, state.commitMessage)
    }

}
