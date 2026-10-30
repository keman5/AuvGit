import AppKit
import SwiftUI
import XCTest
@testable import AuvGit
@testable import GitCore

@MainActor
final class DialogOperationAuditTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var presented = false
        var confirmations = 0
    }
    private struct Fixture: View {
        @ObservedObject var model: Model
        let content: () -> AnyView
        var body: some View {
            Text("Dialog audit").frame(width: 1000, height: 760)
                .auvGitSheet(isPresented: $model.presented) { content() }
        }
    }
    private struct AlertFixture: View {
        @ObservedObject var model: Model
        let disabled: Bool
        var body: some View {
            Text("Alert audit").frame(width: 500, height: 400)
                .auvGitAlert("Error", isPresented: $model.presented) {
                    AuvGitAlertButton("OK") { model.confirmations += 1 }.disabled(disabled)
                } message: { Text("Diagnostic output") }
        }
    }

    func testSingleAcknowledgementEscapeNeverRunsPositiveActionAndRespectsDisabledState() throws {
        try runApp {
            for disabled in [false, true] {
                let model = Model()
                let parent = self.window(AnyView(AlertFixture(model: model, disabled: disabled)))
                defer { self.close(parent) }
                try await self.activate(parent)
                model.presented = true
                try await self.settle()
                let panel = try self.panel(parent)
                NSApp.sendEvent(try self.key(panel, "\u{1b}", 53))
                try await self.settle()
                XCTAssertEqual(model.presented, disabled, "Esc closes an acknowledgement unless its action is disabled")
                XCTAssertEqual(model.confirmations, 0, "Esc must never execute an affirmative callback")
            }
        }
    }

    func testMajorDialogCancelButtonsAndEscapeFromFocusedInput() throws {
        try runApp {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try await GitRepository.initialize(at: root)
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            await store.open(root)
            let request = WorkspaceCommitRequest(repository: repo, message: "Audit", hasTrackedChanges: false)
            let cases: [(String, () -> AnyView)] = [
                ("AI scope", { AnyView(AICommitScopeSheet(generate: { _ in XCTFail("Cancel generated a message") })) }),
                ("AI settings", { AnyView(AICommitSettingsSheet()) }),
                ("Repository tools", { AnyView(RepositoryTools(store: store)) }),
                ("Network", { AnyView(NetworkOperationsView(store: store)) }),
                ("Workspace search", { AnyView(WorkspaceSearchSheet(store: store)) }),
                ("Workspace commit", { AnyView(WorkspaceCommitSheet(store: store, request: request)) }),
                ("Tags", { AnyView(TagManagementView(store: store)) }),
                ("Ignore editor", { AnyView(RepositoryContextEditor(store: store, target: .init(path: root.path, editor: .ignore))) }),
                ("Remote editor", { AnyView(RepositoryContextEditor(store: store, target: .init(path: root.path, editor: .remote))) }),
                ("Operation log", { AnyView(OperationLogView(store: store)) }),
                ("Create repository", { AnyView(CreateRepositorySheet(store: store)) })
            ]
            for (name, content) in cases {
                let model = Model()
                let parent = self.window(AnyView(Fixture(model: model, content: content)))
                defer { self.close(parent) }
                try await self.activate(parent)
                for useEscape in [false, true] {
                    model.presented = true
                    try await self.settle()
                    let panel = try self.panel(parent)
                    let content = try XCTUnwrap(panel.contentView)
                    XCTAssertFalse(panel.firstResponder is NSControl || panel.firstResponder is NSTextView, "\(name) stole focus")
                    let cancel = try XCTUnwrap(self.descendants(content).compactMap { $0 as? KeyViewProxy.Button }
                        .first { $0.declaredKeyEquivalent == "\u{1b}" && $0.isEnabled }, "\(name) lacks enabled Cancel/Close")
                    let point = cancel.convert(NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY), to: content.superview)
                    XCTAssertTrue(content.hitTest(point) === cancel, "\(name) cancel has an obstructed hit area")
                    if useEscape {
                        // Escape must work after a text field/editor receives input as well.
                        if let input = self.descendants(content).first(where: { view in
                            if let field = view as? NSTextField { return field.isEditable && field.isEnabled }
                            return (view as? NSTextView)?.isEditable == true
                        }) { panel.makeFirstResponder(input) }
                        NSApp.sendEvent(try self.key(panel, "\u{1b}", 53))
                    } else { cancel.performClick(nil) }
                    try await self.settle()
                    XCTAssertFalse(model.presented, "\(name) failed \(useEscape ? "Escape" : "mouse cancellation")")
                }
            }
            XCTAssertFalse(store.isBusy)
            let status = try await repo.status()
            XCTAssertTrue(status.isEmpty, "Cancel operations must not alter the repository")
        }
    }

    func testAIScopeWholeLabelSelectionKeyboardAndGenerateCallback() throws {
        try runApp {
            let defaults = UserDefaults.standard
            let original = defaults.object(forKey: AICommitScopeChoice.key)
            defer {
                if let original { defaults.set(original, forKey: AICommitScopeChoice.key) }
                else { defaults.removeObject(forKey: AICommitScopeChoice.key) }
            }
            defaults.removeObject(forKey: AICommitScopeChoice.key)
            let model = Model()
            var generated: AICommitScope?
            let parent = self.window(AnyView(Fixture(model: model, content: {
                AnyView(AICommitScopeSheet { scope in generated = scope; model.presented = false })
            })))
            defer { self.close(parent) }
            try await self.activate(parent)
            model.presented = true
            try await self.settle()
            let panel = try self.panel(parent), content = try XCTUnwrap(panel.contentView)
            let buttons = self.descendants(content).compactMap { $0 as? KeyViewProxy.Button }
            let workspace = try XCTUnwrap(buttons.first { $0.title == aiCommitText("All workspace changes") })
            let staged = try XCTUnwrap(buttons.first { $0.title == aiCommitText("Staged files only") })
            for button in [workspace, staged, workspace] {
                for x in [CGFloat(8), button.bounds.maxX - 8] {
                    let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: content.superview)
                    XCTAssertTrue(content.hitTest(point) === button, "Both icon and label must be clickable")
                }
                button.performClick(nil)
                try await self.settle(50)
                XCTAssertEqual(button.state, .on)
                XCTAssertEqual([workspace, staged].filter { $0.state == .on }.count, 1)
            }
            panel.makeFirstResponder(staged)
            staged.keyDown(with: try self.key(panel, " ", 49))
            try await self.settle(50)
            XCTAssertEqual(staged.state, .on)
            let generate = try XCTUnwrap(buttons.first { $0.title == aiCommitText("Generate") })
            generate.performClick(nil)
            try await self.settle()
            XCTAssertEqual(generated, .staged)
            XCTAssertEqual(AICommitScopeChoice.remembered(), .staged)
            XCTAssertFalse(model.presented)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func window(_ content: AnyView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 50, y: 50, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        return window
    }
    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
    }
    private func panel(_ parent: NSWindow) throws -> NSWindow {
        DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
    }
    private func key(_ panel: NSWindow, _ text: String, _ code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    private func settle(_ milliseconds: Int = 400) async throws { try await Task.sleep(for: .milliseconds(milliseconds)) }
    private func activate(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        try await settle(100)
    }
    private func runApp(_ body: @escaping @MainActor () async throws -> Void) throws {
        let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(policy) }
        var failure: Error?
        Task { @MainActor in
            do { try await body() } catch { failure = error }
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { app.postEvent(wake, atStart: false) }
        }
        app.run()
        if let failure { throw failure }
    }
}
