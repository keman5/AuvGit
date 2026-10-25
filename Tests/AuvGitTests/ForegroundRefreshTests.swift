import XCTest
import Combine
import AppKit
@testable import AuvGit
@testable import GitCore

@MainActor
final class ForegroundRefreshTests: XCTestCase {
    func testActivationReplacesBlockedAutomaticReadAndStagingRemainsResponsive() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.repository = GitRepository(url: root); store.repositoryURL = root
        await store.refresh()
        let started = root.appendingPathComponent(".git/status-started")
        let executable = try installBlockedStatus(root, started: started)
        defer { restoreGit(executable) }
        UserDefaults.standard.set(true, forKey: key)
        let read = Task { await store.refreshIfChanged() }
        defer { read.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        store.setApplicationActive(false)
        try "changed while inactive\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        store.setApplicationActive(true)
        let recovered = Date().addingTimeInterval(2)
        while store.files.isEmpty, Date() < recovered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.files.map(\.path), ["file.txt"], "Activation cannot wait for a stale status command")
        store.selectedPaths = ["file.txt"]
        store.stageSelection()
        let staged = Date().addingTimeInterval(2)
        while store.files.first?.isStaged != true, Date() < staged { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.files.first?.isStaged == true)
        read.cancel(); await read.value
    }

    func testSlowProjectDoesNotBlockOtherProjectsPolling() async throws {
        let roots = try await [fixture(), fixture(), fixture()]
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let stores = roots.map { _ in RepositoryStore(persistsSession: false) }
        defer { stores.forEach { $0.closeTransientSession() } }
        for (store, root) in zip(stores, roots) {
            store.repository = GitRepository(url: root); store.repositoryURL = root
            await store.refresh()
            try "new content\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        // Whichever session the weak store registry visits first is the slow one.
        let started = roots[0].appendingPathComponent(".git/status-started")
        let executable = try installBlockedStatus(roots[0], started: started)
        defer { restoreGit(executable) }
        UserDefaults.standard.set(true, forKey: key)
        let poll = Task { await RepositoryStore.pollAllRepositories() }
        defer { poll.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while stores.filter({ !$0.files.isEmpty }).count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        XCTAssertEqual(stores.filter { !$0.files.isEmpty }.count, 2, "Only the blocked repository may remain stale")
        poll.cancel(); await poll.value
    }

    func testStagingCancelsBlockedAutomaticReadWithoutActivation() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "changed\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.repository = GitRepository(url: root); store.repositoryURL = root
        await store.refresh()
        let started = root.appendingPathComponent(".git/status-started")
        let executable = try installBlockedStatus(root, started: started)
        defer { restoreGit(executable) }
        let stopped = expectation(description: "Automatic read stopped for staging")
        let read = Task { await store.refreshIfChanged(); stopped.fulfill() }
        defer { read.cancel() }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        store.selectedPaths = ["file.txt"]
        store.stageSelection()
        let staged = Date().addingTimeInterval(2)
        while store.files.first?.isStaged != true, Date() < staged { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(store.files.first?.isStaged == true)
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertNil(store.error)
        read.cancel(); await read.value
    }

    func testRepeatedFilesystemChangesAndStageCyclesKeepStatusFresh() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(false, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        await store.cancelBackgroundRepositorySync()
        UserDefaults.standard.set(true, forKey: key)
        for cycle in 0..<60 {
            try "cycle \(cycle)\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            let changed = Date().addingTimeInterval(2)
            while store.files.first?.isUnstaged != true, Date() < changed { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(store.files.first?.isUnstaged == true, "Filesystem events must remain live at cycle \(cycle)")
            store.selectedPaths = ["file.txt"]
            store.stageSelection()
            let deadline = Date().addingTimeInterval(2)
            while store.files.first?.isUnstaged != false, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(store.files.first?.isStaged == true)
            XCTAssertFalse(store.files.first?.isUnstaged == true)
        }
    }

    private func installBlockedStatus(_ root: URL, started: URL) throws -> Any? {
        let previous = UserDefaults.standard.object(forKey: "auvgit.git.executablePath")
        let wrapper = root.appendingPathComponent(".git/blocked-status-git")
        let quoted = "'" + started.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = status ] && mkdir \(quoted) 2>/dev/null; then
                trap '' TERM
                sleep 30
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        UserDefaults.standard.set(wrapper.path, forKey: "auvgit.git.executablePath")
        return previous
    }

    func testApplicationLifecycleResumesAllProjectsWithoutSceneCallbacks() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        let delegate: NSApplicationDelegate = AuvGitApplicationDelegate()
        delegate.applicationDidResignActive?(Notification(name: NSApplication.didResignActiveNotification))
        XCTAssertFalse(store.applicationActive, "The app lifecycle must work without the hidden SwiftUI scene")
        try "changed while inactive\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        delegate.applicationDidBecomeActive?(Notification(name: NSApplication.didBecomeActiveNotification))
        let deadline = Date().addingTimeInterval(3)
        while store.files.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.applicationActive)
        XCTAssertEqual(store.files.map(\.path), ["file.txt"])
    }
    func testApplicationTimerPollsEveryOpenSessionWithoutAWindow() async throws {
        let roots = try await [fixture(), fixture()]
        defer { for root in roots { try? FileManager.default.removeItem(at: root) } }
        let key = "preferences.backgroundRefresh", previous = UserDefaults.standard.object(forKey: key)
        // Use stores without filesystem observers so only the application timer can update them.
        UserDefaults.standard.set(false, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let sessions = roots.map { _ in RepositoryStore(persistsSession: false) }
        defer { for store in sessions { store.closeTransientSession() } }
        for (store, root) in zip(sessions, roots) {
            store.repository = GitRepository(url: root); store.repositoryURL = root
            await store.refresh()
            try "timer change\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        UserDefaults.standard.set(true, forKey: key)
        let delegate = AuvGitApplicationDelegate()
        delegate.startRepositoryPolling(interval: 0.02)
        let deadline = Date().addingTimeInterval(3)
        while sessions.contains(where: { $0.files.isEmpty }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        for store in sessions { XCTAssertEqual(store.files.map(\.path), ["file.txt"]) }
    }
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
