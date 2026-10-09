import XCTest
@testable import GitCore

final class RemoteAuthenticationTests: XCTestCase {
    func testParsesHTTPSAndNormalizesDefaultPort() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://User@GitLab.Example.com/group/project.git"))
        XCTAssertEqual(endpoint.transport, .https)
        XCTAssertEqual(endpoint.host, "gitlab.example.com")
        XCTAssertEqual(endpoint.port, 443)
        XCTAssertEqual(endpoint.username, "User")
        XCTAssertEqual(endpoint.identity(username: "account").storageKey, "https|gitlab.example.com|443|account")
    }

    func testParsesSSHURLAndSCPStyleRemote() throws {
        let url = try XCTUnwrap(RemoteEndpoint.parse("ssh://git@GitLab.Example.com:2222/group/project.git"))
        XCTAssertEqual(url.transport, .ssh)
        XCTAssertEqual(url.host, "gitlab.example.com")
        XCTAssertEqual(url.port, 2222)
        XCTAssertEqual(url.username, "git")

        let scp = try XCTUnwrap(RemoteEndpoint.parse("deploy@git.example.com:group/project.git"))
        XCTAssertEqual(scp.transport, .ssh)
        XCTAssertEqual(scp.host, "git.example.com")
        XCTAssertEqual(scp.port, 22)
        XCTAssertEqual(scp.username, "deploy")
    }

    func testHTTPSRemoteConvertsToStableSSHURL() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://GitLab.Example.com/group/project.git"))

        let standard = try XCTUnwrap(endpoint.convertingToSSH(username: "git", port: 22))
        XCTAssertEqual(standard.transport, .ssh)
        XCTAssertEqual(standard.host, "gitlab.example.com")
        XCTAssertEqual(standard.port, 22)
        XCTAssertEqual(standard.username, "git")
        XCTAssertEqual(standard.remoteURL, "ssh://git@gitlab.example.com/group/project.git")

        let custom = try XCTUnwrap(endpoint.convertingToSSH(username: "deploy", port: 2222))
        XCTAssertEqual(custom.remoteURL, "ssh://deploy@gitlab.example.com:2222/group/project.git")
        XCTAssertNil(endpoint.convertingToSSH(username: "bad\nuser", port: 22))
        XCTAssertNil(endpoint.convertingToSSH(username: "git", port: 0))
    }

    func testRejectsLocalAndUnsupportedRemotes() {
        XCTAssertNil(RemoteEndpoint.parse("../repository.git"))
        XCTAssertNil(RemoteEndpoint.parse("file:///tmp/repository.git"))
        XCTAssertNil(RemoteEndpoint.parse("http://example.com/repository.git"))
        XCTAssertNil(RemoteEndpoint.parse("git@example.com"))
    }

    func testRepositoryResolvesEffectivePushRemoteAfterURLRewrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["remote", "add", "origin", "https://gitlab.example.com/group/project.git"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "url.ssh://deploy@gitlab.example.com:2222/.insteadOf", "https://gitlab.example.com/"])

        let target = try await GitRepository(url: root).remoteAuthenticationTarget(for: .push)

        XCTAssertEqual(target.remoteName, "origin")
        XCTAssertEqual(target.endpoint.transport, .ssh)
        XCTAssertEqual(target.endpoint.host, "gitlab.example.com")
        XCTAssertEqual(target.endpoint.port, 2222)
        XCTAssertEqual(target.endpoint.username, "deploy")
        XCTAssertFalse(target.usesPushURL)
    }

    func testRepositoryDistinguishesExplicitPushURL() async throws {
        let root = try await repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["remote", "add", "origin", "https://gitlab.example.com/group/fetch.git"])
        _ = try await GitProcess.run(at: root, arguments: ["remote", "set-url", "--push", "origin", "https://gitlab.example.com/group/push.git"])

        let target = try await GitRepository(url: root).remoteAuthenticationTarget(for: .push)

        XCTAssertTrue(target.usesPushURL)
        XCTAssertEqual(target.endpoint.remoteURL, "https://gitlab.example.com/group/push.git")
    }

    func testSSHMigrationDoesNotChangeRemoteWhenVerificationFails() async throws {
        let root = try await repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "https://gitlab.example.com/group/project.git"
        _ = try await GitProcess.run(at: root, arguments: ["remote", "add", "origin", original])
        let key = root.appendingPathComponent("id_ed25519")
        try Data("fixture".utf8).write(to: key)
        let repository = GitRepository(url: root)
        let plan = try await repository.remoteSSHMigrationPlan(for: .push, username: "git", port: 22)

        do {
            try await repository.migrateRemoteToSSH(plan, credential: .ssh(username: "git", privateKey: key, passphrase: nil)) { _, _ in
                throw GitError("authentication rejected")
            }
            XCTFail("Expected verification failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("authentication rejected"))
        }

        let configured = try await GitProcess.run(at: root, arguments: ["config", "--get", "remote.origin.url"])
        XCTAssertEqual(configured.text.trimmingCharacters(in: .newlines), original)
    }

    func testSSHMigrationChangesExactRemoteAfterVerificationSucceeds() async throws {
        let root = try await repositoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetch = "https://gitlab.example.com/group/fetch.git"
        let push = "https://gitlab.example.com/group/push.git"
        _ = try await GitProcess.run(at: root, arguments: ["remote", "add", "origin", fetch])
        _ = try await GitProcess.run(at: root, arguments: ["remote", "set-url", "--push", "origin", push])
        let key = root.appendingPathComponent("id_ed25519")
        try Data("fixture".utf8).write(to: key)
        let repository = GitRepository(url: root)
        let plan = try await repository.remoteSSHMigrationPlan(for: .push, username: "deploy", port: 2222)
        var verifiedURL = ""

        try await repository.migrateRemoteToSSH(plan, credential: .ssh(username: "deploy", privateKey: key, passphrase: nil)) { endpoint, _ in
            verifiedURL = endpoint.remoteURL
        }

        XCTAssertEqual(verifiedURL, "ssh://deploy@gitlab.example.com:2222/group/push.git")
        let configuredFetch = try await GitProcess.run(at: root, arguments: ["config", "--get", "remote.origin.url"])
        let configuredPush = try await GitProcess.run(at: root, arguments: ["config", "--get", "remote.origin.pushurl"])
        XCTAssertEqual(configuredFetch.text.trimmingCharacters(in: .newlines), fetch)
        XCTAssertEqual(configuredPush.text.trimmingCharacters(in: .newlines), verifiedURL)
    }

    func testSSHCredentialLeaseUsesPrivateKeyAndProtectsPassphrase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id key")
        try Data("private-key-fixture".utf8).write(to: key)
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("ssh://git@example.com:2222/group/project.git"))
        let passphrase = "secret passphrase"

        let lease = try NetworkCredentialLease(endpoint: endpoint, credential: .ssh(
            username: "deploy", privateKey: key, passphrase: passphrase
        ))
        defer { lease.remove() }

        XCTAssertTrue(lease.gitArguments.isEmpty)
        XCTAssertTrue(try XCTUnwrap(lease.environment["GIT_SSH_COMMAND"]).contains("IdentitiesOnly=yes"))
        XCTAssertTrue(try XCTUnwrap(lease.environment["GIT_SSH_COMMAND"]).contains("2222"))
        XCTAssertFalse(lease.gitArguments.joined(separator: " ").contains(passphrase))
        XCTAssertFalse(lease.environment.values.joined(separator: " ").contains(passphrase))
        XCTAssertEqual(lease.privateValues, [passphrase])
        XCTAssertEqual(try permissions(at: try XCTUnwrap(lease.directoryURL)), 0o700)
        XCTAssertEqual(try permissions(at: try XCTUnwrap(lease.secretURL)), 0o600)
        XCTAssertEqual(try permissions(at: try XCTUnwrap(lease.askpassURL)), 0o700)

        let process = Process(), output = Pipe()
        process.executableURL = try XCTUnwrap(lease.askpassURL)
        process.standardOutput = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), passphrase)
    }

    func testCredentialLeaseCleanupIsIdempotent() throws {
        let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://example.com/project.git"))
        let lease = try NetworkCredentialLease(endpoint: endpoint, credential: .https(username: "user", password: "token"))
        let directory = try XCTUnwrap(lease.directoryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        lease.remove(); lease.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func repositoryFixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        return root
    }
}
