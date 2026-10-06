import XCTest
@testable import GitCore

private final class ForcePushCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
final class GuardedForcePushTests: XCTestCase {
    private struct Fixture { let root: URL; let bare: URL; let local: GitRepository; let other: GitRepository }
    private func commit(_ repo: GitRepository, _ name: String) async throws -> String {
        try name.write(to: repo.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await repo.stage(paths: [name]); try await repo.commit(message: name)
        return try await repo.workflowRevision("HEAD")
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bare = root.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", "-b", "main", bare.path])
        let localURL = root.appendingPathComponent("local"), otherURL = root.appendingPathComponent("other")
        _ = try await GitProcess.run(at: root, arguments: ["clone", bare.path, localURL.path])
        let local = GitRepository(url: localURL)
        for pair in [["user.name", "Test"], ["user.email", "test@example.invalid"], ["commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: localURL, arguments: ["config"] + pair) }
        _ = try await commit(local, "base")
        _ = try await GitProcess.run(at: localURL, arguments: ["push", "-u", "origin", "main"])
        _ = try await GitProcess.run(at: root, arguments: ["clone", bare.path, otherURL.path])
        for pair in [["user.name", "Test"], ["user.email", "test@example.invalid"], ["commit.gpgsign", "false"]] { _ = try await GitProcess.run(at: otherURL, arguments: ["config"] + pair) }
        let other = GitRepository(url: otherURL)
        _ = try await commit(local, "local-change")
        _ = try await commit(other, "remote-change")
        try await other.push()
        _ = try await GitProcess.run(at: localURL, arguments: ["fetch", "origin"])
        return Fixture(root: root, bare: bare, local: local, other: other)
    }
    private func remoteHead(_ fixture: Fixture) async throws -> String {
        try await GitRepository(url: fixture.bare).workflowRevision("refs/heads/main")
    }
    func testPreparationIsReadOnlyAndConfirmedPushPinsLeaseAndUpdatesTracking() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await remoteHead(f)
        let capture = ForcePushCommandCapture()
        let observer = NotificationCenter.default.addObserver(forName: GitCommandLog.notification, object: nil, queue: nil) { event in
            if let record = event.object as? GitCommandRecord, record.directory == f.local.url.path { capture.append(record.command) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let preview = try await f.local.prepareForcePush()
        XCTAssertEqual(preview.remote, "origin"); XCTAssertEqual(preview.remoteBranch, "refs/heads/main")
        XCTAssertEqual(preview.remoteCommit, before); XCTAssertEqual(preview.remoteOnlyCount, 1)
        let unchanged = try await remoteHead(f); XCTAssertEqual(unchanged, before)
        let result = try await f.local.forcePush(preview, progress: { _ in })
        XCTAssertTrue(result.output.contains("forced update"))
        let pushed = try await remoteHead(f), tracked = try await f.local.workflowRevision("refs/remotes/origin/main")
        XCTAssertEqual(pushed, preview.localCommit); XCTAssertEqual(tracked, pushed)
        let forceCommand = try XCTUnwrap(capture.commands.first { $0.contains("--force-with-lease=") })
        XCTAssertTrue(forceCommand.contains("'--force-with-lease=refs/heads/main:" + before + "'"))
        XCTAssertTrue(forceCommand.contains("'" + preview.localCommit + ":refs/heads/main'"))
        XCTAssertTrue(forceCommand.contains("'--recurse-submodules=no'")); XCTAssertTrue(forceCommand.contains("'--no-follow-tags'"))
        XCTAssertFalse(forceCommand.contains("'--force'"))
    }
    func testChangedRemoteIsRejectedEvenAfterTrackingRefRefresh() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = try await f.local.prepareForcePush()
        let advanced = try await commit(f.other, "later-remote-change")
        try await f.other.push()
        _ = try await GitProcess.run(at: f.local.url, arguments: ["fetch", "origin"])
        do { _ = try await f.local.forcePush(preview, progress: { _ in }); XCTFail("Exact remote lease must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("stale info")) }
        let head = try await remoteHead(f); XCTAssertEqual(head, advanced)
    }
    func testChangedHEADOrConfigurationInvalidatesConfirmation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = try await f.local.prepareForcePush()
        _ = try await commit(f.local, "later-local-change")
        do { _ = try await f.local.forcePush(preview, progress: { _ in }); XCTFail("Changed HEAD must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed")) }
        let next = try await f.local.prepareForcePush()
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "remote.pushDefault", "different"])
        do { _ = try await f.local.forcePush(next, progress: { _ in }); XCTFail("Changed config must reject") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed")) }
        let head = try await remoteHead(f); XCTAssertEqual(head, preview.remoteCommit)
    }
    func testPushRemotePrecedenceExplicitForceAndAmbiguousEndpointRefusal() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.local.url, arguments: ["remote", "add", "destination", f.bare.path])
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "remote.pushDefault", "destination"])
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "push.default", "current"])
        var preview = try await f.local.prepareForcePush()
        XCTAssertEqual(preview.remote, "destination")
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "branch.main.pushRemote", "origin"])
        preview = try await f.local.prepareForcePush(); XCTAssertEqual(preview.remote, "origin")
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "branch.main.pushRemote", "destination"])
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "remote.destination.push", "+refs/heads/main:refs/heads/main"])
        preview = try await f.local.prepareForcePush()
        XCTAssertEqual(preview.remoteBranch, "refs/heads/main")
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "--add", "remote.destination.pushurl", f.bare.path])
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "--add", "remote.destination.pushurl", f.bare.path])
        do { _ = try await f.local.prepareForcePush(); XCTFail("Multiple endpoints must not be confirmed") }
        catch ForcePushPreparationError.unsupportedForce {} catch { XCTFail("Unsafe fallback error: \(error)") }
    }
    func testMultipleForcedTargetsAndDetachedBranchStopInsteadOfOrdinaryFallback() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await remoteHead(f)
        _ = try await GitProcess.run(at: f.bare, arguments: ["update-ref", "refs/heads/extra", before])
        for ref in ["main", "extra"] {
            _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "--add", "remote.origin.push", "+refs/heads/main:refs/heads/" + ref])
        }
        do { _ = try await f.local.prepareForcePush(); XCTFail("Multiple forced updates require unsupported result") }
        catch ForcePushPreparationError.unsupportedForce {} catch { XCTFail("Unsafe fallback error: \(error)") }
        _ = try await GitProcess.run(at: f.local.url, arguments: ["checkout", "--detach"])
        do { _ = try await f.local.prepareForcePush(); XCTFail("Detached mapping must not allow ordinary fallback") }
        catch ForcePushPreparationError.unsupportedForce {} catch { XCTFail("Unsafe fallback error: \(error)") }
        let unchanged = try await remoteHead(f); XCTAssertEqual(unchanged, before)
    }
    func testOrdinarySuccessfulPushPreviewUsesOnlyNotRequiredFallback() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.local.url, arguments: ["reset", "--hard", "origin/main"])
        do { _ = try await f.local.prepareForcePush(); XCTFail("No force candidate expected") }
        catch ForcePushPreparationError.notRequired {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testRefspecDestinationAndNonFastForwardClassification() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await GitProcess.run(at: f.bare, arguments: ["update-ref", "refs/heads/delivery", try await remoteHead(f)])
        _ = try await GitProcess.run(at: f.local.url, arguments: ["config", "remote.origin.push", "refs/heads/main:refs/heads/delivery"])
        let preview = try await f.local.prepareForcePush()
        XCTAssertEqual(preview.remoteBranch, "refs/heads/delivery")
        _ = try await f.local.forcePush(preview, progress: { _ in })
        let delivery = try await GitRepository(url: f.bare).workflowRevision("refs/heads/delivery")
        let main = try await remoteHead(f)
        XCTAssertEqual(delivery, preview.localCommit); XCTAssertEqual(main, preview.remoteCommit)
        XCTAssertTrue(ForcePushRejection.isNonFastForward(GitError("[rejected] main -> main (fetch first)")))
        XCTAssertTrue(ForcePushRejection.isNonFastForward(GitError("[rejected] main -> main (non-fast-forward)")))
        XCTAssertFalse(ForcePushRejection.isNonFastForward(GitError("[remote rejected] main -> main (protected branch)")))
        XCTAssertFalse(ForcePushRejection.isNonFastForward(GitError("Authentication failed")))
    }
}
