import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class RepositoryRemoteSyncTests: XCTestCase {
    func testSlowRemoteCannotHideAlreadyKnownIncomingUpdatesInLaterProjects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer")
        let slow = root.appendingPathComponent("slow"), ready = root.appendingPathComponent("ready")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"],
                     ["commit", "--allow-empty", "-m", "base"], ["push", "origin", "HEAD"]] {
            _ = try await GitProcess.run(at: producer, arguments: args)
        }
        for path in [slow, ready] { _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, path.path]) }
        _ = try await GitProcess.run(at: producer, arguments: ["commit", "--allow-empty", "-m", "incoming"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        _ = try await GitProcess.run(at: ready, arguments: ["fetch", "origin"])
        let wrapper = root.appendingPathComponent("test-git"), started = root.appendingPathComponent("started")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "ls-remote" ]; then
                touch '\(started.path)'
                sleep 30
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.recentPaths = [slow.path, ready.path]
        store.refreshRecentRepositoryStates(addedPaths: [slow.path, ready.path])
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertEqual(store.repositorySyncStates[ready.path]?.behind, 1,
            "A project with known incoming commits must appear before any slow remote check completes")
        store.setApplicationActive(false)
        await store.cancelBackgroundRepositorySync()
        XCTAssertEqual(store.repositorySyncStates[ready.path]?.behind, 1, "Switching apps must retain the known sidebar state")
    }

    func testNewProjectFetchesImmediatelyWithBackgroundRefreshDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer"), local = root.appendingPathComponent("local")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["commit", "--allow-empty", "-m", "base"], ["push", "origin", "HEAD"]] {
            _ = try await GitProcess.run(at: producer, arguments: args)
        }
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, local.path])
        _ = try await GitProcess.run(at: producer, arguments: ["commit", "--allow-empty", "-m", "incoming"])
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(local)
        for _ in 0..<300 {
            if store.repositorySyncStates[local.path]?.behind == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.cancelBackgroundRepositorySync()
        XCTAssertEqual(store.repositorySyncStates[local.path]?.behind, 1)
        XCTAssertEqual(store.commits.first?.subject, "incoming")
    }

    func testIncomingHistoryStaysAboveNewerLocalCommitsAcrossPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer"), local = root.appendingPathComponent("local")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["commit", "--allow-empty", "-m", "base"], ["push", "origin", "HEAD"]] {
            _ = try await GitProcess.run(at: producer, arguments: args)
        }
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, local.path])
        for index in 0..<26 {
            _ = try await GitProcess.run(at: producer, arguments: ["commit", "--allow-empty", "-m", "incoming-\(index)"], environmentOverrides: ["GIT_AUTHOR_DATE": "2020-01-01T12:00:00Z", "GIT_COMMITTER_DATE": "2020-01-01T12:00:00Z"])
        }
        _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD"])
        for args in [["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["commit", "--allow-empty", "-m", "newer-local"]] {
            _ = try await GitProcess.run(at: local, arguments: args)
        }
        let repo = GitRepository(url: local)
        try await repo.backgroundFetch()
        let key = "preferences.historyPageSize", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(25, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = repo.url
        await store.refresh()
        XCTAssertEqual(store.commits.first?.subject, "incoming-25")
        XCTAssertTrue(store.hasMore)
        await store.loadHistory(reset: false)
        XCTAssertEqual(store.commits.prefix(26).map(\.subject), (0..<26).reversed().map { "incoming-\($0)" })
        XCTAssertEqual(store.commits.dropFirst(26).map(\.subject), ["newer-local", "base"])
        XCTAssertEqual(Set(store.commits.map(\.hash)).count, store.commits.count)
        XCTAssertFalse(store.hasMore)
    }

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
        store.repository = GitRepository(url: paths[0]); store.repositoryURL = store.repository?.url
        let projects = WorkspaceProjects(initial: store)
        defer { withExtendedLifetime(projects) {} }
        await store.open(paths[1])
        let selected = projects.active
        defer { selected.closeTransientSession() }
        await store.cancelBackgroundRepositorySync()
        store.nextRemoteSync = [:]
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(30))
        for _ in 0..<500 {
            if paths.allSatisfy({ store.repositorySyncStates[$0.path]?.behind == 1 && selected.repositorySyncStates[$0.path]?.behind == 1 }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await store.cancelBackgroundRepositorySync()
        for path in paths {
            XCTAssertEqual(store.repositorySyncStates[path.path]?.behind, 1)
            XCTAssertEqual(store.repositoryChangeCounts[path.path], 1)
            XCTAssertEqual(selected.repositorySyncStates[path.path]?.behind, 1, "Every project sidebar must receive fetched state")
            XCTAssertEqual(selected.repositoryChangeCounts[path.path], 1)
            XCTAssertEqual(try String(contentsOf: path.appendingPathComponent("file.txt"), encoding: .utf8), "dirty\n")
            XCTAssertNotNil(store.nextRemoteSync[path.path])
        }
        let after = try await paths.asyncHeads()
        XCTAssertEqual(heads, after)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.commits.first?.subject, "remote change", "A successful background fetch must put incoming commits at the top of active history")
        XCTAssertTrue(store.commits.contains { $0.subject == "base" })
        var dates = store.nextRemoteSync
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(31))
        try await Task.sleep(nanoseconds: 200_000_000)
        await store.cancelBackgroundRepositorySync()
        XCTAssertEqual(store.nextRemoteSync, dates, "Local checks must not fetch before the per-project deadline")
        let busyProject = RepositoryStore(persistsSession: false)
        busyProject.repositoryURL = paths[0]
        busyProject.isBusy = true
        store.refreshRecentRepositoryStates(now: Date().addingTimeInterval(200))
        for _ in 0..<500 {
            if store.nextRemoteSync[paths[1].path] != dates[paths[1].path] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.cancelBackgroundRepositorySync()
        XCTAssertEqual(store.nextRemoteSync[paths[0].path], dates[paths[0].path])
        XCTAssertNotEqual(store.nextRemoteSync[paths[1].path], dates[paths[1].path], "A busy project cannot starve other projects")
        busyProject.isBusy = false; busyProject.closeTransientSession()
        dates = store.nextRemoteSync
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
            if [ "$arg" = "ls-remote" ]; then
                trap '' TERM
                touch '\(started.path)'
                sleep 30
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let executableKey = "auvgit.git.executablePath", previousExecutable = UserDefaults.standard.object(forKey: "auvgit.git.executablePath")
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
        cancellingWindow.repositoryURL = paths[0]
        cancellingWindow.repository = GitRepository(url: paths[0])
        var joined = false
        let preflight = expectation(description: "Local preflight does not wait for background shutdown")
        cancellingWindow.checkNetworkPreflight(.push) { hint in
            XCTAssertNotNil(hint)
            XCTAssertFalse(joined, "The local hint must arrive before the canceled network process finishes")
            preflight.fulfill()
        }
        let cancellationStart = Date()
        let joining = Task {
            await cancellingWindow.cancelBackgroundRepositorySync()
            joined = true
        }
        await fulfillment(of: [preflight], timeout: 3)
        let wrote = await cancellingWindow.performRepositoryContextOperation("Test", path: paths[0].path) { _ in
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(cancellationStart), 0.4, "Foreground writes must wait for the TERM-resistant background process")
        }
        XCTAssertTrue(wrote)
        await joining.value
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
