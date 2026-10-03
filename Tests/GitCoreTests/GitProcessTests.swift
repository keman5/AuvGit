import XCTest
import Darwin
@testable import GitCore

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return values.joined() }
}
final class GitProcessTests: XCTestCase {
    private func fixture() async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: directory, arguments: ["init"])
        return directory
    }
    func testCancellationTerminatesDescendantProcessGroup() async throws {
        let directory = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A TERM-resistant child ensures cancellation must escalate to the entire process group.
        _ = try await GitProcess.run(at: directory, arguments: ["config", "alias.slow", "!sh -c 'trap \"\" TERM; echo $$ > child.pid; sleep 30' & wait"])
        let task = Task { try await GitProcess.run(at: directory, arguments: ["slow"]) }
        let pidFile = directory.appendingPathComponent("child.pid")
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: pidFile.path) { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        let child = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = Date(); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must throw") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        for _ in 0..<100 { if kill(child, 0) != 0 { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotEqual(kill(child, 0), 0, "The helper must not remain alive after cancellation")
    }
    func testTimeoutAndRealStderrProgress() async throws {
        let directory = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await GitProcess.run(at: directory, arguments: ["config", "alias.progress", "!printf 'Receiving objects: 42%% (42/100)\\r' >&2; sleep 30"])
        let recorder = ProgressRecorder(), start = Date()
        do { _ = try await GitProcess.run(at: directory, arguments: ["progress"], timeout: 0.2, progress: { recorder.append($0) }); XCTFail("Timeout must throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertTrue(recorder.text.contains("42%"))
        XCTAssertEqual(GitProgressParser.parse(recorder.text)?.fraction, 0.42)
        XCTAssertFalse(GitProgressParser.redact("https://secret:token@host.invalid/path?q=secret").contains("token"))
    }
    func testAlreadyCancelledTaskDoesNotStartGit() async throws {
        let directory = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GitProcess.run(at: directory, arguments: ["config", "should.not.exist", "yes"])
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let result = try await GitProcess.run(at: directory, arguments: ["config", "--get", "should.not.exist"], allowedCodes: [0, 1])
        XCTAssertEqual(result.code, 1)
    }
    func testConcurrentCommandsDoNotInheritEachOthersPipes() async throws {
        let directory = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await GitProcess.run(at: directory, arguments: ["config", "alias.slow", "!sleep 30"])
        let slow = Task { try await GitProcess.run(at: directory, arguments: ["slow"]) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        _ = try await GitProcess.run(at: directory, arguments: ["status", "--porcelain"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "A short command must not await a concurrent process retaining its pipe")
        slow.cancel(); _ = try? await slow.value
    }
    func testPushPreviewDoesNotUpdateRemoteAndIdentityChanges() async throws {
        let directory = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote.git")
        _ = try await GitProcess.run(at: directory, arguments: ["init", "--bare", remote.path])
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"], ["symbolic-ref", "HEAD", "refs/heads/main"]] { _ = try await GitProcess.run(at: directory, arguments: args) }
        try Data("hello\n".utf8).write(to: directory.appendingPathComponent("file"))
        for args in [["add", "file"], ["commit", "-m", "initial"], ["remote", "add", "origin", remote.path], ["config", "branch.main.remote", "origin"], ["config", "branch.main.merge", "refs/heads/main"]] { _ = try await GitProcess.run(at: directory, arguments: args) }
        let repository = GitRepository(url: directory)
        let before = try await repository.networkPreviewIdentity()
        let preview = try await repository.runNetwork(.pushPreview, progress: { _ in })
        XCTAssertTrue(preview.output.contains("main"))
        let unchanged = try await GitProcess.run(at: remote, arguments: ["show-ref"], allowedCodes: [0, 1])
        XCTAssertEqual(unchanged.code, 1)
        let afterPreview = try await repository.networkPreviewIdentity()
        XCTAssertEqual(before, afterPreview)
        _ = try await repository.runNetwork(.push, progress: { _ in })
        let updated = try await GitProcess.run(at: remote, arguments: ["show-ref", "refs/heads/main"])
        XCTAssertTrue(updated.text.contains("refs/heads/main"))
        _ = try await GitProcess.run(at: directory, arguments: ["config", "remote.origin.pushurl", "https://private:secret@example.invalid/repo"])
        let afterConfig = try await repository.networkPreviewIdentity()
        XCTAssertNotEqual(before, afterConfig)
        XCTAssertFalse(afterConfig.contains("secret"))
    }
    func testHelperConfigurationDoesNotExposeCustomSecrets() async throws {
        let directory = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await GitProcess.run(at: directory, arguments: ["config", "credential.helper", "!echo secret-token"])
        let repository = GitRepository(url: directory)
        let before = try await repository.credentialConfiguration()
        XCTAssertTrue(before.helpers.contains("Custom helper"))
        XCTAssertFalse(before.helpers.joined().contains("secret-token"))
        try await repository.configureKeychainHelper()
        let after = try await repository.credentialConfiguration()
        XCTAssertTrue(after.helpers.contains("osxkeychain"))
    }
}
