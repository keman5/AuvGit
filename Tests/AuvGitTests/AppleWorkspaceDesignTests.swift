import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

/// Render the real workspace without ordering or activating a window.
@MainActor
final class AppleWorkspaceDesignTests: XCTestCase {
    func testWorkspaceRemainsUsableInBothAppearancesAndAtMinimumSize() async throws {
        let app = NSApplication.shared
        let initiallyActive = app.isActive
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuvGit-Design-" + UUID().uuidString)
        let repository = try await GitRepository.initialize(at: root.appendingPathComponent("AuvGit"))
        defer { try? FileManager.default.removeItem(at: root) }
        for (key, value) in [("user.name", "Design Fixture"), ("user.email", "design@example.test"), ("commit.gpgSign", "false"), ("core.hooksPath", "/dev/null")] {
            _ = try await repository.workflowRead(["config", key, value])
        }
        let file = repository.url.appendingPathComponent("Sources/App/Workspace.swift")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let base = """
        import SwiftUI

        struct Workspace: View {
            let spacing: CGFloat = 16

            var body: some View {
                HStack(spacing: spacing) {
                    RepositorySidebar()
                    FileList()
                }
                .background(Color.white)
            }
        }

        """
        try base.write(to: file, atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["Sources/App/Workspace.swift"])
        try await repository.commit(message: "Workspace fixture")
        let updated = base.replacingOccurrences(of: "= 16", with: "= 12")
            .replacingOccurrences(of: "            FileList()", with: "            VStack(spacing: 0) {\n                FileList()\n                ComparisonPreview()\n            }")
            .replacingOccurrences(of: "Color.white", with: "WorkspaceStyle.canvas")
        try updated.write(to: file, atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["Sources/App/Workspace.swift"])
        let store = fixture(repository)
        defer { store.closeTransientSession() }
        await store.loadDiff()
        XCTAssertTrue(store.diffTitle.contains("Workspace.swift"))
        XCTAssertFalse(store.diffText.isEmpty)
        let model = BorderlessToolbarModel(original: nil)
        for (name, appearance, size) in [
            ("light", NSAppearance.Name.aqua, NSSize(width: 1280, height: 860)),
            ("dark", .darkAqua, NSSize(width: 1280, height: 860)),
            ("compact", .accessibilityHighContrastAqua, NSSize(width: 1000, height: 714))
        ] {
            let host = NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true, shellToolbarModel: model)
                .nativeFocusRoot()
                .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = EightPointFrameView(content: host)
            defer { window.close() }
            for _ in 0..<12 {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
            let tables = descendants(host, of: NSTableView.self)
            XCTAssertTrue(tables.contains { $0.numberOfRows == store.files.count }, "The file table must remain available in \(name)")
            XCTAssertTrue(tables.contains { $0.numberOfRows == store.commits.count }, "History must remain available in \(name)")
            let editor = try XCTUnwrap(descendants(host, of: CommitPlaceholderTextView.self).first)
            let editorRect = editor.convert(editor.visibleRect, to: host)
            XCTAssertGreaterThan(editorRect.width, 160, "The commit editor must not be squeezed away")
            XCTAssertGreaterThan(editorRect.height, 40)
            XCTAssertFalse(window.firstResponder is NSTextView, "Opening the workspace must not focus an input")
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(app.keyWindow === window)
            if let path = ProcessInfo.processInfo.environment["AUVGIT_DESIGN_SNAPSHOT_DIR"], let frame = window.contentView {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("workspace-\(name).png"))
            }
        }
        XCTAssertEqual(app.isActive, initiallyActive)
    }

    private func fixture(_ repository: GitRepository) -> RepositoryStore {
        let store = RepositoryStore(persistsSession: false, followsCurrentBranch: true)
        store.setApplicationActive(false)
        store.isRestoringViewState = true
        store.repository = repository; store.repositoryURL = repository.url
        store.branch = "main"
        store.recentPaths = [repository.url.path, "/Projects/AuvDock", "/Projects/AuvCast", "/Projects/Design-System"]
        store.branches = [
            .init(name: "main", isCurrent: true, isRemote: false, upstream: "origin/main"),
            .init(name: "feature/apple-workspace", isCurrent: false, isRemote: false),
            .init(name: "origin/main", isCurrent: false, isRemote: true)
        ]
        store.stashes = [.init(ref: "stash@{0}", subject: "Navigation refinements", hash: "stash")]
        store.files = [
            .init(path: "Sources/App/Workspace.swift", indexStatus: "M", worktreeStatus: " "),
            .init(path: "Sources/App/Sidebar.swift", indexStatus: " ", worktreeStatus: "M"),
            .init(path: "Sources/App/DesignTokens.swift", indexStatus: "A", worktreeStatus: " "),
            .init(path: "Resources/LegacyPalette.json", indexStatus: " ", worktreeStatus: "D"),
            .init(path: "docs/Workspace.md", indexStatus: "?", worktreeStatus: "?")
        ]
        store.selectedPaths = [store.files[0].path]
        let now = Date()
        let messages = ["Refine workspace hierarchy and navigation", "Keep file comparisons aligned while scrolling", "Cache repository presentations for instant switching", "Improve keyboard navigation and cancellation", "Add conflict resolution actions", "Update localized interface labels"]
        func hash(_ index: Int) -> String { String(format: "%08x", 0x8fa7c010 - index * 0x235489) + String(repeating: "0", count: 32) }
        store.commits = messages.enumerated().map { index, message in
            GitCommit(hash: hash(index), parents: index == messages.count - 1 ? [] : [hash(index + 1)], author: index.isMultiple(of: 2) ? "Kevin" : "Alex", date: now.addingTimeInterval(-Double(index) * 3600), subject: message, body: message, refs: index == 0 ? ["HEAD -> main", "origin/main"] : [])
        }
        store.commitMessage = "Refine workspace hierarchy and native controls\n\nUnify navigation surfaces, toolbar icons and commit actions."
        return store
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
}
