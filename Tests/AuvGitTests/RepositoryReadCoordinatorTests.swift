import XCTest
@testable import AuvGit

final class RepositoryReadCoordinatorTests: XCTestCase {
    actor Gate {
        var starts = 0
        var cancelled = false
        private var continuation: CheckedContinuation<Void, Never>?
        func read() async throws -> Int {
            starts += 1
            await withCheckedContinuation { continuation = $0 }
            cancelled = Task.isCancelled
            try Task.checkCancellation()
            return 42
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor
    func testConcurrentConsumersShareWorkAndCancellationIsIndependent() async throws {
        let pool = InFlightReadPool<String, Int>()
        let gate = Gate()
        let first = Task { try await pool.value(for: "repo") { try await gate.read() } }
        let second = Task { try await pool.value(for: "repo") { try await gate.read() } }
        try await waitUntil {
            let starts = await gate.starts
            return pool.pendingConsumerCount == 2 && starts == 1
        }
        let starts = await gate.starts
        XCTAssertEqual(starts, 1)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled consumer must return before the shared worker finishes") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release()
        let value = try await second.value
        XCTAssertEqual(value, 42)
        let cancelled = await gate.cancelled
        XCTAssertFalse(cancelled)
        // Finished work is never reused as a cache.
        let fresh = try await pool.value(for: "repo") { 99 }
        XCTAssertEqual(fresh, 99)
    }

    @MainActor
    func testFinalCancellationCancelsWorkerAndAllowsFreshRead() async throws {
        let pool = InFlightReadPool<String, Int>()
        let gate = Gate()
        let consumer = Task { try await pool.value(for: "repo") { try await gate.read() } }
        try await waitUntil {
            let starts = await gate.starts
            return pool.pendingConsumerCount == 1 && starts == 1
        }
        consumer.cancel()
        _ = await consumer.result
        let fresh = try await pool.value(for: "repo") { 7 }
        XCTAssertEqual(fresh, 7)
        await gate.release()
        try await waitUntil { await gate.cancelled }
        let cancelled = await gate.cancelled
        XCTAssertTrue(cancelled)
    }

    @MainActor
    func testInvalidationCancelsMatchingConsumersOnly() async throws {
        let pool = InFlightReadPool<String, Int>()
        let a = Gate(), b = Gate()
        let first = Task { try await pool.value(for: "a") { try await a.read() } }
        let second = Task { try await pool.value(for: "b") { try await b.read() } }
        try await waitUntil {
            let aStarts = await a.starts, bStarts = await b.starts
            return pool.pendingConsumerCount == 2 && aStarts == 1 && bStarts == 1
        }
        pool.cancel { $0 == "a" }
        do { _ = try await first.value; XCTFail("Invalidation must cancel waiting consumers") }
        catch { XCTAssertTrue(error is CancellationError) }
        await a.release()
        await b.release()
        let value = try await second.value
        XCTAssertEqual(value, 42)
    }

    @MainActor
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Timed out waiting for shared read state"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
