import XCTest
@testable import AuvGit
@testable import GitCore

private final class MemoryRemoteKeychain: RemoteKeychainClient {
    var values: [String: String] = [:]
    func read(service: String, account: String) throws -> String? { values[service + "\0" + account] }
    func write(_ value: String, service: String, account: String) throws { values[service + "\0" + account] = value }
    func delete(service: String, account: String) throws { values.removeValue(forKey: service + "\0" + account) }
}

final class RemoteCredentialStoreTests: XCTestCase {
    func testLegacyCredentialsRemainReadableAndNewCredentialsTakePriority() throws {
        let suite = "AuvGit.LegacyCredentials." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MemoryRemoteKeychain(), store = RemoteCredentialStore(defaults: defaults, keychain: keychain)
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://gitlab.example.com/group/project.git"))
        let account = endpoint.identity(username: "alice").storageKey
        try keychain.write("legacy-token", service: "com.raygit.remote-auth.https", account: account)
        guard case let .https(_, legacy)? = try store.load(for: endpoint, username: "alice") else {
            return XCTFail("Expected legacy credential")
        }
        XCTAssertEqual(legacy, "legacy-token")
        try store.save(.https(username: "alice", password: "new-token"), for: endpoint)
        guard case let .https(_, current)? = try store.load(for: endpoint, username: "alice") else {
            return XCTFail("Expected current credential")
        }
        XCTAssertEqual(current, "new-token")
        XCTAssertEqual(keychain.values["com.auvgit.remote-auth.https\0" + account], "new-token")
    }

    func testHTTPSCredentialsAreScopedByEndpointAndUsername() throws {
        let suite = "RemoteCredentialStoreTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MemoryRemoteKeychain(), store = RemoteCredentialStore(defaults: defaults, keychain: keychain)
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://gitlab.example.com/group/project.git"))

        try store.save(.https(username: "alice", password: "alice-token"), for: endpoint)
        try store.save(.https(username: "bob", password: "bob-token"), for: endpoint)

        XCTAssertEqual(store.preferredUsername(for: endpoint), "bob")
        guard case let .https(username, password)? = try store.load(for: endpoint, username: "alice") else {
            return XCTFail("Expected saved HTTPS credential")
        }
        XCTAssertEqual(username, "alice")
        XCTAssertEqual(password, "alice-token")
        XCTAssertNotEqual(keychain.values.count, 1)
    }

    func testSSHCredentialStoresKeyBookmarkPathAndOptionalPassphrase() throws {
        let suite = "RemoteCredentialStoreTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MemoryRemoteKeychain(), store = RemoteCredentialStore(defaults: defaults, keychain: keychain)
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("ssh://git@gitlab.example.com:2222/group/project.git"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_ed25519")
        try Data("fixture".utf8).write(to: key)

        try store.save(.ssh(username: "git", privateKey: key, passphrase: "key-secret"), for: endpoint)

        guard case let .ssh(username, restoredKey, passphrase)? = try store.load(for: endpoint, username: "git") else {
            return XCTFail("Expected saved SSH credential")
        }
        XCTAssertEqual(username, "git")
        XCTAssertEqual(restoredKey.standardizedFileURL.path, key.standardizedFileURL.path)
        XCTAssertEqual(passphrase, "key-secret")
        XCTAssertNotNil(defaults.data(forKey: store.bookmarkKey(endpoint.identity(username: "git"))))
        XCTAssertEqual(defaults.string(forKey: store.pathKey(endpoint.identity(username: "git"))), key.path)
    }
}
