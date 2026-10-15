import XCTest
import Combine
@testable import AuvGit
@testable import GitCore

@MainActor
final class RepositorySwitchLatencyTests: XCTestCase {
    func testBackgroundPreparationMakesFirstVisitPublishAllListsWithin100Milliseconds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        defer { try? FileManager.default.removeItem(at: root) }
        for repo in [first, second] {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                _ = try await GitProcess.run(at: repo, arguments: args)
            }
            try "base\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try await GitProcess.run(at: repo, arguments: ["add", "."])
            _ = try await GitProcess.run(at: repo, arguments: ["commit", "-m", repo.lastPathComponent])
            try "changed\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        store.recentPaths = [first.path, second.path]
        await store.open(first)
        await store.prepareRecentProjects()?.value
        let started = Date()
        let opening = try XCTUnwrap(store.requestOpen(second))
        while store.repositoryURL?.path != second.path, Date().timeIntervalSince(started) < 1 { await Task.yield() }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertEqual(store.files.map(\.path), ["file.txt"])
        XCTAssertEqual(store.commits.first?.subject, "second")
        XCTAssertEqual(store.branches.first?.name, "main")
        XCTAssertTrue(store.diffText.contains("+changed"))
        XCTAssertLessThan(elapsed, 0.1)
        print("Prepared first-visit project publication: \(elapsed)s")
        await opening.value
    }
    func testWarmSwitchPublishesCachedListsBeforeValidationAndRefreshesChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for repo in [first, second] {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                _ = try await GitProcess.run(at: repo, arguments: args)
            }
            try "base\n".write(to: repo.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            _ = try await GitProcess.run(at: repo, arguments: ["add", "."])
            _ = try await GitProcess.run(at: repo, arguments: ["commit", "-m", "Fixture"])
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let largeDirectory = first.appendingPathComponent("large")
        try FileManager.default.createDirectory(at: largeDirectory, withIntermediateDirectories: true)
        for index in 0..<2000 { try Data().write(to: largeDirectory.appendingPathComponent("file-\(index).txt")) }
        let wrapper = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> .git/read-trace
        for arg in "$@"; do
            if [ "$arg" = "status" ] && [ -f .git/block-status ]; then
                touch .git/status-blocked
                attempts=0
                while [ ! -f .git/release-status ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        let coldStart = Date()
        await store.open(first)
        let coldElapsed = Date().timeIntervalSince(coldStart)
        XCTAssertEqual(store.files.count, 2000)
        store.mode = "workspace"; store.commitMessage = "draft"
        let cachedFiles = store.files, generation = store.filesGeneration, cachedCommits = store.commits
        await store.open(second)
        let trace = first.appendingPathComponent(".git/read-trace")
        try Data().write(to: trace)
        try Data().write(to: first.appendingPathComponent(".git/block-status"))
        let warmStart = Date()
        let warm = Task { await store.open(first) }
        let blocked = first.appendingPathComponent(".git/status-blocked")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertEqual(store.repositoryURL?.path, first.path)
        XCTAssertEqual(store.files, cachedFiles)
        XCTAssertEqual(store.filesGeneration, generation)
        XCTAssertEqual(store.commits, cachedCommits)
        XCTAssertFalse(store.branches.isEmpty)
        XCTAssertEqual(store.commitMessage, "draft")
        XCTAssertTrue(store.isBusy, "Cached status must remain read-only until Git validates it")
        let visibleElapsed = Date().timeIntervalSince(warmStart)
        try Data().write(to: first.appendingPathComponent(".git/release-status"))
        await warm.value
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.filesGeneration, generation)
        XCTAssertNotNil(store.selectedCommit)
        let reads = try String(contentsOf: trace, encoding: .utf8)
        XCTAssertFalse(reads.contains("for-each-ref --format=%(HEAD)"))
        XCTAssertFalse(reads.split(separator: "\n").contains { $0.contains(" diff ") || $0.hasPrefix("diff ") }, "Unchanged cached comparisons must not run Git diff again")
        XCTAssertTrue(reads.contains("stash list"), "Stash reflog can change without its tip hash changing")
        XCTAssertFalse(reads.split(separator: "\n").contains { $0.hasPrefix("log ") })
        print("Large repository switch: cold=\(coldElapsed)s warm-visible=\(visibleElapsed)s")
        await store.open(second)
        try "changed\n".write(to: first.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        await store.open(first)
        XCTAssertTrue(store.files.contains { $0.path == "tracked.txt" })
        XCTAssertNotEqual(store.filesGeneration, generation)
        await store.open(second)
        _ = try await GitProcess.run(at: first, arguments: ["add", "tracked.txt"])
        _ = try await GitProcess.run(at: first, arguments: ["commit", "-m", "New history"])
        _ = try await GitProcess.run(at: first, arguments: ["checkout", "-b", "changed-branch"])
        await store.open(first)
        XCTAssertEqual(store.branch, "changed-branch")
        XCTAssertEqual(store.commits.first?.subject, "New history")
        XCTAssertFalse(store.files.contains { $0.path == "tracked.txt" })
        for message in ["Older stash", "Top stash"] {
            try "\(message)\n".write(to: first.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            _ = try await GitProcess.run(at: first, arguments: ["stash", "push", "-m", message])
        }
        await store.refresh()
        XCTAssertEqual(store.stashes.count, 2)
        let removedStash = try XCTUnwrap(store.stashes.last?.hash)
        let stashTip = try await GitProcess.run(at: first, arguments: ["rev-parse", "refs/stash"]).text
        await store.open(second)
        _ = try await GitProcess.run(at: first, arguments: ["stash", "drop", "stash@{1}"])
        let unchangedTip = try await GitProcess.run(at: first, arguments: ["rev-parse", "refs/stash"]).text
        XCTAssertEqual(stashTip, unchangedTip)
        await store.open(first)
        XCTAssertEqual(store.stashes.count, 1)
        XCTAssertFalse(store.commits.contains { $0.hash == removedStash }, "History must discard deleted non-top stash rows")
        await store.open(second)
        try FileManager.default.removeItem(at: first.appendingPathComponent(".git/release-status"))
        try FileManager.default.removeItem(at: blocked)
        let stale = Task { await store.open(first) }
        let staleDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < staleDeadline { try await Task.sleep(for: .milliseconds(10)) }
        await store.open(second)
        try Data().write(to: first.appendingPathComponent(".git/release-status"))
        await stale.value
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertFalse(store.isBusy)
        XCTAssertTrue(store.files.isEmpty, "Late status from the old repository must not overwrite the latest click")
    }
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
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
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
        XCTAssertEqual(store.diffText, "old repository diff", "Opening must retain the visible comparison until the target is ready")
        XCTAssertEqual(store.commitMessage, "old repository draft")
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
        let neverStarted = try XCTUnwrap(store.requestOpen(first))
        neverStarted.cancel(); await neverStarted.value
        XCTAssertNil(store.pendingRepositoryPath)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        await store.open(root.appendingPathComponent("missing"))
        XCTAssertFalse(store.isBusy)
        XCTAssertNil(store.pendingRepositoryPath)
        await store.open(second)
        XCTAssertEqual(store.commitMessage, "preserved draft", "A failed switch must retain the previous repository draft")
    }
    func testCachedRootMustNotBecomeItsParentRepositoryAfterMetadataRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init", "-b", "parent"])
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await GitProcess.run(at: directory, arguments: ["init", "-b", "main"])
            try "draft".write(to: directory.appendingPathComponent(directory.lastPathComponent + ".txt"), atomically: true, encoding: .utf8)
        }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(first); await store.open(second)
        let files = store.files
        try FileManager.default.moveItem(at: first.appendingPathComponent(".git"), to: root.appendingPathComponent("removed-metadata"))
        await store.open(first)
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertEqual(store.files, files)
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.isBusy)
    }
    func testColdSwitchKeepsCompletePreviousViewUntilTargetIsReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for args in [["init", "-b", "main"], ["config", "user.name", "Test"], ["config", "user.email", "test@example.invalid"], ["config", "commit.gpgsign", "false"]] {
                _ = try await GitProcess.run(at: directory, arguments: args)
            }
            try "base\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try await GitProcess.run(at: directory, arguments: ["add", "."])
            _ = try await GitProcess.run(at: directory, arguments: ["commit", "-m", directory.lastPathComponent])
            try "\(directory.lastPathComponent) change\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        await store.open(first)
        XCTAssertTrue(store.diffText.contains("first change"))
        store.showsWorkspaceTree = true
        let previousFiles = store.files, previousBranches = store.branches, previousCommits = store.commits, previousDiff = store.diffText
        let wrapper = root.appendingPathComponent("git")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "status" ] && [ -f .git/block-status ]; then
                touch .git/status-blocked
                attempts=0
                while [ ! -f .git/release-status ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        try Data().write(to: second.appendingPathComponent(".git/block-status"))
        var clearedList = false
        let subscriptions = [store.$files.dropFirst().sink { if $0.isEmpty { clearedList = true } },
                             store.$branches.dropFirst().sink { if $0.isEmpty { clearedList = true } },
                             store.$commits.dropFirst().sink { if $0.isEmpty { clearedList = true } }]
        defer { subscriptions.forEach { $0.cancel() } }
        let opening = Task { await store.open(second) }
        let blocked = second.appendingPathComponent(".git/status-blocked"), deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertEqual(store.highlightedRepositoryPath, second.path)
        XCTAssertEqual(store.repositoryURL?.path, first.path)
        XCTAssertEqual(store.files, previousFiles); XCTAssertEqual(store.branches, previousBranches)
        XCTAssertEqual(store.commits, previousCommits); XCTAssertEqual(store.diffText, previousDiff)
        XCTAssertTrue(store.isBusy); XCTAssertFalse(store.canMutateDisplayedDiff)
        try Data().write(to: second.appendingPathComponent(".git/release-status"))
        await opening.value
        XCTAssertEqual(store.repositoryURL?.path, second.path)
        XCTAssertEqual(store.commits.first?.subject, "second")
        XCTAssertTrue(store.diffText.contains("second change"))
        XCTAssertEqual(WorkspaceTreeCache.shared.nodes(for: second.path)?.first?.path, "file.txt", "The target tree must be ready before the repository is published")
        XCTAssertTrue(store.commitFiles.isEmpty, "The workspace must not load hidden commit details")
        XCTAssertFalse(clearedList, "Cold switching must never publish an intermediate empty list")
        let warmStart = Date()
        let warm = Task { await store.open(first) }
        while store.repositoryURL?.path != first.path { await Task.yield() }
        let visible = Date().timeIntervalSince(warmStart)
        XCTAssertEqual(store.commits, previousCommits); XCTAssertEqual(store.diffText, previousDiff)
        XCTAssertLessThan(visible, 0.15, "A warm view must restore without awaiting Git")
        await warm.value
        XCTAssertFalse(clearedList)
        try FileManager.default.removeItem(at: second.appendingPathComponent(".git/release-status"))
        try FileManager.default.removeItem(at: blocked)
        let cancelled = Task { await store.open(second) }
        let cancelDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: blocked.path), Date() < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        cancelled.cancel(); await cancelled.value
        XCTAssertEqual(store.repositoryURL?.path, first.path)
        XCTAssertEqual(store.commits, previousCommits); XCTAssertEqual(store.diffText, previousDiff)
        XCTAssertFalse(store.isBusy); XCTAssertNil(store.error)
        await store.open(root.appendingPathComponent("missing"))
        XCTAssertEqual(store.repositoryURL?.path, first.path)
        XCTAssertEqual(store.commits, previousCommits); XCTAssertEqual(store.diffText, previousDiff)
        XCTAssertFalse(store.isBusy); XCTAssertNotNil(store.error)
        XCTAssertFalse(clearedList)
        print("Atomic switch warm model publication: \(visible)s")
    }
}
