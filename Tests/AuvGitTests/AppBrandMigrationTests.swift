import XCTest
@testable import AuvGit

final class AppBrandMigrationTests: XCTestCase {
    func testUpgradePreservesPathsAndExistingSettingsAndRunsOnce() throws {
        let suite = "AuvGit.BrandMigrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("dark", forKey: "preferences.theme")
        AppBrandMigration.migrate(defaults: defaults, legacy: [
            "preferences.theme": "light", "recentRepositories": ["/repos/raygit"],
            "RayGit.window": "saved-frame", "remoteCredential.ssh.path.account": "/keys/id_git"
        ])
        XCTAssertEqual(defaults.string(forKey: "preferences.theme"), "dark")
        XCTAssertEqual(defaults.stringArray(forKey: "recentRepositories"), ["/repos/raygit"])
        XCTAssertEqual(defaults.string(forKey: "AuvGit.window"), "saved-frame")
        XCTAssertEqual(defaults.string(forKey: "remoteCredential.ssh.path.account"), "/keys/id_git")
        defaults.removeObject(forKey: "recentRepositories")
        AppBrandMigration.migrate(defaults: defaults, legacy: ["recentRepositories": ["stale"]])
        XCTAssertNil(defaults.object(forKey: "recentRepositories"))
    }
}
