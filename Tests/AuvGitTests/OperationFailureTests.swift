import XCTest
@testable import GitCore
import AuvGitLocalization
@testable import AuvGit

final class OperationFailureTests: XCTestCase {
    @MainActor
    func testRemoteDeletionUsesDeletionGuidanceInsteadOfForcePushGuidance() {
        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
        let key = "Remote branch changed; fetch updates and confirm deletion again"
        for language in ["en", "zh-Hans", "zh-Hant", "ja"] {
            UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
            XCTAssertEqual(OperationFailure.message(GitError(key + "\n[rejected] (stale info)")), L10n.text(key, table: "OperationLog"))
            if language != "en" { XCTAssertNotEqual(L10n.text(key, table: "OperationLog"), key) }
        }
    }
    @MainActor
    func testMergeDialogTranslatesButOperationLogKeepsOriginalDiagnostic() {
        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
        let original = "Merge requires a commit and label"
        let observer = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { notification in
            XCTAssertEqual((notification.object as? OperationFailure.Event)?.message, original)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for language in ["en", "zh-Hans", "zh-Hant", "ja"] {
            UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
            let message = OperationFailure.message(GitError(original))
            XCTAssertEqual(message, L10n.text(original, table: "OperationLog"))
            if language != "en" { XCTAssertNotEqual(message, original) }
        }
    }
    func testUnknownDiagnosticRemainsReadableAndRedacted() {
        let unknown = "Unknown diagnostic with token=private-token"
        XCTAssertEqual(OperationFailure.message(GitError(unknown)), GitCommandLog.redact(unknown))
    }
    @MainActor
    func testBridgePreservesRepositoryAndRedactsSecret() {
        let repository = URL(fileURLWithPath: "/tmp/test-repository")
        let delivered = expectation(description: "Failure bridge")
        let observer = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { notification in
            guard let event = notification.object as? OperationFailure.Event else { return }
            XCTAssertEqual(event.repository, repository)
            XCTAssertFalse(event.message.contains("private-token"))
            delivered.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "token=private-token"])
        XCTAssertFalse(OperationFailure.message(error, repository: repository).contains("private-token"))
        wait(for: [delivered], timeout: 1)
    }
    func testCancellationIsNotPublishedAsFailure() {
        let notDelivered = expectation(description: "Cancellation remains quiet")
        notDelivered.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { _ in notDelivered.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = OperationFailure.message(CancellationError())
        wait(for: [notDelivered], timeout: 0.05)
    }
    @MainActor
    func testRealRetainedHelperOutputFailureTranslatesDialogsAndSummaryWhileKeepingRawLogs() async throws {
        let original = "Git exited but an external helper kept its output stream open."
        let key = "External Git helper did not close its output stream"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("git-output-helper-fixture")
        // The leader exits immediately, while its background helper inherits the
        // capture pipes. Exercise the actual GitProcess error producer unchanged.
        try Data("#!/bin/sh\n/bin/sleep 30 &\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let commandLogged = expectation(description: "Raw helper diagnostic recorded")
        let logObserver = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { notification in
            guard let record = notification.object as? GitCommandRecord, record.directory == directory.path else { return }
            XCTAssertEqual(record.error, original)
            XCTAssertEqual(record.fullError, original)
            XCTAssertEqual(record.fullContents().error, original)
            commandLogged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(logObserver) }
        var failure: Error?
        do {
            _ = try await GitCommandLog.$suppressRoutineReads.withValue(false) {
                try await GitProcess.run(at: directory, arguments: ["status"], executable: executable.path)
            }
            XCTFail("The helper retaining Git output must throw")
        } catch { failure = error }
        let error = try XCTUnwrap(failure)
        XCTAssertEqual(error.localizedDescription, original)
        XCTAssertEqual(GitFailureSummary.key(for: error.localizedDescription), key)
        XCTAssertEqual(GitFailureSummary.key(for: String(original.dropLast())), key)
        await fulfillment(of: [commandLogged], timeout: 1)

        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
        let eventLogged = expectation(description: "Localized dialogs preserve raw failure bridge")
        eventLogged.expectedFulfillmentCount = 4
        let eventObserver = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { notification in
            guard let event = notification.object as? OperationFailure.Event, event.repository == directory else { return }
            XCTAssertEqual(event.message, original)
            eventLogged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(eventObserver) }
        let expected = [
            "en": "Git has exited, but an external helper has not closed its output stream.",
            "zh-Hans": "Git 已结束，但外部辅助程序尚未关闭输出流。",
            "zh-Hant": "Git 已結束，但外部輔助程式尚未關閉輸出串流。",
            "ja": "Git は終了しましたが、外部ヘルパーが出力ストリームを閉じていません。"
        ]
        for language in ["en", "zh-Hans", "zh-Hant", "ja"] {
            UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
            XCTAssertEqual(OperationFailure.message(error, repository: directory), expected[language])
            XCTAssertEqual(GitFailureSummary.message(for: original, localize: { L10n.text($0, table: "OperationLog") }), expected[language], "Native operation summary uses the same mapping")
        }
        await fulfillment(of: [eventLogged], timeout: 1)
    }

    @MainActor
    func testRemoteDisconnectTranslationsKeepEndpointAndRawDiagnostic() throws {
        let diagnostic = """
        Connection closed by 127.0.0.1 port 7890
        fatal: Could not read from remote repository.

        Please make sure you have the correct access rights
        and the repository exists.
        """
        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
        let logged = expectation(description: "Original diagnostic reaches operation log")
        logged.expectedFulfillmentCount = 4
        let repository = URL(fileURLWithPath: "/localization-test")
        let observer = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { notification in
            guard let event = notification.object as? OperationFailure.Event, event.repository == repository else { return }
            XCTAssertEqual(event.message, diagnostic)
            logged.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let translations = [
            "en": "SSH connection closed by 127.0.0.1 on port 7890.",
            "zh-Hans": "SSH 连接已被 127.0.0.1（端口 7890）关闭。",
            "zh-Hant": "SSH 連線已由 127.0.0.1（連接埠 7890）關閉。",
            "ja": "127.0.0.1（ポート 7890）が SSH 接続を閉じました。"
        ]
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("ssh://git@example.test/repo"))
        for (language, prefix) in translations {
            UserDefaults.standard.set(language, forKey: L10n.preferenceKey)
            let summary = OperationFailure.message(GitError(diagnostic), repository: repository)
            let guidance = L10n.text("Could not read the remote repository. Check your access rights and confirm the repository exists.", table: "OperationLog")
            XCTAssertEqual(summary, prefix + "\n\n" + guidance)
            XCTAssertEqual(OperationFailure.display(diagnostic), summary)
            XCTAssertEqual(RepositoryStore.progressDetail("Connection closed by 127.0.0.1 port 7890"), prefix)
            XCTAssertEqual(RepositoryStore.progressDetail("fatal: Could not read from remote repository."), guidance)
            XCTAssertNil(NetworkAuthenticationPolicy.prompt(for: GitError(diagnostic), endpoint: endpoint))
        }
        wait(for: [logged], timeout: 1)
    }

    func testLocalErrorsAndRecoveryDetailsUseTheSameTranslator() {
        let previous = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: L10n.preferenceKey) }
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        XCTAssertEqual(OperationFailure.display("Git operation timed out after 45 seconds."), "Git 操作在 45 秒后超时。")
        XCTAssertEqual(OperationFailure.display("Unknown rebase instruction on todo line 15"), "变基计划第 15 行包含未知指令。")
        XCTAssertEqual(OperationFailure.display("Unknown stash reference"), "找不到此贮藏引用。")
        XCTAssertEqual(OperationFailure.display("Invalid revision\nSaved changes remain in stash stash@{2}"),
                       "无效的版本。\n修改保留在贮藏 stash@{2} 中。")
        XCTAssertEqual(OperationFailure.display("Repository-specific hook detail"), "Repository-specific hook detail")
    }

}
