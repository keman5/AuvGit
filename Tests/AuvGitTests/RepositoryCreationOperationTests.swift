import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class RepositoryCreationOperationTests: XCTestCase {
    private var savedPreferences: [String: Any] = [:]
    override func setUp() async throws {
        try await super.setUp()
        for key in [CloneDestination.parentPreference, RepositoryCreationDraft.preference] {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
        }
    }
    override func tearDown() async throws {
        for key in [CloneDestination.parentPreference, RepositoryCreationDraft.preference] {
            UserDefaults.standard.set(savedPreferences[key], forKey: key)
        }
        savedPreferences.removeAll()
        try await super.tearDown()
    }
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
        store.creationOperation = operation
        operation.clone = true; operation.source = root.path; operation.destination = root.appendingPathComponent("clone").path
        operation.isPresented = true
        operation.create()
        XCTAssertFalse(operation.isPresented, "Submitting must close the form synchronously")
        operation.endPresentation()
        XCTAssertFalse(store.isBusy, "Cloning must not lock the current project")
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
        store.creationOperation = operation
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
        store.creationOperation = operation
        operation.clone = false
        operation.destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        operation.isPresented = true
        operation.create()
        try await settle(operation)
        XCTAssertFalse(operation.isPresented)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.operationLog.filter { $0.command.isEmpty && $0.operation == "Create Repository" }.count, 1)
    }

    func testCloneAllowsStagingAcrossProjectsAndNeverClearsAnotherOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second"), target = root.appendingPathComponent("clone")
        for url in [first, second] {
            _ = try await GitRepository.initialize(at: url)
            try "change".write(to: url.appendingPathComponent("change.txt"), atomically: true, encoding: .utf8)
        }
        let store = RepositoryStore(persistsSession: false)
        let projects = WorkspaceProjects(initial: store)
        defer { for session in projects.sessions { session.closeTransientSession() } }
        await store.open(first)
        var releaseClone: CheckedContinuation<Void, Never>?
        var releaseForeground: CheckedContinuation<Void, Never>?
        defer { releaseClone?.resume(); releaseForeground?.resume() }
        let operation = RepositoryCreationOperation(store: store) { _, _, target, _, _ in
            GitCommandLog.progress?(try XCTUnwrap(GitProgressParser.parse("Receiving objects: 50%")))
            await withCheckedContinuation { releaseClone = $0 }
            return try await GitRepository.initialize(at: target)
        }
        store.creationOperation = operation
        operation.clone = true; operation.source = first.path; operation.destination = target.path
        operation.create()
        let deadline = Date().addingTimeInterval(8)
        while releaseClone == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(releaseClone)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(operation.busy)
        XCTAssertNotNil(store.visibleProgress)
        store.stageSelection()
        while store.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let firstStatus = try await GitRepository(url: first).status()
        XCTAssertTrue(firstStatus.contains { $0.path == "change.txt" && $0.isStaged })
        await store.open(second)
        let other = projects.active
        other.stageSelection()
        while other.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let secondStatus = try await GitRepository(url: second).status()
        XCTAssertTrue(secondStatus.contains { $0.path == "change.txt" && $0.isStaged })
        store.operation("Held foreground") { _ in await withCheckedContinuation { releaseForeground = $0 } }
        while releaseForeground == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let foregroundID = store.currentUserOperationID
        releaseClone?.resume(); releaseClone = nil
        try await settle(operation)
        XCTAssertTrue(store.isBusy, "Finishing a clone cannot unlock another in-flight operation")
        XCTAssertEqual(store.currentUserOperationID, foregroundID)
        XCTAssertTrue(projects.active === other, "A background clone cannot replace the selected project")
        let cloneRecord = try XCTUnwrap(store.operationLog.first { $0.command.isEmpty && $0.operation == "Clone" })
        XCTAssertNotEqual(cloneRecord.operationID, foregroundID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(store.commands(for: cloneRecord).isEmpty)
        releaseForeground?.resume(); releaseForeground = nil
        while store.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isBusy)
    }

    func testExistingDestinationRequiresConfirmationAndKeepsOldContentsInTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        _ = try await GitRepository.initialize(at: source)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = target.appendingPathComponent("keep.txt")
        try "original contents".write(to: marker, atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        var starts = 0
        let trash = root.appendingPathComponent("trash")
        let operation = RepositoryCreationOperation(store: store, trashItem: {
            try FileManager.default.moveItem(at: $0, to: trash)
        }) { _, _, url, _, _ in
            starts += 1
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            return try await GitRepository.initialize(at: url)
        }
        store.creationOperation = operation
        operation.clone = true; operation.source = source.path; operation.destination = target.path
        operation.create()
        guard case .replace(let pending) = operation.prompt else { return XCTFail("Expected replacement confirmation") }
        XCTAssertEqual(pending.path, target.path)
        XCTAssertEqual(starts, 0)
        operation.prompt = nil // Cancel preserves every existing file.
        XCTAssertEqual(try String(contentsOf: marker), "original contents")
        operation.create()
        operation.prompt = nil // The alert dismisses before dispatching its action.
        operation.replaceAndCreate(target)
        try await settle(operation)
        XCTAssertEqual(starts, 1)
        XCTAssertNotNil(store.repository)
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("keep.txt")), "original contents")
    }

    func testFailedCloneOffersRetryAndPreservesSeparateAttemptLogs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        var starts = 0
        let operation = RepositoryCreationOperation(store: store) { _, _, url, _, _ in
            starts += 1
            if starts == 1 { throw GitError("fatal: unable to access remote: token=hidden-secret") }
            return try await GitRepository.initialize(at: url)
        }
        store.creationOperation = operation
        operation.clone = true; operation.source = "https://example.invalid/team/repo.git"; operation.destination = root.path
        operation.create()
        try await settle(operation)
        guard case .retry(let message) = operation.prompt else { return XCTFail("Expected retry prompt") }
        XCTAssertFalse(message.contains("hidden-secret"))
        XCTAssertFalse(operation.isPresented)
        operation.prompt = nil
        operation.create()
        try await settle(operation)
        XCTAssertEqual(starts, 2)
        let attempts = store.operationLog.filter { $0.command.isEmpty && $0.operation == "Clone" }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNotEqual(attempts.first?.operationID, attempts.last?.operationID)
        XCTAssertNil(operation.prompt)
        XCTAssertFalse(store.isBusy)
    }

    func testReplacementCannotMoveItsOwnCloneSourceToTrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRepository.initialize(at: root)
        let store = RepositoryStore(persistsSession: false)
        let operation = RepositoryCreationOperation(store: store) { _, _, _, _, _ in XCTFail("Must not clone after moving the source"); return GitRepository(url: root) }
        operation.clone = true; operation.source = root.path; operation.destination = root.path
        operation.replaceAndCreate(root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        guard case .retry = operation.prompt else { return XCTFail("Expected a safe failure prompt") }
        XCTAssertFalse(operation.busy)
    }
}
