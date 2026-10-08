import XCTest
@testable import RayGit

final class CloneAuthenticationTests: XCTestCase {
    func testCredentialValidationUsesLocalizedGuidance() {
        let defaults = UserDefaults.standard, key = "appLanguage", previous = defaults.object(forKey: "appLanguage")
        defaults.set("zh-Hans", forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let message = "HTTPS credentials require a valid HTTPS clone URL."
        XCTAssertEqual(CloneAuthentication.classify(source: "https://example.invalid/repo", error: NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])), .other(workflowText(message)))
    }
    func testHTTPSAskpassFailureRequestsCredentialsWithoutRetainingRemote() {
        let error = NSError(domain: "Git", code: 128, userInfo: [
            NSLocalizedDescriptionKey: "error: unable to read askpass response from '/usr/bin/false'\nfatal: could not read Username for 'https://gitlab.example.invalid': terminal prompts disabled"
        ])

        XCTAssertEqual(
            CloneAuthentication.classify(source: "https://gitlab.example.invalid/group/project.git", error: error),
            .httpsCredentials
        )
    }

    func testSSHPublicKeyFailureReturnsSSHGuidance() {
        let error = NSError(domain: "Git", code: 128, userInfo: [
            NSLocalizedDescriptionKey: "git@gitlab.example.invalid: Permission denied (publickey)."
        ])

        XCTAssertEqual(
            CloneAuthentication.classify(source: "ssh://git@gitlab.example.invalid:2223/group/project.git", error: error),
            .sshKey
        )
    }

    func testUnrelatedFailurePreservesRedactedGitDiagnostic() {
        let error = NSError(domain: "Git", code: 128, userInfo: [
            NSLocalizedDescriptionKey: "fatal: repository 'https://secret-token@gitlab.example.invalid/group/missing.git' not found"
        ])

        XCTAssertEqual(
            CloneAuthentication.classify(source: "https://gitlab.example.invalid/group/missing.git", error: error),
            .other("fatal: repository '[remote] not found")
        )
    }
}
