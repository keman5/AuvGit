import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class RepositoryCreationOperationTests: XCTestCase {
    private func settle(_ operation: RepositoryCreationOperation) async throws {
        for _ in 0..<500 {
            if !operation.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Background creation did not finish")
    }

    func testSubmissionClosesFormBeforeCloneCompletesAndReportsResult() async throws {
        let defaults = UserDefaults.standard, previousParent = UserDefaults.standard.object(forKey: CloneDestination.parentPreference)
        defer {
            if let previousParent { defaults.set(previousParent, forKey: CloneDestination.parentPreference) }
            else { defaults.removeObject(forKey: CloneDestination.parentPreference) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try await GitRepository.initialize(at: root)
        let store = RepositoryStore(persistsSession: false)
        var release: CheckedContinuation<Void, Never>?
        var starts = 0
        let operation = RepositoryCreationOperation(store: store) { _, _, _, _, _ in
            starts += 1
            await withCheckedContinuation { release = $0 }
            return repository
        }
        operation.clone = true; operation.source = root.path; operation.destination = root.path
        operation.isPresented = true
        operation.create()
        XCTAssertFalse(operation.isPresented, "Submitting must close the form synchronously")
        operation.endPresentation()
        XCTAssertTrue(store.isBusy)
        operation.create() // A second click cannot enqueue another clone.
        for _ in 0..<500 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(starts, 1)
        XCTAssertNotNil(release)
        XCTAssertFalse(operation.isPresented, "No sheet is needed while Git is running")
        release?.resume()
        try await settle(operation)
        XCTAssertEqual(store.repositoryURL?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(store.operationLog.filter { $0.command.isEmpty && $0.operation == "Clone" }.count, 1)
        XCTAssertFalse(store.isBusy)
    }

    func testAuthenticationFailureReopensOnlyForInputAndRetryClosesAgain() async throws {
        let store = RepositoryStore(persistsSession: false)
        let operation = RepositoryCreationOperation(store: store) { _, _, _, _, _ in
            throw GitError("fatal: could not read Username for 'https://example.invalid': terminal prompts disabled")
        }
        operation.clone = true; operation.source = "https://example.invalid/team/repo.git"
        operation.destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        operation.isPresented = true
        operation.create()
        XCTAssertFalse(operation.isPresented)
        try await settle(operation)
        XCTAssertTrue(operation.authenticationRequested)
        XCTAssertTrue(operation.isPresented)
        XCTAssertFalse(store.isBusy)
        operation.username = "tester"; operation.password = "test-token"
        operation.create()
        XCTAssertFalse(operation.isPresented)
        try await settle(operation)
        XCTAssertTrue(operation.password.isEmpty)
        XCTAssertEqual(store.operationLog.filter { $0.command.isEmpty && $0.operation == "Clone" }.count, 2)
    }

    func testOrdinaryFailureStaysClosedAndAppearsInMainWindow() async throws {
        let store = RepositoryStore(persistsSession: false)
        let operation = RepositoryCreationOperation(store: store) { _, _, _, _, _ in throw GitError("Destination already exists") }
        operation.clone = false
        operation.destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        operation.isPresented = true
        operation.create()
        try await settle(operation)
        XCTAssertFalse(operation.isPresented)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.operationLog.filter { $0.command.isEmpty && $0.operation == "Create Repository" }.count, 1)
    }
}
