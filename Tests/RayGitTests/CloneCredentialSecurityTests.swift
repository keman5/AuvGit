import XCTest
@testable import GitCore

final class CloneCredentialSecurityTests: XCTestCase {
    private let credential = HTTPSCloneCredential(username: "fixture-user", password: "fixture-secret", saveToKeychain: false)

    func testSSHCloneUsesSelectedKeyAndPortAndRedactsPassphraseOnFailure() async throws {
        let defaults = UserDefaults.standard, setting = "raygit.git.executablePath"
        let previous = defaults.object(forKey: setting)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            if let previous { defaults.set(previous, forKey: setting) } else { defaults.removeObject(forKey: setting) }
            try? FileManager.default.removeItem(at: directory)
        }
        let key = directory.appendingPathComponent("private key")
        try Data("fixture".utf8).write(to: key)
        let executable = directory.appendingPathComponent("git-fixture")
        let captured = directory.appendingPathComponent("ssh-command")
        try Data("#!/bin/sh\nprintf '%s' \"$GIT_SSH_COMMAND\" > '\(captured.path)'\n\"$SSH_ASKPASS\" >&2\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(executable.path, forKey: setting)
        func leases() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("raygit-ssh-") })
        }
        let before = try leases()
        do {
            _ = try await GitRepository.clone(source: "ssh://git@example.invalid:2223/group/repo.git", destination: directory.appendingPathComponent("clone"),
                sshCredential: .ssh(username: "git", privateKey: key, passphrase: "ssh-fixture-secret"))
            XCTFail("Fixture must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains("ssh-fixture-secret")) }
        let command = try String(contentsOf: captured, encoding: .utf8)
        XCTAssertTrue(command.contains(key.path))
        XCTAssertTrue(command.contains("-p 2223"))
        XCTAssertTrue(command.contains("IdentitiesOnly=yes"))
        XCTAssertFalse(command.contains("ssh-fixture-secret"))
        XCTAssertEqual(try leases(), before)
    }

    func testRejectsCredentialBearingOrAmbiguousURLsWithoutEchoingThem() throws {
        for source in ["https://user@example.invalid/repo", "https://user:secret@example.invalid/repo", "https://%75ser@example.invalid/repo", "https://example.invalid/repo?", "https://example.invalid/repo?token=secret", "https://example.invalid/repo#", "https://example.invalid/repo#secret", "http://example.invalid/repo", "https:///repo"] {
            do {
                let lease = try HTTPSCredentialLease(source: URL(string: source)!, credential: credential)
                lease.remove()
                XCTFail("Accepted an unsafe credential URL")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(source))
                XCTAssertFalse(error.localizedDescription.contains(credential.password))
            }
        }
    }

    func testRealHelperNormalizesCaseAndDefaultPortAndRejectsMalformedRequests() throws {
        let lease = try HTTPSCredentialLease(source: URL(string: "https://Example.invalid/repo")!, credential: credential)
        defer { lease.remove() }
        for host in ["example.invalid", "EXAMPLE.INVALID", "example.invalid:443"] {
            XCTAssertEqual(try invoke(lease, "get", "protocol=https\nhost=\(host)\n\n"), "username=fixture-user\npassword=fixture-secret\n\n")
        }
        for input in ["protocol=https\nhost=example.invalid:8443\n\n", "protocol=https\nhost=example.invalid.evil\n\n", "protocol=https\nhost=elsewhere.invalid\n\n", "protocol=https\nhost=example.invalid\nhost=elsewhere.invalid\n\n", "protocol=https\nhost=example.invalid\nbroken\n\n"] {
            XCTAssertEqual(try invoke(lease, "get", input), "")
        }
        XCTAssertEqual(try invoke(lease, "store", "protocol=https\nhost=example.invalid\n\n"), "")
        XCTAssertEqual(try invoke(lease, "erase", "protocol=https\nhost=example.invalid\n\n"), "")
    }

    func testNondefaultPortRemainsScopedAndCleanupIsIdempotent() throws {
        let lease = try HTTPSCredentialLease(source: URL(string: "https://example.invalid:8443/repo")!, credential: credential)
        XCTAssertFalse(lease.gitArguments.joined().contains(credential.password))
        XCTAssertEqual(try invoke(lease, "get", "protocol=https\nhost=example.invalid\n\n"), "")
        XCTAssertTrue(try invoke(lease, "get", "protocol=https\nhost=example.invalid:8443\n\n").contains("password="))
        lease.remove(); lease.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directoryURL.path))
    }

    func testPersistenceOnlyRunsOnMatchingStoreNeverOnGet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("keychain-fixture"), saved = directory.appendingPathComponent("saved")
        try Data("#!/bin/sh\n/bin/cat > '\(saved.path)'\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let lease = try HTTPSCredentialLease(source: URL(string: "https://example.invalid/repo")!, credential: .init(username: credential.username, password: credential.password, saveToKeychain: true), keychainHelper: helper)
        defer { lease.remove() }
        let request = "protocol=https\nhost=example.invalid\nusername=fixture-user\npassword=fixture-secret\n\n"
        _ = try invoke(lease, "get", request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        _ = try invoke(lease, "store", request.replacingOccurrences(of: "example.invalid", with: "other.invalid"))
        _ = try invoke(lease, "store", request.replacingOccurrences(of: "fixture-secret", with: "wrong-secret"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        _ = try invoke(lease, "store", request)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), request)
    }

    func testCloneFailureRedactsExactSecretAndRemovesLease() async throws {
        let defaults = UserDefaults.standard, key = "raygit.git.executablePath"
        let previous = defaults.object(forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("git-fixture")
        try Data("#!/bin/sh\nprintf 'failure echo fixture-secret' >&2\nexit 1\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defaults.set(executable.path, forKey: key)
        func leases() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("raygit-credential-") })
        }
        let before = try leases()
        let observer = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { notification in
            guard let record = notification.object as? GitCommandRecord, record.directory == directory.path else { return }
            XCTAssertFalse(record.command.contains("fixture-secret"))
            XCTAssertFalse(record.output.contains("fixture-secret"))
            XCTAssertFalse(record.error?.contains("fixture-secret") ?? false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        do {
            _ = try await GitRepository.clone(source: "https://example.invalid/repo", destination: directory.appendingPathComponent("clone"), credential: credential)
            XCTFail("Fixture must fail")
        } catch { XCTAssertFalse(error.localizedDescription.contains(credential.password)) }
        XCTAssertEqual(try leases(), before)
    }

    private func invoke(_ lease: HTTPSCredentialLease, _ operation: String, _ input: String) throws -> String {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = lease.helperURL; process.arguments = [operation]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8)); try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stderr.fileHandleForReading.readDataToEndOfFile().count, 0)
        return String(decoding: output, as: UTF8.self)
    }
}
