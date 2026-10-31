import AppKit
import SwiftUI
import XCTest
import AuvGitLocalization
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

    func testRehostingDoesNotPromoteAutomaticFocusButPreservesExplicitEditing() throws {
        try runApp {
            for explicit in [false, true] {
                let parent = self.window(AnyView(Text("Focus audit")))
                defer { self.close(parent) }
                try await self.activate(parent)
                let sheet = NSPanel(contentRect: .init(x: 0, y: 0, width: 380, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.isReleasedWhenClosed = false
                let content = NSView(frame: .init(x: 0, y: 0, width: 380, height: 200))
                let field = NSTextField(frame: .init(x: 20, y: 80, width: 340, height: 24))
                field.stringValue = "Keep my draft"
                content.addSubview(field); sheet.contentView = content
                parent.beginSheet(sheet, completionHandler: nil)
                let appearance = NativeFocusAppearance.forWindow(sheet)
                if explicit { appearance.beginNavigation() }
                sheet.makeFirstResponder(field)
                (sheet.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 4))
                DialogAppearance.style(sheet)
                let visible = DialogAppearance.visibleWindow(for: sheet)
                if explicit {
                    XCTAssertTrue(NativeFocusAppearance.isVisible(in: visible))
                    XCTAssertTrue((visible.firstResponder as? NSTextView)?.delegate === field)
                    XCTAssertEqual((visible.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 2, length: 4))
                } else {
                    XCTAssertTrue(visible.firstResponder === visible, "An automatically chosen field must not acquire explicit focus during rehosting")
                }
                XCTAssertEqual(field.stringValue, "Keep my draft")
            }
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
            let endpoint = try XCTUnwrap(RemoteEndpoint.parse("https://example.invalid/audit.git"))
            let authentication = RemoteAuthenticationRequest(repository: repo, operation: .push, remoteName: "origin", endpoint: endpoint,
                preferredUsername: nil, preferredSSHUsername: nil, privateKey: nil, retry: { _ in })
            let firstPush = FirstBranchPushPrompt(repository: repo, request: FirstBranchPushRequest(branch: "main", commit: "fixture", remotes: ["origin"], remoteBranches: []))
            let cases: [(String, (Model) -> AnyView)] = [
                ("AI scope", { _ in AnyView(AICommitScopeSheet(generate: { _ in XCTFail("Cancel generated a message") })) }),
                ("AI settings", { _ in AnyView(AICommitSettingsSheet()) }),
                ("Repository tools", { _ in AnyView(RepositoryTools(store: store)) }),
                ("Network", { _ in AnyView(NetworkOperationsView(store: store)) }),
                ("Workspace search", { _ in AnyView(WorkspaceSearchSheet(store: store)) }),
                ("Workspace commit", { _ in AnyView(WorkspaceCommitSheet(store: store, request: request)) }),
                ("Tags", { _ in AnyView(TagManagementView(store: store)) }),
                ("Ignore editor", { _ in AnyView(RepositoryContextEditor(store: store, target: .init(path: root.path, editor: .ignore))) }),
                ("Remote editor", { _ in AnyView(RepositoryContextEditor(store: store, target: .init(path: root.path, editor: .remote))) }),
                ("Operation log", { _ in AnyView(OperationLogView(store: store)) }),
                ("Clone repository", { _ in store.creationOperation.clone = true; return AnyView(CreateRepositorySheet(store: store)) }),
                ("Initialize repository", { _ in store.creationOperation.clone = false; return AnyView(CreateRepositorySheet(store: store)) }),
                ("Rebase", { model in AnyView(RebaseWorkflowView(store: store, onClose: { model.presented = false }).frame(width: 1000, height: 700)) }),
                ("Authentication", { model in AnyView(RemoteAuthenticationSheet(request: authentication, error: nil, isSubmitting: false, submit: { _ in XCTFail("Cancel submitted credentials") }, cancel: { model.presented = false })) }),
                ("First push", { model in AnyView(FirstBranchPushSheet(store: store, prompt: firstPush, close: { model.presented = false }, submit: { _, _ in XCTFail("Cancel pushed") })) })
            ]
            for (name, content) in cases {
                let model = Model()
                let parent = self.window(AnyView(Fixture(model: model, content: { content(model) })))
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

    func testIgnoreAndRemoteEditorsLoadReloadAndSaveInRehostedSheets() throws {
        try runApp {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try await GitRepository.initialize(at: root)
            _ = try await repo.workflowRead(["remote", "add", "origin", "https://example.invalid/old.git"])
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            await store.open(root)
            for editor in [RepositoryContextTarget.Editor.ignore, .remote] {
                let model = Model()
                let parent = self.window(AnyView(Fixture(model: model, content: {
                    AnyView(RepositoryContextEditor(store: store, target: .init(path: root.path, editor: editor)))
                })))
                defer { self.close(parent) }
                try await self.activate(parent)
                model.presented = true
                try await self.settle()
                let panel = try self.panel(parent), content = try XCTUnwrap(panel.contentView)
                let buttons = self.descendants(content).compactMap { $0 as? KeyViewProxy.Button }
                let reload = try XCTUnwrap(buttons.first { $0.title == repositoryContextText("Reload") })
                let save = try XCTUnwrap(buttons.first { $0.title == repositoryContextText("Save") })
                for _ in 0..<100 {
                    if save.isEnabled { break }
                    try await self.settle(20)
                }
                try self.capture(panel, editor == .ignore ? "ignore" : "remote")
                XCTAssertTrue(save.isEnabled, "Sheet initialization must finish despite rehosting")
                reload.performClick(nil)
                try await self.settle()
                XCTAssertTrue(save.isEnabled, "Reload must restore the editable form")
                if editor == .ignore {
                    let text = try XCTUnwrap(self.descendants(content).compactMap { $0 as? NSTextView }.first { $0.isEditable && !$0.isFieldEditor })
                    text.string = "audit-cache/\n"; text.didChangeText()
                } else {
                    let field = try XCTUnwrap(self.descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue.contains("old.git") })
                    self.type("https://example.invalid/new.git", in: field)
                }
                try await self.settle(100)
                save.performClick(nil)
                for _ in 0..<100 {
                    try await self.settle(20)
                    if !model.presented && !store.isBusy { break }
                }
                XCTAssertFalse(model.presented)
                XCTAssertNil(store.error)
            }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8), "audit-cache/\n")
            let remote = try await repo.workflowRead(["remote", "get-url", "origin"])
            XCTAssertEqual(remote.trimmingCharacters(in: .whitespacesAndNewlines), "https://example.invalid/new.git")
        }
    }

    func testTagCreationTypeControlsValidationAndActualAnnotatedTag() throws {
        try runApp {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try await GitRepository.initialize(at: root)
            for (key, value) in [("user.name", "Dialog Audit"), ("user.email", "audit@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false")] {
                _ = try await repo.workflowRead(["config", key, value])
            }
            _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "Base"])
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            await store.open(root)
            let model = Model()
            let parent = self.window(AnyView(Fixture(model: model, content: { AnyView(TagManagementView(store: store)) })))
            defer { self.close(parent) }
            try await self.activate(parent)
            model.presented = true
            try await self.settle()
            let management = try self.panel(parent)
            try self.capture(management, "tag")
            try self.click(management, x: 820, top: 44)
            try await self.settle()
            let panel = try self.nestedPanel(parent), content = try XCTUnwrap(panel.contentView)
            XCTAssertFalse(panel.firstResponder is NSControl || panel.firstResponder is NSTextView)
            let buttons = self.descendants(content).compactMap { $0 as? KeyViewProxy.Button }
            let create = try XCTUnwrap(buttons.first { $0.title == workflowText("Create tag") })
            XCTAssertFalse(create.isEnabled)
            let fields = self.descendants(content).compactMap { $0 as? NSTextField }.filter(\.isEditable)
            let name = try XCTUnwrap(fields.first)
            self.type("audit-v1", in: name)
            try await self.settle(100)
            XCTAssertTrue(create.isEnabled, "Lightweight tags need only a name and revision")
            for label in [designText("Annotated"), workflowText("Signed tag"), designText("Lightweight"), designText("Annotated")] {
                let radio = try XCTUnwrap(buttons.first { $0.title == label })
                for x in [CGFloat(8), radio.bounds.maxX - 8] {
                    let point = radio.convert(NSPoint(x: x, y: radio.bounds.midY), to: content.superview)
                    XCTAssertTrue(content.hitTest(point) === radio, "Tag type icon and label must both receive clicks")
                }
                radio.performClick(nil)
                try await self.settle(100)
                XCTAssertEqual(radio.state, .on)
                XCTAssertEqual(buttons.filter { $0.isRadio && $0.state == .on }.count, 1)
                XCTAssertEqual(create.isEnabled, label == designText("Lightweight"), "Annotated and signed tags require an annotation")
            }
            let editor = try XCTUnwrap(self.descendants(content).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor && $0.isEditable })
            editor.string = "Audited annotation"
            editor.didChangeText()
            try await self.settle(100)
            XCTAssertTrue(create.isEnabled)
            create.performClick(nil)
            for _ in 0..<100 {
                try await self.settle(20)
                if !model.presented && !store.isBusy { break }
            }
            XCTAssertFalse(model.presented)
            XCTAssertNil(store.error)
            let kind = try await repo.workflowRead(["cat-file", "-t", "refs/tags/audit-v1"])
            let annotation = try await repo.workflowRead(["for-each-ref", "--format=%(contents)", "refs/tags/audit-v1"])
            XCTAssertEqual(kind.trimmingCharacters(in: .whitespacesAndNewlines), "tag")
            XCTAssertTrue(annotation.contains("Audited annotation"))
        }
    }

    func testFullOperationOutputWaitsForUserFocusSupportsCopyAndEscape() throws {
        try runApp {
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            store.commandRecords.userCommands = [GitCommandRecord(date: Date(), directory: "/tmp/dialog-audit", command: "git status", output: "Audit output\n第二行", error: nil, duration: 0.1, exitCode: 0, operation: "status", userInitiated: true)]
            let model = Model()
            let parent = self.window(AnyView(Fixture(model: model, content: { AnyView(OperationLogView(store: store)) })))
            defer { self.close(parent) }
            try await self.activate(parent)
            model.presented = true
            try await self.settle()
            let log = try self.panel(parent)
            try self.capture(log, "log")
            try self.click(log, x: 200, top: 74)
            try await self.settle()
            try self.capture(log, "expanded-log")
            try self.click(log, x: 95, top: 105)
            try await self.settle()
            let full = try self.nestedPanel(parent), content = try XCTUnwrap(full.contentView)
            XCTAssertFalse(full.firstResponder is NSControl || full.firstResponder is NSTextView, "Opening full output must not focus its text automatically")
            let text = try XCTUnwrap(self.descendants(content).compactMap { $0 as? NSTextView }.first { $0.isSelectable && !$0.isFieldEditor })
            full.makeFirstResponder(text)
            let selectAll = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: full.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            XCTAssertTrue(NativeFocusAppearance.forWindow(full).handle(selectAll))
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: text.string.utf16.count))
            XCTAssertTrue(text.string.contains("Audit output"))
            let pasteboard = NSPasteboard.general
            let savedItems = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
                return copy
            }
            defer { pasteboard.clearContents(); if !savedItems.isEmpty { pasteboard.writeObjects(savedItems) } }
            pasteboard.clearContents()
            text.copy(nil)
            XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("Audit output\n第二行"))
            NSApp.sendEvent(try self.key(full, "\u{1b}", 53))
            try await self.settle()
            XCTAssertNil(parent.attachedSheet?.attachedSheet)
            XCTAssertTrue(model.presented, "Closing a nested detail must leave its operation log open")
        }
    }

    private func capture(_ panel: NSWindow, _ name: String) throws {
        guard ProcessInfo.processInfo.environment["AUVGIT_DIALOG_AUDIT_CAPTURE"] == "1" else { return }
        let content = try XCTUnwrap(panel.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/auvgit-audit-" + name + ".png"))
    }
    private func type(_ value: String, in field: NSTextField) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    // These coordinates exercise the actual SwiftUI hit regions in the fixed
    // 1020 pt tag and 760 pt operation-log layouts, including their labels.
    private func click(_ window: NSWindow, x: CGFloat, top: CGFloat) throws {
        let content = try XCTUnwrap(window.contentView)
        let point = content.convert(NSPoint(x: x, y: content.isFlipped ? top : content.bounds.height - top), to: nil)
        window.makeKey()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
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
        func endSheets(_ parent: NSWindow) {
            guard let sheet = parent.attachedSheet else { return }
            let visible = DialogAppearance.visibleWindow(for: sheet)
            if visible !== sheet { endSheets(visible) }
            endSheets(sheet)
            parent.endSheet(sheet)
            visible.orderOut(nil)
        }
        endSheets(window)
        window.close()
    }
    private func nestedPanel(_ parent: NSWindow) throws -> NSWindow {
        let anchor = try XCTUnwrap(parent.attachedSheet)
        let outer = DialogAppearance.visibleWindow(for: anchor)
        return DialogAppearance.visibleWindow(for: try XCTUnwrap(anchor.attachedSheet ?? outer.attachedSheet))
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
        NSRunningApplication.current.activate(options: [.activateAllWindows])
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
