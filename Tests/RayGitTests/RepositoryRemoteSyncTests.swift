import XCTest
@testable import RayGit
@testable import GitCore

@MainActor
final class RepositoryRemoteSyncTests: XCTestCase {
    func testBackgroundSweepRefreshesActiveAndUnselectedProjectsWithoutChangingWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionKeys = ["repositorySession.v1", "repositorySession.v1.backup", "repositorySession.v1.corrupt"]
        let savedSession = sessionKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(sessionKeys, savedSession) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        _ = try await GitProcess.run(at: producer, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: producer, arguments: ["config", "user.email", "test@example.com"])
        try "base\n".write(to: producer.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: producer, arguments: ["add", "."])
        _ = try await GitProcess.run(at: producer, arguments: ["commit", "-m", "base"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        let paths = [root.appendingPathComponent("active"), root.appendingPathComponent("unselected")]
        for path in paths { _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, path.path]) }
        let heads = try await paths.asyncHeads()
        for path in paths { try "dirty\n".write(to: path.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8) }
        try "remote change\n".write(to: producer.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: producer, arguments: ["commit", "-am", "remote change"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        let store = RepositoryStore()
        store.recentPaths = paths.map(\.path); store.openRepositories = [paths[0].path]
        store.repositoryURL = paths[0]; store.repository = GitRepository(url: paths[0])
        store.refreshRecentRepositoryStates()
        for _ in 0..<500 {
            if paths.allSatisfy({ store.repositorySyncStates[$0.path]?.behind == 1 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await store.cancelBackgroundRepositorySync()
        for path in paths {
            XCTAssertEqual(store.repositorySyncStates[path.path]?.behind, 1)
            XCTAssertEqual(store.repositoryChangeCounts[path.path], 1)
            XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("file.txt"), encoding: .utf8), "dirty\n")
            XCTAssertNotNil(store.nextRemoteSync[path.path])
        }
        let after = try await paths.asyncHeads()
        XCTAssertEqual(heads, after)
        XCTAssertFalse(store.isBusy)
        let dates = store.nextRemoteSync
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(31))
        try await Task.sleep(nanoseconds: 200_000_000)
        await store.cancelBackgroundRepositorySync()
        XCTAssertEqual(store.nextRemoteSync, dates, "Local checks must not fetch before the per-project deadline")
        let transient = RepositoryStore(persistsSession: false)
        transient.isBusy = true
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(400))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(store.nextRemoteSync, dates, "Writes in a Log window must stop the main window sweep")
        transient.isBusy = false; transient.closeTransientSession()
        // One broken remote must back off without starving another valid remote.
        _ = try await GitProcess.run(at: paths[0], arguments: ["remote", "add", "aaa-broken", root.appendingPathComponent("missing.git").path])
        store.nextRemoteSync = [:]
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(401))
        for _ in 0..<500 {
            if store.nextRemoteSync.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await store.cancelBackgroundRepositorySync()
        XCTAssertGreaterThan(store.nextRemoteSync[paths[0].path]!.timeIntervalSinceNow, 290)
        XCTAssertLessThan(store.nextRemoteSync[paths[1].path]!.timeIntervalSinceNow, 151)
        XCTAssertEqual(store.repositorySyncStates[paths[0].path]?.behind, 1)

        // A transient window joins the main window fetch before writing.
        let wrapper = root.appendingPathComponent("test-git"), started = root.appendingPathComponent("fetch-started")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "fetch" ]; then
                touch '\(started.path)'
                sleep 30
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let executableKey = "raygit.git.executablePath", previousExecutable = UserDefaults.standard.object(forKey: "raygit.git.executablePath")
        UserDefaults.standard.set(wrapper.path, forKey: executableKey)
        defer { if let previousExecutable { UserDefaults.standard.set(previousExecutable, forKey: executableKey) } else { UserDefaults.standard.removeObject(forKey: executableKey) } }
        store.nextRemoteSync = [:]
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(800))
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: started.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        let cancellingWindow = RepositoryStore(persistsSession: false)
        cancellingWindow.isBusy = true
        let cancellationStart = Date()
        await cancellingWindow.cancelBackgroundRepositorySync()
        XCTAssertLessThan(Date().timeIntervalSince(cancellationStart), 3)
        XCTAssertTrue(store.nextRemoteSync.isEmpty, "Cancellation must not mark the fetch fresh or failed")
        cancellingWindow.isBusy = false; cancellingWindow.closeTransientSession()
    }
}
private extension Array where Element == URL {
    func asyncHeads() async throws -> [String] {
        var heads: [String] = []
        for path in self { heads.append(try await GitProcess.run(at: path, arguments: ["rev-parse", "HEAD"]).text) }
        return heads
    }
}
