import XCTest
@testable import GitCore

final class GitExtensionsTests: XCTestCase {
    func testVersionOrderingAndShortcutRepair() throws {
        XCTAssertTrue(try UpdateManifest.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(try UpdateManifest.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(try UpdateManifest.isNewer("1.0.0-beta.2", than: "1.0.0"))
        XCTAssertTrue(try UpdateManifest.isNewer("1.0.0", than: "1.0.0-rc.1"))
        XCTAssertTrue(try UpdateManifest.isNewer("1.0.0-beta.10", than: "1.0.0-beta.2"))
        XCTAssertThrowsError(try UpdateManifest.isNewer("invalid", than: "1.0.0"))
        XCTAssertFalse(ShortcutRules.isValid("l")); XCTAssertFalse(ShortcutRules.isValid("q")); XCTAssertFalse(ShortcutRules.isValid("s")); XCTAssertFalse(ShortcutRules.isValid("c"))
        let repaired = ShortcutRules.normalized(["q", "r", "r", "C"])
        XCTAssertEqual(Set(repaired).count, 4); XCTAssertTrue(repaired.allSatisfy(ShortcutRules.isValid))
    }
    func testHostedReviewURLs() throws {
        let github = try HostedReview.url(remote: "git@github.com:owner/repo.git", source: "feature/space", target: "main")
        XCTAssertEqual(github.host, "github.com"); XCTAssertTrue(github.path.contains("/compare/main...feature/space"))
        let gitlab = try HostedReview.url(remote: "https://gitlab.com/group/repo.git", source: "feature/test", target: "develop")
        XCTAssertEqual(URLComponents(url: gitlab, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "feature/test")
        XCTAssertThrowsError(try HostedReview.url(remote: "https://evil.example/repo", source: "a", target: "b"))
        XCTAssertThrowsError(try HostedReview.url(remote: "https://user:secret@github.com/owner/repo", source: "a", target: "b"))
    }
    func testFeatureReleaseHotfixAndDirtyRefusal() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["commit", "--allow-empty", "-m", "base"], ["branch", "develop"]] { _ = try await GitProcess.run(at: dir, arguments: args) }
        let repo = GitRepository(url: dir)
        do { try await repo.startGitFlow(kind: .feature, name: "bad", main: "main", develop: "main"); XCTFail("distinct bases required") } catch { }
        do { try await repo.startGitFlow(kind: .feature, name: "bad", main: "feature/bad", develop: "develop"); XCTFail("task branch must differ from bases") } catch { }
        do { try await repo.startGitFlow(kind: .feature, name: "../escape"); XCTFail("invalid branch must reject") } catch { }
        for (kind, name) in [(GitFlowKind.feature, "one"), (.release, "1.0"), (.hotfix, "1.0.1")] {
            try await repo.startGitFlow(kind: kind, name: name)
            _ = try await GitProcess.run(at: dir, arguments: ["commit", "--allow-empty", "-m", name])
            try await repo.finishGitFlow(kind: kind, name: name)
            let current = try await repo.currentBranch(); XCTAssertEqual(current, "develop")
        }
        let tags = try await GitProcess.run(at: dir, arguments: ["tag"]).text
        XCTAssertTrue(tags.contains("1.0\n")); XCTAssertTrue(tags.contains("1.0.1"))
        try Data("dirty".utf8).write(to: dir.appendingPathComponent("untracked"))
        do { try await repo.startGitFlow(kind: .feature, name: "dirty"); XCTFail("dirty must reject") } catch { }
    }
}
