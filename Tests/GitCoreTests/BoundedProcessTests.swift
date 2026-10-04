import XCTest
@testable import GitCore

final class BoundedProcessTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data().write(to: url.appendingPathComponent("input")); return url
    }
    func testSuccessfulProviderExit() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let status = try await BoundedProcess().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], directory: url, environment: [:], input: url.appendingPathComponent("input"), timeout: 2)
        XCTAssertEqual(status, 0)
    }
    func testHungProviderTimesOut() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await BoundedProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: url, environment: [:], input: url.appendingPathComponent("input"), timeout: 0.05)
            XCTFail("Expected deadline")
        } catch BoundedProcessError.timedOut {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testCancellationStopsProvider() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let operation = Task { try await BoundedProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: url, environment: [:], input: url.appendingPathComponent("input"), timeout: 3) }
        try await Task.sleep(nanoseconds: 50_000_000); operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
