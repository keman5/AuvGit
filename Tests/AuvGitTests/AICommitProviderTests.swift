import XCTest
@testable import AuvGit

final class AICommitProviderTests: XCTestCase {
    func testAPIBaseURLAppendsChatCompletionsWithoutDuplicatingV1() throws {
        let url = try AICommitAPI.endpointURL(from: "https://example.test/proxy/v1/")
        XCTAssertEqual(url.absoluteString, "https://example.test/proxy/v1/chat/completions")
    }

    func testFullChatCompletionsURLRemainsUnchanged() throws {
        let url = try AICommitAPI.endpointURL(from: "https://example.test/proxy/v1/chat/completions")
        XCTAssertEqual(url.absoluteString, "https://example.test/proxy/v1/chat/completions")
    }

    func testAPIErrorIncludesStatusAndServerMessage() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://example.test/v1/chat/completions")!,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let data = Data(#"{"error":{"message":"Service temporarily unavailable","type":"api_error"}}"#.utf8)

        XCTAssertThrowsError(try AICommitAPI.message(from: data, response: response)) { error in
            XCTAssertEqual(error.localizedDescription, "API request failed (503): Service temporarily unavailable")
        }
    }

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
