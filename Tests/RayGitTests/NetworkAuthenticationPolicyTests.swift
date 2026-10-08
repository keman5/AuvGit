import XCTest
@testable import RayGit
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
        XCTAssertNil(draft.credential)
        draft.secret = "token"
        guard case let .https(username, password)? = draft.credential else { return XCTFail("Expected HTTPS credential") }
        XCTAssertEqual(username, "alice")
        XCTAssertEqual(password, "token")
    }

    func testSSHDraftRequiresExistingPrivateKey() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("git@gitlab.example.com:group/project.git"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_ed25519")
        try Data("fixture".utf8).write(to: key)

        var draft = RemoteAuthenticationDraft(endpoint: endpoint, preferredUsername: nil)
        XCTAssertEqual(draft.username, "git")
        XCTAssertNil(draft.credential)
        draft.privateKey = key; draft.secret = "passphrase"
        guard case let .ssh(username, privateKey, passphrase)? = draft.credential else { return XCTFail("Expected SSH credential") }
        XCTAssertEqual(username, "git")
        XCTAssertEqual(privateKey.path, key.path)
        XCTAssertEqual(passphrase, "passphrase")
    }
}
