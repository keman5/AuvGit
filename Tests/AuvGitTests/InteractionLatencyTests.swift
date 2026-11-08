import XCTest
import AppKit
@testable import AuvGit
@testable import GitCore

/// Background-only regressions: no window activation or visible test windows.
@MainActor
final class InteractionLatencyTests: XCTestCase {
    func testLargeDraftTypingCoalescesAnalysisAndKeepsLatestTextAndAlignment() async throws {
        _ = NSApplication.shared
        let source = (0..<2_000).map { "let item\($0) = \($0)" }.joined(separator: "\n")
        var draft = source
        func editor() -> ComparisonEditor {
            ComparisonEditor(columns: [
                .init(id: "head", title: "HEAD", text: source, isEditable: false, message: nil),
                .init(id: "worktree", title: "Result", text: draft, isEditable: true, message: nil)
            ], wrapLines: false, showLineNumbers: true, synchronizeScroll: true,
                search: "", navigation: 0, changeNavigation: 0, onEdit: { _, text in draft = text }, languagePath: "file.swift")
        }
        let split = ComparisonSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        split.isVertical = true
        let coordinator = ComparisonEditor.Coordinator(editor()); coordinator.split = split; coordinator.update(editor())
        let texts = split.subviews.compactMap { $0.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? ComparisonTextView }.first }
        let text = try XCTUnwrap(texts.last)
        let before = coordinator.decorationBuildCount
        let start = Date()
        for index in 0..<20 {
            text.string = source + "\nlet inserted = \(index)"
            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            coordinator.update(editor())
        }
        let typingDuration = Date().timeIntervalSince(start)
        XCTAssertTrue(coordinator.analyzingEdit)
        XCTAssertEqual(coordinator.decorationBuildCount, before, "Typing must not synchronously rebuild full-document decorations")
        XCTAssertTrue(draft.hasSuffix("let inserted = 19"), "Draft saving must not wait for analysis")
        let deadline = Date().addingTimeInterval(5)
        while coordinator.analyzingEdit, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(coordinator.analyzingEdit)
        XCTAssertEqual(coordinator.decorationBuildCount, before + 1)
        XCTAssertTrue(coordinator.lineDiffs["worktree"]?.targetChangedLines.contains(2_000) == true)
        let rails = split.subviews.flatMap { $0.subviews.compactMap { $0 as? ComparisonActionRail } }
        XCTAssertTrue(rails.allSatisfy { !$0.isHidden })
        XCTAssertEqual(text.string, draft)
        print("Background typing fixture: 20 edits, \(source.utf16.count) UTF-16 units, \(typingDuration)s synchronous work, one decoration pass")
    }

    func testActivationRefreshesSelectedProjectWithoutScanningHiddenSession() async throws {
        let key = "preferences.backgroundRefresh", defaults = UserDefaults.standard, previous = UserDefaults.standard.object(forKey: "preferences.backgroundRefresh")
        defaults.set(false, forKey: key)
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await GitRepository.initialize(at: root.appendingPathComponent("hidden"))
        let second = try await GitRepository.initialize(at: root.appendingPathComponent("active"))
        let initial = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        let projects = WorkspaceProjects(initial: initial)
        defer { projects.sessions.forEach { $0.closeTransientSession() } }
        await initial.open(first.url); await projects.active.open(second.url)
        let hidden = try XCTUnwrap(projects.sessions.first { $0.repositoryURL == first.url })
        let active = projects.active
        XCTAssertFalse(hidden === active)
        for store in projects.sessions { store.setApplicationActive(false) }
        for repo in [first, second] { try "changed".write(to: repo.url.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8) }
        defaults.set(true, forKey: key)
        for store in projects.sessions { store.setApplicationActive(true) }
        let deadline = Date().addingTimeInterval(3)
        while !active.files.contains(where: { $0.path == "new.txt" }), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(active.files.contains { $0.path == "new.txt" })
        XCTAssertFalse(hidden.files.contains { $0.path == "new.txt" }, "Hidden project activation must not compete with the selected project's refresh")
    }

    func testStagingScopesSafetyReadsToSelectedPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        try "selected".write(to: root.appendingPathComponent("selected.txt"), atomically: true, encoding: .utf8)
        try "unrelated".write(to: root.appendingPathComponent("unrelated.txt"), atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent(".git/scoped-git")
        try """
        #!/bin/sh
        echo "$*" >> .git/scoped-reads
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        try await repo.stage(paths: ["selected.txt"])
        let trace = try String(contentsOf: root.appendingPathComponent(".git/scoped-reads"), encoding: .utf8)
        XCTAssertTrue(trace.contains("--untracked-files=all -- selected.txt"))
        XCTAssertTrue(trace.contains("ls-files -z -- selected.txt"))
        let files = try await repo.status()
        XCTAssertTrue(files.first { $0.path == "selected.txt" }?.isStaged == true)
        XCTAssertTrue(files.first { $0.path == "unrelated.txt" }?.isUntracked == true)
    }

    func testStageAndUnstageRefreshOnlyTouchedRowsAndPreserveOtherRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for path in ["selected.txt", "unrelated.txt"] {
            try path.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = root
        await store.refresh(); store.setApplicationActive(false)
        let unrelated = store.files.first { $0.path == "unrelated.txt" }
        let wrapper = root.appendingPathComponent(".git/row-git")
        try """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = status ]; then echo "$*" >> .git/row-status; fi
        done
        exec /usr/bin/git "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let key = "auvgit.git.executablePath", previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(wrapper.path, forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        store.selectedPaths = ["selected.txt"]
        for staging in [true, false] {
            if staging { store.stageSelection() } else { store.unstageSelection() }
            let deadline = Date().addingTimeInterval(3)
            while (store.isBusy || store.files.first(where: { $0.path == "selected.txt" })?.isStaged != staging), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(store.files.first { $0.path == "selected.txt" }?.isStaged, staging)
            XCTAssertEqual(store.files.first { $0.path == "unrelated.txt" }, unrelated)
        }
        let trace = try String(contentsOf: root.appendingPathComponent(".git/row-status"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(trace.count, 4)
        XCTAssertTrue(trace.allSatisfy { $0.hasSuffix("-- selected.txt") }, "Both preflight and post-write status must stay scoped")
    }

    func testStagingRenameEndsSeparatelyMergesIntoOneCanonicalRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for args in [["config", "user.name", "Fixture"], ["config", "user.email", "fixture@example.invalid"], ["config", "commit.gpgsign", "false"]] { _ = try await repo.workflowRead(args) }
        try "original\n".write(to: root.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["old.txt"]); try await repo.commit(message: "base")
        try FileManager.default.moveItem(at: root.appendingPathComponent("old.txt"), to: root.appendingPathComponent("new.txt"))
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        defer { store.closeTransientSession() }
        store.repository = repo; store.repositoryURL = root
        await store.refresh(); store.setApplicationActive(false)
        for path in ["new.txt", "old.txt"] {
            store.selectedPaths = [path]; store.stageSelection()
            let deadline = Date().addingTimeInterval(3)
            while (store.isBusy || (path == "new.txt" ? store.files.first(where: { $0.path == path })?.isStaged != true : store.files.first?.originalPath != "old.txt")), Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        let actual = try await repo.status()
        XCTAssertEqual(store.files, actual)
        XCTAssertEqual(store.files.count, 1)
        XCTAssertEqual(store.files.first?.path, "new.txt")
        XCTAssertEqual(store.files.first?.originalPath, "old.txt")
        let scoped = try await repo.status(paths: ["new.txt"])
        XCTAssertEqual(scoped, actual, "A scoped read must preserve the rename origin")
    }
}
