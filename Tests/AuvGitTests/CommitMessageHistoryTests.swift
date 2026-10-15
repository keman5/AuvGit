import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class CommitMessageHistoryTests: XCTestCase {
    func testMenuTitleTruncatesGraphemesAndKeepsStoredMessageComplete() throws {
        let title = String(repeating: "👩🏽‍💻", count: 61)
        let message = "\n  " + title + "  \nFull body"
        XCTAssertEqual(CommitMessageHistory.menuTitle(message), String(title.prefix(59)) + "…")
        XCTAssertEqual(CommitMessageHistory.menuTitle(" short title \nbody"), "short title")
        XCTAssertEqual(CommitMessageHistory.menuTitle(String(repeating: "字", count: 60)).count, 60)
        let history = CommitMessageHistory(defaults: try defaults())
        let repository = URL(fileURLWithPath: "/tmp/menu-title")
        history.record(message, for: repository)
        XCTAssertEqual(history.messages(for: repository), [message])
    }

    private func defaults() throws -> UserDefaults {
        let suite = "CommitMessageHistoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testHistoryIsRepositoryScopedDeduplicatedNewestFirstAndLimitedToTen() throws {
        let history = CommitMessageHistory(defaults: try defaults())
        let first = URL(fileURLWithPath: "/tmp/first-repository")
        let second = URL(fileURLWithPath: "/tmp/second-repository")

        history.record("shared message", for: first)
        history.record("other repository", for: second)
        for index in 1...11 { history.record("message \(index)", for: first) }
        history.record("message 5", for: first)

        XCTAssertEqual(history.messages(for: first), [
            "message 5", "message 11", "message 10", "message 9", "message 8",
            "message 7", "message 6", "message 4", "message 3", "message 2"
        ])
        XCTAssertEqual(history.messages(for: second), ["other repository"])
    }

    func testClearRemovesOnlyTheSelectedRepositoryHistory() throws {
        let history = CommitMessageHistory(defaults: try defaults())
        let first = URL(fileURLWithPath: "/tmp/first-repository")
        let second = URL(fileURLWithPath: "/tmp/second-repository")
        history.record("first", for: first)
        history.record("second", for: second)

        history.clear(for: first)

        XCTAssertEqual(history.messages(for: first), [])
        XCTAssertEqual(history.messages(for: second), ["second"])
    }

    func testRepositoryStoreRecordsSuccessfulCommitAndAmendButNotFailedCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.test"), ("commit.gpgSign", "false")] {
            _ = try await repository.workflowRead(["config", key, value])
        }
        let store = RepositoryStore(persistsSession: false, commitHistoryDefaults: try defaults())
        store.repository = repository
        store.repositoryURL = repository.url

        try Data("one".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repository.stage(paths: ["file.txt"])
        store.files = try await repository.status()
        store.commitMessage = "Initial message"
        store.commit()
        await waitUntilIdle(store)
        XCTAssertEqual(store.recentCommitMessages, ["Initial message"])

        try Data("two".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repository.stage(paths: ["file.txt"])
        store.files = try await repository.status()
        store.commitMessage = "Amended message"
        store.amend = true
        store.commit()
        await waitUntilIdle(store)
        XCTAssertEqual(store.recentCommitMessages, ["Amended message", "Initial message"])

        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        try Data("three".utf8).write(to: root.appendingPathComponent("file.txt"))
        try await repository.stage(paths: ["file.txt"])
        store.files = try await repository.status()
        store.commitMessage = "Rejected message"
        store.amend = false
        store.commit()
        await waitUntilIdle(store)
        XCTAssertEqual(store.recentCommitMessages, ["Amended message", "Initial message"])
    }

    private func waitUntilIdle(_ store: RepositoryStore) async {
        for _ in 0..<1_000 {
            if !store.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("RepositoryStore did not become idle")
    }
}
