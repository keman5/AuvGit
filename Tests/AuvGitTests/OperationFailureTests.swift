import XCTest
@testable import AuvGit

final class OperationFailureTests: XCTestCase {
    @MainActor
    func testBridgePreservesRepositoryAndRedactsSecret() {
        let repository = URL(fileURLWithPath: "/tmp/test-repository")
        let delivered = expectation(description: "Failure bridge")
        let observer = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { notification in
            guard let event = notification.object as? OperationFailure.Event else { return }
            XCTAssertEqual(event.repository, repository)
            XCTAssertFalse(event.message.contains("private-token"))
            delivered.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "token=private-token"])
        XCTAssertFalse(OperationFailure.message(error, repository: repository).contains("private-token"))
        wait(for: [delivered], timeout: 1)
    }
    func testCancellationIsNotPublishedAsFailure() {
        let notDelivered = expectation(description: "Cancellation remains quiet")
        notDelivered.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: OperationFailure.notification, object: nil, queue: nil) { _ in notDelivered.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = OperationFailure.message(CancellationError())
        wait(for: [notDelivered], timeout: 0.05)
    }
}
