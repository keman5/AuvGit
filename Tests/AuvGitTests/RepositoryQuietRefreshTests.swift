import XCTest
import Combine
@testable import AuvGit
@testable import GitCore

@MainActor
final class RepositoryQuietRefreshTests: XCTestCase {
    func testProjectSwitchSelectsFirstFileButKeepsSavedSelectionAndQuietDeselection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await GitProcess.run(at: directory, arguments: ["init"])
            for path in ["file10.txt", "file2.txt"] {
                try "\(path)\n".write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
            }
        }
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(first)
        // Transient stores default to the Log window's history mode.
        store.mode = "workspace"
        await store.loadDiff()
        XCTAssertEqual(store.selectedPaths, ["file2.txt"])
        XCTAssertEqual(store.automaticallySelectedPath, "file2.txt")
        XCTAssertTrue(store.diffText.contains("+file2.txt"))
        store.selectedPaths = ["file10.txt"]
        await store.open(second)
        store.mode = "workspace"
        XCTAssertEqual(store.selectedPaths, ["file2.txt"])
        await store.open(first)
        XCTAssertEqual(store.selectedPaths, ["file10.txt"])
        XCTAssertNil(store.automaticallySelectedPath)
        store.selectedPaths = []
        await store.refresh()
        XCTAssertTrue(store.selectedPaths.isEmpty)
        store.selectedPaths = ["file10.txt"]
        await store.open(second)
        try FileManager.default.removeItem(at: first.appendingPathComponent("file10.txt"))
        await store.open(first)
        XCTAssertEqual(store.selectedPaths, ["file2.txt"])
        XCTAssertTrue(store.diffText.contains("+file2.txt"))
    }
    func testChangedFilesystemRefreshReusesStatusAndStateReads() async throws {
        let backgroundKey = "preferences.backgroundRefresh", previousBackground = UserDefaults.standard.object(forKey: "preferences.backgroundRefresh")
        UserDefaults.standard.set(false, forKey: backgroundKey)
        defer { if let previousBackground { UserDefaults.standard.set(previousBackground, forKey: backgroundKey) } else { UserDefaults.standard.removeObject(forKey: backgroundKey) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        // Opening also queues the initial remote/status sweep; count only the
        // explicit filesystem refresh below, not that independent background read.
        await store.cancelBackgroundRepositorySync()
        let wrapper = root.appendingPathComponent(".git/test-git")
        try """
        #!/bin/sh
        # Conflict recovery metadata is a separate read, not the index snapshot under test.
        case " $* " in
            *" --resolve-undo "*) exec /usr/bin/git "$@" ;;
        esac
        for arg in "$@"; do
            case "$arg" in
                status|show-ref|ls-files) echo "$arg" >> ".git/read-$arg" ;;
            esac
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: "auvgit.git.executablePath")
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        try "new content\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        await store.refreshIfChanged()
        XCTAssertEqual(store.files.map(\.path), ["file.txt"])
        for command in ["status", "show-ref", "ls-files"] {
            let reads = try String(contentsOf: root.appendingPathComponent(".git/read-" + command), encoding: .utf8).split(separator: "\n")
            XCTAssertEqual(reads.count, 1, "Changed filesystem refresh must reuse its initial \(command) read")
        }
    }

    func testFileStatusPublishesBeforeSlowRepositoryMetadata() async throws {
        let backgroundKey = "preferences.backgroundRefresh", previousBackground = UserDefaults.standard.object(forKey: "preferences.backgroundRefresh")
        UserDefaults.standard.set(false, forKey: backgroundKey)
        defer { if let previousBackground { UserDefaults.standard.set(previousBackground, forKey: backgroundKey) } else { UserDefaults.standard.removeObject(forKey: backgroundKey) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        let file = root.appendingPathComponent("file.txt")
        try "new file\n".write(to: file, atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(root)
        _ = try await GitProcess.run(at: root, arguments: ["add", "file.txt"])

        // Block metadata until the published status releases it. The timeout
        // only prevents a broken implementation from hanging the test.
        let wrapper = root.appendingPathComponent(".git/test-git")
        let release = root.appendingPathComponent(".git/release-metadata")
        let finished = root.appendingPathComponent(".git/metadata-finished")
        try """
        #!/bin/sh
        for arg in "$@"; do
            if [ "$arg" = "for-each-ref" ]; then
                attempts=0
                while [ ! -f .git/release-metadata ] && [ "$attempts" -lt 500 ]; do
                    sleep 0.01
                    attempts=$((attempts + 1))
                done
                touch .git/metadata-finished
            fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: "auvgit.git.executablePath")
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        var publishedBeforeMetadata = false
        let observation = store.$files.dropFirst().sink { files in
            guard files.first(where: { $0.path == "file.txt" })?.isStaged == true else { return }
            publishedBeforeMetadata = !FileManager.default.fileExists(atPath: finished.path)
            _ = FileManager.default.createFile(atPath: release.path, contents: Data())
        }
        defer { observation.cancel() }
        await store.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path), "The wrapper must exercise the metadata barrier")
        XCTAssertTrue(publishedBeforeMetadata, "Staged status must publish before branch/stash metadata finishes")
        XCTAssertTrue(store.files.first(where: { $0.path == "file.txt" })?.isStaged == true)
    }

    func testSelectingSameRepositoryKeepsHistoryAndRefreshesChangedTextWithoutBusyFade() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: alias); try? FileManager.default.removeItem(at: root) }
        _ = try await GitProcess.run(at: root, arguments: ["init"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.name", "Test"])
        _ = try await GitProcess.run(at: root, arguments: ["config", "user.email", "test@example.com"])
        let file = root.appendingPathComponent("file.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await GitProcess.run(at: root, arguments: ["add", "file.txt"])
        _ = try await GitProcess.run(at: root, arguments: ["commit", "-m", "Fixture"])
        try "first change\n".write(to: file, atomically: true, encoding: .utf8)
        let store = RepositoryStore(persistsSession: false)
        await store.open(root)
        store.mode = "workspace"; store.selectedPaths = ["file.txt"]
        await store.loadDiff()
        let commits = store.commits, generation = store.filesGeneration
        store.historySearch = "keep this filter"
        var busyTransitions: [Bool] = []
        let observation = store.$isBusy.dropFirst().sink { busyTransitions.append($0) }
        defer { observation.cancel() }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try "second content with same M status\n".write(to: file, atomically: true, encoding: .utf8)
        await store.open(alias)
        XCTAssertEqual(store.commits, commits)
        XCTAssertEqual(store.historySearch, "keep this filter")
        XCTAssertEqual(store.filesGeneration, generation)
        XCTAssertTrue(store.diffText.contains("second content with same M status"))
        XCTAssertTrue(busyTransitions.isEmpty)
        XCTAssertTrue(RepositoryStore.sameRepositoryLocation(root, alias))
    }
}
