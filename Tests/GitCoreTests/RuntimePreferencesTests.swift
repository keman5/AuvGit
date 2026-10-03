import XCTest
@testable import GitCore

final class RuntimePreferencesTests: XCTestCase {
    func testIsolatedPreferencesAndReset() throws {
        let suite = "raygit.tests.preferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GitRuntimePreferences(defaults: defaults)
        XCTAssertEqual(settings.executablePath, "/usr/bin/git")
        XCTAssertEqual(settings.timeout, 120)
        XCTAssertTrue(settings.fetchPrune)
        XCTAssertThrowsError(try settings.setGit(path: "git", timeout: 120, cleanup: "default"))
        XCTAssertThrowsError(try settings.setGit(path: "/usr/bin/git", timeout: 0, cleanup: "default"))
        try settings.setGit(path: "/usr/bin/git", timeout: 30, cleanup: "strip")
        XCTAssertEqual(settings.timeout, 30)
        XCTAssertEqual(settings.commitCleanup, "strip")
        settings.resetGit()
        XCTAssertEqual(settings.commitCleanup, "default")
    }
    func testProxyValidationAndEnvironmentPrecedence() throws {
        let suite = "raygit.tests.network." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GitRuntimePreferences(defaults: defaults)
        XCTAssertThrowsError(try settings.setNetwork(mode: "manual", proxy: "https://user:secret@proxy:8080", ssh: "", prune: true))
        try settings.setNetwork(mode: "manual", proxy: "http://localhost:8080", ssh: "ssh -oBatchMode=yes", prune: false)
        let env = settings.environment(["HTTPS_PROXY": "old", "GIT_SSH_COMMAND": "existing", "KEEP": "yes"])
        XCTAssertNil(env["HTTPS_PROXY"])
        XCTAssertEqual(env["https_proxy"], "http://localhost:8080")
        XCTAssertEqual(env["GIT_SSH_COMMAND"], "existing")
        XCTAssertEqual(env["KEEP"], "yes")
        XCTAssertFalse(settings.fetchPrune)
        try settings.setNetwork(mode: "off", proxy: "", ssh: "", prune: true)
        XCTAssertNil(settings.environment(["all_proxy": "old"])["all_proxy"])
        settings.resetNetwork()
        XCTAssertEqual(settings.proxyMode, "inherit")
    }
    func testGitExecutableValidation() async throws {
        let version = try await GitRuntimePreferences.validateExecutable("/usr/bin/git")
        XCTAssertTrue(version.hasPrefix("git version "))
        do { _ = try await GitRuntimePreferences.validateExecutable("/usr/bin/true"); XCTFail("Non-Git executable accepted") } catch {}
    }
    func testExplicitGlobalConfigurationFilePreservesOtherSettings() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "[user]\n\tname = Original\n[custom]\n\tuntouched = yes\n".write(to: file, atomically: true, encoding: .utf8)
        let original = try await GlobalGitConfiguration.load(configFile: file)
        var edited = original; edited.name = "Changed"; edited.email = "test@example.invalid"; edited.signCommits = "true"
        try await edited.apply(changedFrom: original, configFile: file)
        let loaded = try await GlobalGitConfiguration.load(configFile: file)
        XCTAssertEqual(loaded.name, "Changed")
        XCTAssertEqual(loaded.email, "test@example.invalid")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("untouched = yes"))
        edited = loaded; edited.email = ""
        try await edited.apply(changedFrom: loaded, configFile: file)
        let removed = try await GlobalGitConfiguration.load(configFile: file)
        XCTAssertEqual(removed.email, "")
        edited.signCommits = "invalid"
        do { try await edited.apply(changedFrom: removed, configFile: file); XCTFail("Invalid boolean accepted") } catch {}
    }

}
