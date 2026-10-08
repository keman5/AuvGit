import XCTest
@testable import RayGit

final class AICommitProviderTests: XCTestCase {
    func testIsolatedProviderKeepsBearerAuthenticationWithoutLoadingTools() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try """
        model_provider = "custom"
        [model_providers.custom]
        base_url = "https://example.test/v1"
        experimental_bearer_token = "test-only-token"
        requires_openai_auth = false
        wire_api = "responses"
        [model_providers.unselected]
        experimental_bearer_token = "other-token"
        [mcp_servers.untrusted]
        command = "do-not-load"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let config = try XCTUnwrap(AICommitCLI.isolatedProviderConfig(from: home))
        XCTAssertTrue(config.contains("experimental_bearer_token = \"test-only-token\""))
        XCTAssertTrue(config.contains("requires_openai_auth = false"))
        XCTAssertFalse(config.contains("other-token"))
        XCTAssertFalse(config.contains("mcp_servers"))
        XCTAssertFalse(config.contains("do-not-load"))
    }
}
