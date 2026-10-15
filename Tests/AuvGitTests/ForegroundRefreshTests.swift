import XCTest
import Combine
@testable import AuvGit
@testable import GitCore

@MainActor
final class ForegroundRefreshTests: XCTestCase {
    func testSwitchCleanupDoesNotRepublishIdleControllers() {
        let ai = AICommitController()
        let authentication = RemoteAuthenticationCoordinator()
        var invalidations = 0
        let observers = [ai.objectWillChange.sink { invalidations += 1 },
                         authentication.objectWillChange.sink { invalidations += 1 }]
        for _ in 0..<3 { ai.cancel(); authentication.cancel() }
        XCTAssertEqual(invalidations, 0, "Repository changes must not schedule another full layout for already-empty state")
        withExtendedLifetime(observers) {}
    }
    private func fixture() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "main"])
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
            _ = try await GitProcess.run(at: root, arguments: ["config", key, value])
        }
        try "base\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "file.txt"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        return root
    }
    private func installCountingGit(_ root: URL) throws -> Any? {
        let previous = UserDefaults.standard.object(forKey: "auvgit.git.executablePath")
        let wrapper = root.appendingPathComponent(".git/count-git")
        try """
        #!/bin/sh
        for arg in "$@"; do
            case "$arg" in
                status|for-each-ref|log) echo "$arg" >> .git/reads ;;
            esac
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        UserDefaults.standard.set(wrapper.path, forKey: "auvgit.git.executablePath")
        return previous
    }
    private func restoreGit(_ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: "auvgit.git.executablePath") }
        else { UserDefaults.standard.removeObject(forKey: "auvgit.git.executablePath") }
    }
    func testInactivePollingDoesNoReadsAndActivationCoalesces() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.setApplicationActive(false)
        let previous = try installCountingGit(root)
        defer { restoreGit(previous) }
        let background = UserDefaults.standard.object(forKey: "preferences.backgroundRefresh")
        UserDefaults.standard.set(true, forKey: "preferences.backgroundRefresh")
        defer {
            if let background { UserDefaults.standard.set(background, forKey: "preferences.backgroundRefresh") }
            else { UserDefaults.standard.removeObject(forKey: "preferences.backgroundRefresh") }
        }
        try "changed\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        for _ in 0..<3 { await store.pollForChanges(); await store.refreshIfChanged() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/reads").path))
        store.setApplicationActive(true)
        store.setApplicationActive(true)
        let deadline = Date().addingTimeInterval(3)
        while store.files.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.files.map(\.path), ["file.txt"])
        await store.pollForChanges()
        let reads = try String(contentsOf: root.appendingPathComponent(".git/reads"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(reads.filter { $0 == "status" }.count, 1, "Activation and an immediate timer tick must share one refresh")
    }
    func testStageAndUnstageDoNotReloadBranchOrHistoryLists() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "changed\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        store.setApplicationActive(false)
        let commits = store.commits, branches = store.branches
        let previous = try installCountingGit(root)
        defer { restoreGit(previous) }
        store.selectedPaths = ["file.txt"]
        for staging in [true, false] {
            let updated = expectation(description: staging ? "Staged row" : "Unstaged row")
            let observation = store.$files.dropFirst().sink { files in
                if files.first?.isStaged == staging { updated.fulfill() }
            }
            if staging { store.stageSelection() } else { store.unstageSelection() }
            await fulfillment(of: [updated], timeout: 3)
            observation.cancel()
            let deadline = Date().addingTimeInterval(3)
            while store.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertEqual(store.commits, commits); XCTAssertEqual(store.branches, branches)
        let reads = try String(contentsOf: root.appendingPathComponent(".git/reads"), encoding: .utf8).split(separator: "\n")
        XCTAssertFalse(reads.contains("for-each-ref")); XCTAssertFalse(reads.contains("log"))
        XCTAssertEqual(reads.filter { $0 == "status" }.count, 4, "Each write keeps its fresh-status safety check and one file-only refresh")
    }
}
