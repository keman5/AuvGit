import AppKit
import XCTest
import GitCore
@testable import AuvGit

@MainActor
final class LogWindowSelectionFocusTests: XCTestCase {
    func testOpeningRequestedCommitFocusesHistoryAfterFilesLoad() throws {
        let app = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await self.verifyFocus() } catch { failure = error }
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: false)
            }
        }
        app.run()
        if let failure { throw failure }
    }
    private func verifyFocus() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(policy) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try await GitRepository.initialize(at: root)
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
            _ = try await repo.workflowRead(["config", key, value])
        }
        try "base\n".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        try await repo.stage(paths: ["file"]); try await repo.commit(message: "Base")
        let hash = try await repo.workflowRevision("HEAD")
        LogPresenter.show(repository: repo, selectedCommit: hash)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title.hasPrefix(root.lastPathComponent) })
        defer { window.close() }
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(50))
        } while !NSApp.isActive && ContinuousClock.now < deadline
        _ = try XCTUnwrap(NSApp.isActive ? NSApp : nil, "Focus checks require an active AppKit host")
        func graph(in view: NSView) -> CommitGraphView? {
            if let graph = view as? CommitGraphView { return graph }
            for child in view.subviews { if let graph = graph(in: child) { return graph } }
            return nil
        }
        var target: NSTableView?
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if let graph = window.contentView.flatMap({ graph(in: $0) }), graph.nativeSelected {
                var parent = graph.superview
                while let view = parent, !(view is NSTableView) { parent = view.superview }
                target = parent as? NSTableView
                if window.firstResponder === target { break }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let history = try XCTUnwrap(target)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.firstResponder === history, "Requested history must own focus; got \(String(describing: window.firstResponder))")
    }
}
