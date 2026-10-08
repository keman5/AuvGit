import XCTest
@testable import GitCore

final class HTTPSCloneCredentialTests: XCTestCase {
    func testOneShotHelperSuppliesCredentialsWithoutEmbeddingSecretsInArguments() async throws {
        let credential = HTTPSCloneCredential(
            username: "miaojiang-user",
            password: "private-token-value",
            saveToKeychain: false
        )
        let lease = try HTTPSCredentialLease(source: URL(string: "https://gitlab.example.invalid/group/project.git")!, credential: credential)
        defer { lease.remove() }

        let arguments = lease.gitArguments
        XCTAssertFalse(arguments.joined(separator: " ").contains(credential.username))
        XCTAssertFalse(arguments.joined(separator: " ").contains(credential.password))
        XCTAssertEqual(try permissions(at: lease.directoryURL), 0o700)
        XCTAssertEqual(try permissions(at: lease.credentialURL), 0o600)
        XCTAssertEqual(try permissions(at: lease.helperURL), 0o700)

        let input = lease.directoryURL.appendingPathComponent("request")
        try Data("protocol=https\nhost=gitlab.example.invalid\n\n".utf8).write(to: input)
        let output = try await GitProcess.run(
            at: lease.directoryURL,
            arguments: arguments + ["credential", "fill"],
            inputFile: input
        )

        XCTAssertTrue(output.text.contains("username=miaojiang-user"))
        XCTAssertTrue(output.text.contains("password=private-token-value"))
    }

    func testKeychainPersistenceIsExplicitAndCredentialInputRejectsLineBreaks() throws {
        let credential = HTTPSCloneCredential(username: "user", password: "token", saveToKeychain: true)
        let lease = try HTTPSCredentialLease(source: URL(string: "https://gitlab.example.invalid/group/project.git")!, credential: credential)
        defer { lease.remove() }

        XCTAssertEqual(Array(lease.gitArguments.prefix(2)), ["-c", "credential.https://gitlab.example.invalid.helper="])
        XCTAssertTrue(lease.gitArguments[3].hasPrefix("credential.https://gitlab.example.invalid.helper=!"))
        // Persistence is inside the scoped helper, never an unscoped second helper.
        XCTAssertEqual(lease.gitArguments.count, 4)
        XCTAssertThrowsError(try HTTPSCredentialLease(source: URL(string: "https://gitlab.example.invalid/group/project.git")!, credential: .init(
            username: "bad\nuser",
            password: "token",
            saveToKeychain: false
        )))
    }

    func testOneShotHelperDoesNotReleaseCredentialsToAnotherHost() async throws {
        let lease = try HTTPSCredentialLease(
            source: URL(string: "https://gitlab.example.invalid/group/project.git")!,
            credential: .init(username: "user", password: "private-token-value", saveToKeychain: false)
        )
        defer { lease.remove() }
        let input = lease.directoryURL.appendingPathComponent("other-host-request")
        try Data("protocol=https\nhost=redirected.example.invalid\n\n".utf8).write(to: input)

        do {
            _ = try await GitProcess.run(
                at: lease.directoryURL,
                arguments: lease.gitArguments + ["credential", "fill"],
                inputFile: input
            )
            XCTFail("Credential helper released credentials to another host")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-token-value"))
            XCTAssertTrue(error.localizedDescription.lowercased().contains("username"))
        }
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
