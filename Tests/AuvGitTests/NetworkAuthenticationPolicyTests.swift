import XCTest
@testable import AuvGit
@testable import GitCore

final class NetworkAuthenticationPolicyTests: XCTestCase {
    func testHTTPSPromptRequiresHTTPSAuthenticationFailure() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://gitlab.example.com/group/project.git"))
        let authentication = GitError("fatal: could not read Username for 'https://gitlab.example.com': terminal prompts disabled")
        XCTAssertEqual(NetworkAuthenticationPolicy.prompt(for: authentication, endpoint: endpoint), .https)

        let connection = GitError("fatal: unable to access: Could not resolve host: gitlab.example.com")
        XCTAssertNil(NetworkAuthenticationPolicy.prompt(for: connection, endpoint: endpoint))
    }

    func testSSHPromptRequiresPublicKeyFailure() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("git@gitlab.example.com:group/project.git"))
        let authentication = GitError("git@gitlab.example.com: Permission denied (publickey).")
        XCTAssertEqual(NetworkAuthenticationPolicy.prompt(for: authentication, endpoint: endpoint), .ssh)

        let hostKey = GitError("Host key verification failed.")
        XCTAssertNil(NetworkAuthenticationPolicy.prompt(for: hostKey, endpoint: endpoint))
    }

    func testProtocolMismatchDoesNotOfferWrongForm() throws {
        let ssh = try XCTUnwrap(RemoteEndpoint.parse("git@gitlab.example.com:group/project.git"))
        let httpsFailure = GitError("fatal: could not read Username: terminal prompts disabled")
        XCTAssertNil(NetworkAuthenticationPolicy.prompt(for: httpsFailure, endpoint: ssh))
    }

    func testHTTPSDraftRequiresUsernameAndSecret() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://gitlab.example.com/group/project.git"))
        var draft = RemoteAuthenticationDraft(endpoint: endpoint, preferredUsername: "alice")
        XCTAssertEqual(draft.method, .accessToken)
        XCTAssertNil(draft.submission)
        draft.token = "token"
        guard case let .https(username, password)? = draft.submission?.credential else { return XCTFail("Expected HTTPS credential") }
        XCTAssertEqual(username, "alice")
        XCTAssertEqual(password, "token")

        draft.method = .accountPassword
        XCTAssertNil(draft.submission)
        draft.password = "password"
        guard case let .https(passwordUsername, accountPassword)? = draft.submission?.credential else { return XCTFail("Expected password credential") }
        XCTAssertEqual(passwordUsername, "alice")
        XCTAssertEqual(accountPassword, "password")
    }

    func testSSHDraftRequiresExistingPrivateKey() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("git@gitlab.example.com:group/project.git"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_ed25519")
        try Data("fixture".utf8).write(to: key)

        var draft = RemoteAuthenticationDraft(endpoint: endpoint, preferredUsername: nil)
        XCTAssertEqual(draft.method, .sshPrivateKey)
        XCTAssertEqual(draft.sshUsername, "git")
        XCTAssertNil(draft.submission)
        draft.privateKey = key; draft.passphrase = "passphrase"; draft.sshPort = "2222"
        guard let submission = draft.submission,
              case let .ssh(username, privateKey, passphrase) = submission.credential else { return XCTFail("Expected SSH credential") }
        XCTAssertEqual(username, "git")
        XCTAssertEqual(privateKey.path, key.path)
        XCTAssertEqual(passphrase, "passphrase")
        XCTAssertEqual(submission.sshPort, 2222)
    }

    func testHTTPSDraftCanChooseSSHWithoutReusingHTTPSSecrets() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://gitlab.example.com/group/project.git"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_ed25519")
        try Data("fixture".utf8).write(to: key)
        var draft = RemoteAuthenticationDraft(endpoint: endpoint, preferredUsername: "alice")
        draft.token = "token-value"
        draft.method = .sshPrivateKey
        draft.privateKey = key

        guard let submission = draft.submission,
              case let .ssh(username, _, passphrase) = submission.credential else { return XCTFail("Expected SSH credential") }
        XCTAssertEqual(username, "git")
        XCTAssertNil(passphrase)
    }

    func testSSHRemoteRejectsHTTPSCredentialMethods() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("ssh://git@gitlab.example.com/group/project.git"))
        var draft = RemoteAuthenticationDraft(endpoint: endpoint, preferredUsername: "git")

        draft.method = .accessToken
        draft.httpsUsername = "alice"
        draft.token = "token"
        XCTAssertNil(draft.submission)

        draft.method = .accountPassword
        draft.password = "password"
        XCTAssertNil(draft.submission)
    }

    func testRemoteMigrationRetryRequiresFreshPushPreparation() throws {
        let key = FileManager.default.temporaryDirectory.appendingPathComponent("id_ed25519")
        let context = RemoteAuthenticationRetryContext(
            credential: .ssh(username: "git", privateKey: key, passphrase: nil),
            saveCredential: false,
            remoteChanged: true
        )

        XCTAssertTrue(context.acceptsMigratedPushIdentity)
        XCTAssertTrue(context.requiresFreshForcePushPreparation)
    }
}
