import AppKit
import SwiftUI
import XCTest
import GitCore
@testable import AuvGit

/// No window is shown or activated, including the auxiliary comparison host.
@MainActor
final class WorkspaceFilesLifecycleTests: XCTestCase {
    private final class State: ObservableObject {
        @Published var files: [GitFile] = []
        @Published var repository = GitRepository(url: URL(fileURLWithPath: "/tmp/auvgit-list-lifecycle-a"))
        @Published var selection: Set<String> = []
        @Published var filter = ""
        @Published var tree = false
        @Published var mounted = true
        @Published var revision = 0
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        var body: some View {
            VStack {
                if state.mounted {
                    WorkspaceFilesPane(files: state.files, selection: $state.selection, filter: $state.filter,
                        treeMode: $state.tree, isBusy: false, onAction: { _, _ in },
                        treeContent: { _ in Color.clear }, repository: state.repository)
                }
                Text(String(state.revision))
            }.frame(width: 800, height: 350)
        }
    }
    func testClosingAuxiliaryWindowAndRehostingKeepsFilesAndSelection() async throws {
        _ = NSApplication.shared
        let state = State()
        state.files = files("first", count: 600)
        let host = NSHostingView(rootView: Fixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        try await waitForFiles(in: host, count: 600, prefix: "first")
        state.selection = ["first/file5.swift"]
        for _ in 0..<12 {
            let comparison = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            comparison.isReleasedWhenClosed = false
            comparison.contentView = NSHostingView(rootView: Text("Comparison"))
            comparison.performClose(nil)
            host.rootView = Fixture(state: state)
            state.revision += 1
            try await waitForFiles(in: host, count: 600, prefix: "first")
            XCTAssertEqual(table(in: host)?.selectedRowIndexes, IndexSet(integer: 5))
            XCTAssertFalse(comparison.isVisible)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testInterruptedPreparationAndRapidRepositoryChangesRecoverLatestRows() async throws {
        _ = NSApplication.shared
        let state = State()
        let host = NSHostingView(rootView: Fixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        for index in 0..<8 {
            state.files = files("large\(index)", count: 3000)
            state.filter = "file"
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            state.mounted = false
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(2))
            state.repository = GitRepository(url: URL(fileURLWithPath: "/tmp/auvgit-list-lifecycle-\(index)"))
            state.files = files("latest\(index)", count: 37)
            state.filter = ""
            state.mounted = true
            try await waitForFiles(in: host, count: 37, prefix: "latest\(index)")
        }
        XCTAssertFalse(window.isVisible)
    }
    private func files(_ prefix: String, count: Int) -> [GitFile] {
        (0..<count).map { GitFile(path: "\(prefix)/file\($0).swift", indexStatus: " ", worktreeStatus: "M") }
    }
    private func table(in view: NSView) -> WorkspaceNativeFilesTable.FileTable? {
        (view as? WorkspaceNativeFilesTable.FileTable) ?? view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }
    private func waitForFiles(in host: NSView, count: Int, prefix: String) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            host.layoutSubtreeIfNeeded()
            if let table = table(in: host), let model = table.coordinator?.parent,
               table.numberOfRows == count, model.isReady, model.rows.first?.path.hasPrefix(prefix + "/") == true {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let table = table(in: host)
        XCTFail("File pane failed to recover: rows=\(table?.numberOfRows ?? -1), ready=\(table?.coordinator?.parent.isReady ?? false)")
    }
}
