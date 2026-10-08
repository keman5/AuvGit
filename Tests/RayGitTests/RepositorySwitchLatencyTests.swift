import XCTest
import Combine
@testable import RayGit
@testable import GitCore

@MainActor
final class RepositorySwitchLatencyTests: XCTestCase {
    func testLatestRepositoryClickWinsWhilePreviousOpenIsWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for repo in [first, second] { _ = try await GitProcess.run(at: repo, arguments: ["init"]) }
        let wrapper = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        if [ -f .git/delay-opening ]; then
            for arg in "$@"; do
                if [ "$arg" = "--show-toplevel" ]; then
                    touch .git/opening-blocked
                    attempts=0
                    while [ ! -f .git/release-opening ] && [ "$attempts" -lt 500 ]; do
                        sleep 0.01
                        attempts=$((attempts + 1))
                    done
                fi
            done
        fi
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try Data().write(to: first.appendingPathComponent(".git/delay-opening"))
        let key = "raygit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        store.diffText = "old repository diff"; store.commitMessage = "old repository draft"
        let opening = Task { await store.open(first) }
        while !store.isBusy { await Task.yield() }
        XCTAssertEqual(store.highlightedRepositoryPath, first.path)
        XCTAssertNil(store.repository)
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertTrue(store.branches.isEmpty)
        XCTAssertTrue(store.commits.isEmpty)
        XCTAssertTrue(store.diffText.isEmpty)
        XCTAssertTrue(store.commitMessage.isEmpty)
        await store.open(second)
        await opening.value
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.error)
        store.commitMessage = "preserved draft"
        let cancelled = Task { await store.open(first) }
        while !store.isBusy { await Task.yield() }
        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(store.isBusy, "Canceling the current opening must release its busy state")
        XCTAssertFalse(store.isRestoringViewState)
        XCTAssertNil(store.error)
        await store.open(second)
        XCTAssertEqual(store.commitMessage, "preserved draft", "A canceled switch must retain the previous repository draft")
        await store.open(root.appendingPathComponent("missing"))
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.pendingRepositoryPath)
        await store.open(second)
        XCTAssertEqual(store.commitMessage, "preserved draft", "A failed switch must retain the previous repository draft")
    }
    func testWorkspaceSwitchTimingAndSkipsHiddenCommitDetails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
            _ = try await GitProcess.run(at: root, arguments: args)
        }
        let file = root.appendingPathComponent("file.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "."])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        try "changed\n".write(to: file, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent(".git/test-git")
        let release = root.appendingPathComponent(".git/release-panels")
        let timeout = root.appendingPathComponent(".git/panel-gate-timeout")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "diff" ] || [ "$arg" = "HEAD...@{upstream}" ]; then
                attempts=0
                while [ ! -f .git/release-panels ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
                if [ ! -f .git/release-panels ]; then touch .git/panel-gate-timeout; fi
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "raygit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        let started = Date()
        var filesElapsed: TimeInterval?
        let observation = store.$files.sink { files in
            if !files.isEmpty, filesElapsed == nil {
                filesElapsed = Date().timeIntervalSince(started)
                store.mode = "workspace"; store.selectedPaths = ["file.txt"]
            }
        }
        defer { observation.cancel() }
        var diffElapsed: TimeInterval?
        let diffObservation = store.$diffText.sink { text in
            if text.contains("changed"), diffElapsed == nil { diffElapsed = Date().timeIntervalSince(started) }
        }
        defer { diffObservation.cancel() }
        var branchesBeforeDetails = false, historyBeforeDetails = false
        let branchObservation = store.$branches.sink { branches in
            if !branches.isEmpty { branchesBeforeDetails = !FileManager.default.fileExists(atPath: release.path) }
        }
        let historyObservation = store.$commits.sink { commits in
            if !commits.isEmpty {
                historyBeforeDetails = !FileManager.default.fileExists(atPath: timeout.path)
                _ = FileManager.default.createFile(atPath: release.path, contents: Data())
            }
        }
        defer { branchObservation.cancel(); historyObservation.cancel() }
        await store.open(root)
        print("Repository switch: files=\(filesElapsed ?? -1)s diff=\(diffElapsed ?? -1)s complete=\(Date().timeIntervalSince(started))s")
        XCTAssertEqual(store.files.map(\.path), ["file.txt"])
        XCTAssertNotNil(diffElapsed)
        XCTAssertTrue(branchesBeforeDetails, "Branches must publish before selected diff/upstream reads finish")
        XCTAssertTrue(historyBeforeDetails, "History must release the diff/upstream barrier without waiting for it")
        XCTAssertNotNil(store.selectedCommit)
        // Opening the main workspace needs the history row, not its invisible file details.
        if store.mode == "workspace" { XCTAssertTrue(store.commitFiles.isEmpty) }
    }
}
