import AppKit
import SwiftUI
import XCTest
@testable import GitCore
@testable import AuvGit

@MainActor
final class FetchRemoteBranchesSheetTests: XCTestCase {
    func testHiddenSheetLoadsSelectsAndFetchesAnAdditionalBranch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git"), producer = root.appendingPathComponent("producer")
        _ = try await GitProcess.run(at: root, arguments: ["init", "--bare", "--initial-branch=main", remote.path])
        _ = try await GitProcess.run(at: root, arguments: ["clone", remote.path, producer.path])
        _ = try await GitProcess.run(at: producer, arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"])
        for branch in ["main", "feature/extra"] {
            _ = try await GitProcess.run(at: producer, arguments: ["push", "origin", "HEAD:refs/heads/" + branch])
        }
        let clone = root.appendingPathComponent("clone")
        _ = try await GitProcess.run(at: root, arguments: ["clone", "--single-branch", "--branch", "main", remote.path, clone.path])
        let store = RepositoryStore(persistsSession: false)
        defer { store.closeTransientSession() }
        await store.open(clone)
        let repository = try XCTUnwrap(store.repository)
        var closed = false
        let host = NSHostingView(rootView: FetchRemoteBranchesSheet(store: store,
            prompt: FetchRemoteBranchesPrompt(repository: repository, remote: "origin"), close: { closed = true }).nativeFocusRoot())
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func buttons() -> [NSButton] { descendants(host).compactMap { $0 as? NSButton } }
        func settle(until condition: () -> Bool) async throws {
            for _ in 0..<300 {
                host.layoutSubtreeIfNeeded()
                panel.setContentSize(host.fittingSize)
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Sheet did not reach the expected state")
        }
        try await settle { buttons().contains { $0.title == "feature/extra" } && !store.isBusy }
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.firstResponder is NSControl)
        let fetch = try XCTUnwrap(buttons().first { $0.title == sidebarRefinementText("Fetch Selected Branches") })
        XCTAssertFalse(fetch.isEnabled)
        let branch = try XCTUnwrap(buttons().first { $0.title == "feature/extra" })
        branch.performClick(nil)
        try await settle { fetch.isEnabled }
        fetch.performClick(nil)
        try await settle { closed && !store.isBusy }
        XCTAssertTrue(store.repository === repository)
        let current = try await repository.workflowRead(["symbolic-ref", "--short", "HEAD"])
        XCTAssertEqual(current.trimmingCharacters(in: .whitespacesAndNewlines), "main")
        let remaining = try await repository.unfetchedRemoteBranches(remote: "origin")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(panel.isVisible)
    }
}
