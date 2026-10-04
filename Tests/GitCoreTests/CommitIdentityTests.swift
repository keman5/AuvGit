import XCTest
@testable import GitCore

final class CommitIdentityTests: XCTestCase {
    func testAvatarUsesVerifiedNoreplyLoginOrNormalizedEmailHash() {
        XCTAssertEqual(CommitAvatarIdentity.githubLogin(email: "123+Octocat@users.noreply.github.com"), "octocat")
        XCTAssertEqual(CommitAvatarIdentity.githubLogin(email: "octocat@users.noreply.github.com"), "octocat")
        XCTAssertEqual(CommitAvatarIdentity.url(email: "123+octocat@users.noreply.github.com")?.host, "github.com")
        XCTAssertNil(CommitAvatarIdentity.githubLogin(email: "octocat@example.com"))
        XCTAssertNil(CommitAvatarIdentity.githubLogin(email: "x+octocat@users.noreply.github.com"))
        XCTAssertNil(CommitAvatarIdentity.githubLogin(email: "123+../login@users.noreply.github.com"))
        XCTAssertNil(CommitAvatarIdentity.url(email: "Author Name"))
        XCTAssertEqual(CommitAvatarIdentity.url(email: " TEST@example.com ")?.path, "/avatar/55502f40dc8b7c769880b10874abc9d0")
    }
    func testActualGitLogPreservesBothIdentitiesAndDates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Committer Name"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "committer@example.com"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "--allow-empty", "--author", "Author Name <123+octocat@users.noreply.github.com>", "--date", "2000-01-01T00:00:00Z", "-m", "Identity fixture"])
        let rows = try await GitRepository(url: root).log()
        let commit = try XCTUnwrap(rows.first)
        XCTAssertEqual(commit.author, "Author Name")
        XCTAssertEqual(commit.authorEmail, "123+octocat@users.noreply.github.com")
        XCTAssertEqual(commit.committer, "Committer Name")
        XCTAssertEqual(commit.committerEmail, "committer@example.com")
        XCTAssertEqual(commit.date.timeIntervalSince1970, 946684800)
        XCTAssertGreaterThan(commit.committedDate, commit.date)
    }
}
