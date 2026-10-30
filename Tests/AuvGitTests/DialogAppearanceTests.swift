import AppKit
import SwiftUI
import AuvGitLocalization
import XCTest
@testable import GitCore
@testable import AuvGit

@MainActor
final class DialogAppearanceTests: XCTestCase {
    private final class ResetSheetModel: ObservableObject {
        @Published var request: HistoryResetRequest?
    }
    private struct ResetSheetFixture: View {
        @ObservedObject var model: ResetSheetModel
        let store: RepositoryStore
        var body: some View {
            Text("Reset parent").frame(width: 650, height: 600)
                .auvGitSheet(item: $model.request) { HistoryResetSheet(store: store, request: $0) }
        }
    }
    func testAdvancedResetClickTargetsKeyboardCancelAndSoftReset() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try await GitRepository.initialize(at: root)
            for (key, value) in [("user.name", "Reset Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
                _ = try await repo.workflowRead(["config", key, value])
            }
            _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "Base"])
            let commits = try await repo.log()
            let commit = try XCTUnwrap(commits.first)
            _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "Second"])
            let originalHead = try await repo.workflowRevision("HEAD")
            let draft = root.appendingPathComponent("draft.txt")
            try "Staged content".write(to: draft, atomically: true, encoding: .utf8)
            try await repo.stage(paths: ["draft.txt"])
            try "Unstaged content".write(to: draft, atomically: true, encoding: .utf8)
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            await store.open(root)
            let model = ResetSheetModel()
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.contentView = NSHostingView(rootView: ResetSheetFixture(model: model, store: store))
            defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) }; parent.close() }
            try await self.activateFixture(parent)
            model.request = HistoryResetRequest(commit: commit, repositoryURL: try XCTUnwrap(store.repositoryURL), advanced: true)
            for _ in 0..<60 { try await Task.sleep(for: .milliseconds(10)) }
            let panel = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
            let content = try XCTUnwrap(panel.contentView)
            @MainActor func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
            let actions = buttons(content)
            XCTAssertFalse(panel.firstResponder is NSControl)
            let confirm = try XCTUnwrap(actions.first { $0.title == L10n.text("confirm", table: "HistoryReset") })
            XCTAssertTrue(confirm.isEnabled)
            for mode in GitResetMode.allCases {
                let button = try XCTUnwrap(actions.first { $0.title == L10n.text(mode.rawValue, table: "HistoryReset") })
                for x in [CGFloat(8), button.bounds.maxX - 8] {
                    let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: content.superview)
                    XCTAssertTrue(content.hitTest(point) === button, "Radio \(mode) icon and label must receive clicks")
                }
                button.performClick(nil)
                for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(button.state, .on)
                XCTAssertEqual(actions.filter { ($0 as? KeyViewProxy.Button)?.isRadio == true && $0.state == .on }.count, 1)
            }
            let cancel = try XCTUnwrap(actions.first { $0.title == workflowText("Cancel") })
            let point = cancel.convert(NSPoint(x: cancel.bounds.midX, y: cancel.bounds.midY), to: content.superview)
            XCTAssertTrue(content.hitTest(point) === cancel)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertTrue(panel.performKeyEquivalent(with: escape))
            for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(model.request)
            let head = try await repo.workflowRevision("HEAD")
            XCTAssertEqual(head, originalHead)

            // Present again and exercise the real confirm path using a safe
            // soft reset, keeping both staged and unstaged fixture contents.
            model.request = HistoryResetRequest(commit: commit, repositoryURL: try XCTUnwrap(store.repositoryURL), advanced: true)
            for _ in 0..<60 { try await Task.sleep(for: .milliseconds(10)) }
            let resetPanel = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
            let resetContent = try XCTUnwrap(resetPanel.contentView)
            let resetActions = buttons(resetContent)
            let soft = try XCTUnwrap(resetActions.first { $0.title == L10n.text("soft", table: "HistoryReset") })
            XCTAssertFalse(resetPanel.firstResponder is NSControl)
            resetPanel.recalculateKeyViewLoop()
            let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: resetPanel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            for _ in 0..<10 {
                NSApp.sendEvent(tab)
                if resetPanel.firstResponder === soft { break }
            }
            XCTAssertTrue(resetPanel.firstResponder === soft)
            let space = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: resetPanel.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            soft.keyDown(with: space)
            for _ in 0..<5 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(soft.state, .on)
            let reset = try XCTUnwrap(resetActions.first { $0.title == L10n.text("confirm", table: "HistoryReset") })
            XCTAssertTrue(reset.isEnabled)
            let resetPoint = reset.convert(NSPoint(x: reset.bounds.midX, y: reset.bounds.midY), to: resetContent.superview)
            XCTAssertTrue(resetContent.hitTest(resetPoint) === reset)
            reset.performClick(nil)
            for _ in 0..<300 {
                try await Task.sleep(for: .milliseconds(10))
                if model.request == nil && !store.isBusy { break }
            }
            XCTAssertNil(model.request)
            XCTAssertFalse(store.isBusy)
            XCTAssertNil(store.error)
            let resetHead = try await repo.workflowRevision("HEAD")
            let staged = try await repo.workflowRead(["show", ":draft.txt"])
            XCTAssertEqual(resetHead, commit.hash)
            XCTAssertEqual(staged, "Staged content")
            XCTAssertEqual(try String(contentsOf: draft, encoding: .utf8), "Unstaged content")
        }
    }
    func testLatePrimaryRegistrationOverridesRewrittenCancelShortcut() throws {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        let cancel = KeyViewProxy.Button(title: "Cancel", target: nil, action: nil)
        cancel.declaredKeyEquivalent = "\u{1b}"
        cancel.keyEquivalent = "\u{1b}"
        content.addSubview(cancel)
        DialogAppearance.configureDefaultButton(in: window)
        XCTAssertTrue(window.defaultButtonCell === cancel.cell)
        cancel.keyEquivalent = "\r" // AppKit can rewrite the early default's live shortcut.
        let pull = KeyViewProxy.Button(title: "Pull", target: nil, action: nil)
        pull.declaredKeyEquivalent = "\r"; pull.keyEquivalent = "\r"; pull.isPrimaryAction = true
        content.addSubview(pull)
        DialogAppearance.configureDefaultButton(in: window)
        XCTAssertTrue(window.defaultButtonCell === pull.cell)
        pull.isEnabled = false
        DialogAppearance.configureDefaultButton(in: window)
        XCTAssertTrue(window.defaultButtonCell === cancel.cell)
        pull.isEnabled = true
        DialogAppearance.configureDefaultButton(in: window)
        XCTAssertTrue(window.defaultButtonCell === pull.cell)
        var cancelled = false
        cancel.activate = { cancelled = true }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(cancel.performKeyEquivalent(with: escape))
        XCTAssertTrue(cancelled)
    }
    func testPullDefaultActionIsPullWithoutTakingKeyboardFocus() throws {
        try runApplicationFixture {
            _ = NSApplication.shared
            let policy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            defer { NSApp.setActivationPolicy(policy) }
            var executed: NetworkOperation?
            var cancelled = false
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PullOperationConfirmation(hint: nil, cancel: { cancelled = true }, execute: { executed = $0 }).nativeFocusRoot())
            defer { window.close() }
            try await self.activateFixture(window)
            try await Task.sleep(for: .milliseconds(150))
            DialogAppearance.configureDefaultButton(in: window)
            let cell = try XCTUnwrap(window.defaultButtonCell)
            XCTAssertEqual(cell.keyEquivalent, "\r", "Pull must be the default, not Cancel or Fetch")
            XCTAssertTrue(window.firstResponder === window)
            XCTAssertFalse(NativeFocusAppearance.isVisible(in: window))
            let button = try XCTUnwrap(cell.controlView as? NSButton)
            XCTAssertEqual(button.title, networkText("pull"))
            let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
            NSApp.sendEvent(tab)
            XCTAssertTrue(NativeFocusAppearance.isVisible(in: window))
            XCTAssertTrue(window.firstResponder is KeyViewProxy.Button)
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            XCTAssertTrue(window.performKeyEquivalent(with: escape))
            XCTAssertTrue(cancelled)
            window.makeFirstResponder(window)
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertTrue(window.performKeyEquivalent(with: enter))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(executed, .pull)
        }
    }
    func testRemoteBranchNamePromptUsesClickableNativeSaveButton() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = try await GitRepository.initialize(at: root)
            for (key, value) in [("user.name", "Branch Fixture"), ("user.email", "fixture@example.invalid"), ("commit.gpgsign", "false")] {
                _ = try await repo.workflowRead(["config", key, value])
            }
            _ = try await repo.workflowRead(["commit", "--allow-empty", "-m", "Base"])
            let oid = try await repo.workflowRevision("HEAD")
            _ = try await repo.workflowRead(["remote", "add", "origin", "/unused-local-remote"])
            _ = try await repo.workflowRead(["update-ref", "refs/remotes/origin/website/app-store", oid])
            try "Unsaved workspace draft".write(to: root.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            await store.open(root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: MainWindow(store: store, usesBorderlessToolbar: true).nativeFocusRoot())
            window.contentView = host; window.center()
            defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
            try await self.activateFixture(window)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            @MainActor func branchCoordinator(in view: NSView) -> NativeBranchTable.Coordinator? {
                if let table = view as? NSTableView, let coordinator = table.delegate as? NativeBranchTable.Coordinator { return coordinator }
                return view.subviews.lazy.compactMap { branchCoordinator(in: $0) }.first
            }
            let coordinator = try XCTUnwrap(branchCoordinator(in: host))
            let row = try XCTUnwrap(coordinator.rows.firstIndex { $0.id == "remote:origin/website/app-store" })
            let menu = try XCTUnwrap(coordinator.menu(row: row))
            coordinator.performMenuAction(try XCTUnwrap(menu.items.first))
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
            let sheet = try XCTUnwrap(window.attachedSheet)
            let visible = DialogAppearance.visibleWindow(for: sheet)
            let button = try XCTUnwrap(visible.defaultButtonCell?.controlView as? KeyViewProxy.Button)
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(button.keyEquivalent, "\r")
            XCTAssertGreaterThanOrEqual(button.frame.width, AuvGitDialogButtonStyle.minimumWidth)
            let content = try XCTUnwrap(visible.contentView)
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: content.superview)
            XCTAssertTrue(content.hitTest(point) === button, "The visible Continue button must receive mouse hits")
            let operationCount = store.operationLog.filter { $0.userInitiated }.count
            button.performClick(nil)
            for _ in 0..<300 where store.operationLog.filter({ $0.userInitiated }).count == operationCount || store.isBusy {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(store.operationLog.filter { $0.userInitiated }.count, operationCount)
            XCTAssertFalse(store.isBusy)
            XCTAssertNil(store.error)
            let created = try await repo.workflowRevision("refs/heads/website/app-store")
            let current = try await repo.currentBranch()
            XCTAssertEqual(created, oid); XCTAssertEqual(current, "website/app-store")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("draft.txt"), encoding: .utf8), "Unsaved workspace draft")
        }
    }
    private final class PullSheetModel: ObservableObject {
        @Published var presented = false
        var operations: [NetworkOperation] = []
        var cancellations = 0
    }
    private struct PullSheetFixture: View {
        @ObservedObject var model: PullSheetModel
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .auvGitSheet(isPresented: $model.presented) {
                    PullOperationConfirmation(hint: nil, cancel: {
                        model.cancellations += 1; model.presented = false
                    }, execute: {
                        model.operations.append($0); model.presented = false
                    })
                }
        }
    }
    func testDefaultActionCueSupportsSpaceWithoutTakingFirstResponder() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            let model = PullSheetModel()
            let host = NSHostingView(rootView: PullSheetFixture(model: model))
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; parent.contentView = host
            defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) }; parent.close() }
            try await self.activateFixture(parent)
            model.presented = true
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
            try await self.ensureApplicationActive()
            let visible = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
            let primary = try XCTUnwrap(visible.defaultButtonCell?.controlView as? KeyViewProxy.Button)
            XCTAssertTrue(primary.showsDefaultActionFocus)
            XCTAssertTrue(visible.firstResponder === visible)
            var activations = 0
            primary.activate = { activations += 1 }
            @MainActor func space(flags: NSEvent.ModifierFlags = [], repeating: Bool = false) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: 49)!
            }
            let appearance = NativeFocusAppearance.forWindow(visible)
            app.sendEvent(space())
            XCTAssertEqual(activations, 1)
            XCTAssertTrue(visible.firstResponder === visible)
            let content = try XCTUnwrap(visible.contentView)
            XCTAssertTrue(visible.makeFirstResponder(content))
            XCTAssertTrue(visible.firstResponder === content)
            app.sendEvent(space())
            XCTAssertEqual(activations, 2, "SwiftUI's hosting view may own input instead of the panel on older macOS")
            XCTAssertTrue(visible.firstResponder === content, "Activating the default must not force control focus")
            XCTAssertTrue(appearance.handle(space(repeating: true)))
            XCTAssertEqual(activations, 2, "Holding Space must not repeat an operation")
            for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
                XCTAssertFalse(appearance.handle(space(flags: flags)))
            }
            primary.isEnabled = false
            XCTAssertFalse(appearance.handle(space()))
            primary.isEnabled = true
            let inputHost = NSHostingView(rootView: TextField("Input", text: .constant("")))
            inputHost.frame = NSRect(x: 0, y: 0, width: 250, height: 80)
            content.addSubview(inputHost)
            defer { inputHost.removeFromSuperview() }
            @MainActor func input(in view: NSView) -> NSTextField? {
                (view as? NSTextField) ?? view.subviews.lazy.compactMap { input(in: $0) }.first
            }
            inputHost.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(input(in: inputHost))
            XCTAssertTrue(visible.makeFirstResponder(field))
            XCTAssertFalse(appearance.handle(space()), "Space in a field editor must remain text input even with a default action")
            let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 250, height: 80))
            content.addSubview(editor)
            defer { editor.removeFromSuperview() }
            XCTAssertTrue(visible.makeFirstResponder(editor))
            app.sendEvent(space())
            XCTAssertEqual(editor.string, " ", "A default action must not consume Space typed into a text view")
            XCTAssertEqual(activations, 2)
        }
    }

    func testRealPullSheetWaitsForTabAndCyclesButtonsOnEveryPresentation() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            let model = PullSheetModel()
            let host = NSHostingView(rootView: PullSheetFixture(model: model))
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; parent.contentView = host
            defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) }; parent.close() }
            @MainActor func key(_ window: NSWindow, code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
                NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            }
            for presentation in 0..<3 {
                try await self.activateFixture(parent)
                model.presented = true
                for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
                try await self.ensureApplicationActive()
                let visible = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
                let primary = try XCTUnwrap(visible.defaultButtonCell?.controlView as? KeyViewProxy.Button)
                XCTAssertEqual(primary.title, networkText("pull"))
                XCTAssertTrue(visible.isKeyWindow)
                XCTAssertFalse(visible.firstResponder is NSControl, "Opening a sheet must not focus a control")
                XCTAssertFalse(NativeFocusAppearance.isVisible(in: visible))
                XCTAssertEqual(primary.focusRingType, .none)
                XCTAssertEqual(primary.layer?.borderWidth ?? 0, 0, "A full-frame border changes the apparent button height instead of drawing the native focus shape")
                XCTAssertTrue(primary.showsDefaultActionFocus, "Every default action must display the native focus style before Tab")
                if presentation == 0, let path = ProcessInfo.processInfo.environment["AUVGIT_DEFAULT_ACTION_PREVIEW"],
                   let content = visible.contentView,
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                var reached = Set<String>()
                if presentation == 1 {
                    XCTAssertTrue(visible.makeFirstResponder(visible.contentView))
                }
                for step in 0..<3 {
                    app.sendEvent(key(visible, code: 48, characters: "\t"))
                    if step == 0 { XCTAssertEqual((visible.firstResponder as? NSButton)?.title, networkText("fetch")) }
                    reached.insert(try XCTUnwrap(visible.firstResponder as? NSButton).title)
                    XCTAssertNotEqual((visible.firstResponder as? NSButton)?.focusRingType, NSFocusRingType.none)
                    NativeFocusAppearance.forWindow(visible).apply()
                    XCTAssertEqual(primary.layer?.borderWidth ?? 0, 0, "Tab must leave only the actual keyboard focus ring")
                    XCTAssertFalse(primary.showsDefaultActionFocus)
                }
                XCTAssertEqual(reached, Set([networkText("fetch"), networkText("cancel"), networkText("pull")]))
                if presentation == 0 {
                    for _ in 0..<3 where (visible.firstResponder as? NSButton)?.title != networkText("cancel") {
                        app.sendEvent(key(visible, code: 48, characters: "\u{19}", flags: .shift))
                    }
                    XCTAssertEqual((visible.firstResponder as? NSButton)?.title, networkText("cancel"))
                    app.sendEvent(key(visible, code: 49, characters: " "))
                } else if presentation == 1 {
                    app.sendEvent(key(visible, code: 36, characters: "\r"))
                } else {
                    app.sendEvent(key(visible, code: 53, characters: "\u{1b}"))
                }
                for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertFalse(model.presented)
                XCTAssertNil(parent.attachedSheet)
            }
            XCTAssertEqual(model.operations, [.pull])
            XCTAssertEqual(model.cancellations, 2)
        }
    }
    func testDimmingSurvivesSheetAnimationAndParentRedraw() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            for borderless in [false, true] {
                let model = SheetModel()
                let host = NSHostingView(rootView: RealSheetFixture(model: model).background(Color.white))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 434),
                    styleMask: borderless ? [.borderless] : [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = borderless ? EightPointFrameView(content: host) : host
                window.center()
                defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
                try await self.activateFixture(window)
                @MainActor func luminance() throws -> CGFloat {
                    let output = URL(fileURLWithPath: "/tmp/auvgit-sheet-dimming-\(borderless ? "shell" : "native").png")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    let top = try XCTUnwrap(NSScreen.screens.first).frame.maxY
                    process.arguments = ["-x", "-R", "\(Int(window.frame.minX + 20)),\(Int(top - window.frame.maxY + 60)),8,8", output.path]
                    process.standardOutput = Pipe(); process.standardError = Pipe()
                    try process.run(); process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0)
                    let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: output)))
                    let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                    return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                }
                let captures = ProcessInfo.processInfo.environment["AUVGIT_DIALOG_CAPTURE"] == "1"
                let baseline = captures ? try luminance() : 0
                model.presented = true
                for delay in [100, 300, 700] {
                    try await Task.sleep(for: .milliseconds(delay))
                    window.contentView?.needsDisplay = true
                    window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    if captures {
                        let value = try luminance()
                        print("SHEET_DIMMING shell=\(borderless) elapsedStepMs=\(delay) baseline=\(baseline) value=\(value)")
                        XCTAssertLessThan(value, baseline - (delay == 100 ? 0.02 : 0.12), "The native mask must remain visible after sheet animation and redraw")
                    }
                }
                model.presented = false
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertNil(window.attachedSheet)
                if captures { XCTAssertEqual(try luminance(), baseline, accuracy: 0.03) }
                model.presented = true
                try await Task.sleep(for: .milliseconds(75))
                model.presented = false
                try await Task.sleep(for: .milliseconds(75))
                model.presented = true
                try await Task.sleep(for: .milliseconds(500))
                let reopened = try XCTUnwrap(window.attachedSheet)
                XCTAssertTrue(DialogAppearance.visibleWindow(for: reopened).isVisible)
                if captures { XCTAssertLessThan(try luminance(), baseline - 0.12) }
                model.presented = false
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertNil(window.attachedSheet)
                if captures { XCTAssertEqual(try luminance(), baseline, accuracy: 0.03) }
            }
        }
    }
    func testPresentationFocusSelectsInitialInputOnce() throws {
        try runApplicationFixture { try await self.verifyInitialInputFocus() }
    }

    private func verifyInitialInputFocus() async throws {
        let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(policy) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let first = NSTextField(frame: NSRect(x: 20, y: 100, width: 300, height: 24))
        let next = NSTextField(frame: NSRect(x: 20, y: 60, width: 300, height: 24))
        first.stringValue = "Prefilled branch"
        window.contentView?.addSubview(first); window.contentView?.addSubview(next)
        let scope = NativeFocusCoordinator(); scope.focusesOnPresentation = true
        defer { scope.cancel(); window.close() }
        scope.register(first, initial: true); scope.register(next); scope.attach(to: window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(first.currentEditor(), "An unshown dialog must wait until presentation")
        try await activateFixture(window)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(first.currentEditor() === window.firstResponder)
        XCTAssertEqual((first.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 0, length: first.stringValue.utf16.count))
        XCTAssertTrue(NativeFocusAppearance.isVisible(in: window))
        next.selectText(nil)
        scope.schedule()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(next.currentEditor() === window.firstResponder, "Updating a dialog must retain the user's focus")
    }

    func testPresentationFocusUsesEnabledDefaultWhenThereIsNoInput() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let disabled = KeyViewProxy.Button(title: "Save", target: nil, action: nil)
        disabled.keyEquivalent = "\r"; disabled.isEnabled = false
        let cancel = KeyViewProxy.Button(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        window.contentView?.addSubview(disabled); window.contentView?.addSubview(cancel)
        DialogAppearance.configureDefaultButton(in: window)
        let scope = NativeFocusCoordinator(); scope.focusesOnPresentation = true
        defer { scope.cancel(); window.close() }
        scope.register(disabled); scope.register(cancel); scope.attach(to: window)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(window.defaultButtonCell === cancel.cell)
        XCTAssertTrue(window.firstResponder === cancel)
        XCTAssertTrue(NativeFocusAppearance.isVisible(in: window))
    }

    func testSheetUsesSharedRadiusWithoutSystemModalFrame() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled, .docModalWindow, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        DialogAppearance.style(window)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.docModalWindow))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.canBecomeKey)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertNotEqual(window.standardWindowButton(button)?.isHidden, false)
        }
        XCTAssertEqual(window.contentView?.superview?.layer?.cornerRadius, 12)
        XCTAssertEqual(window.contentView?.superview?.layer?.masksToBounds, true)
        XCTAssertFalse(window.isOpaque)
    }

    func testMainWindowClipsTheFrameContainingTheSheetDimmer() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = EightPointFrameView(content: NSView())
        XCTAssertEqual(window.contentView?.superview?.layer?.cornerRadius, 12)
        XCTAssertEqual(window.contentView?.superview?.layer?.masksToBounds, true)
    }
    func testAlertDefaultSkipsDisabledActionsAndPrefersCancelToDestructive() {
        let disabledSave = AuvGitAlertButton("Save").disabled(true)
        let discard = AuvGitAlertButton("Discard", role: .destructive)
        let cancel = AuvGitAlertButton("Cancel", role: .cancel)
        XCTAssertEqual(DialogAppearance.defaultButtonIndex([disabledSave, discard, cancel]), 2)
        XCTAssertEqual(DialogAppearance.defaultButtonIndex([discard, AuvGitAlertButton("Save"), cancel]), 1)
        XCTAssertNil(DialogAppearance.defaultButtonIndex([disabledSave, cancel.disabled(true)]))
    }

    func testDefaultButtonHighlightDoesNotReplaceDraftEditorFocus() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        let editor = NSTextView(frame: NSRect(x: 10, y: 60, width: 300, height: 100))
        editor.string = "Unfinished draft"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: nil, action: nil)
        save.keyEquivalent = "\r"
        content.addSubview(editor); content.addSubview(cancel); content.addSubview(save)
        window.contentView = content
        window.makeFirstResponder(editor)
        DialogAppearance.style(window)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(window.defaultButtonCell === save.cell)
        XCTAssertEqual(editor.string, "Unfinished draft")
        save.isEnabled = false
        DialogAppearance.configureDefaultButton(in: window)
        XCTAssertTrue(window.defaultButtonCell === cancel.cell)
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testSheetClipsContentAndOuterFrameAtMainWindowRadius() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        DialogAppearance.style(window)
        for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
            XCTAssertEqual(view.layer?.cornerRadius, AuvGitStyle.windowCornerRadius)
            XCTAssertEqual(view.layer?.masksToBounds, true)
        }
    }

    private final class SheetModel: ObservableObject {
        @Published var presented = false
        @Published var draft = "Unfinished draft"
        @Published var showError = false
        var confirmations = 0
        var dismissals = 0
    }
    private struct RealSheetFixture: View {
        @ObservedObject var model: SheetModel
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .auvGitSheet(isPresented: $model.presented, onDismiss: { model.dismissals += 1 }) {
                    RealSheetContent(model: model)
                }
        }
    }

    private struct RealSheetContent: View {
        @ObservedObject var model: SheetModel
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            VStack {
                StableTextField("Draft", text: $model.draft, initialFocus: true)
                KeyViewProxy(label: "Cancel", keyEquivalent: "\u{1b}") { dismiss() }
                if model.showError { Text("Authentication requires another credential.").frame(height: 70) }
                KeyViewProxy(label: "Continue", prominent: true) { model.confirmations += 1 }
            }.padding(24).frame(width: 360, height: model.showError ? 250 : 180).background(Color.white)
        }
    }

    func testRealSwiftUISheetUsesSharedOuterSilhouetteAndNativeDismissal() throws {
        try runApplicationFixture { try await self.verifyRealSheet() }
    }

    private func runApplicationFixture(_ body: @escaping @MainActor () async throws -> Void) throws {
        let app = NSApplication.shared
        var failure: Error?
        Task { @MainActor in
            do { try await body() } catch { failure = error }
            app.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(wake, atStart: false)
            }
        }
        // Key-window activation and Return dispatch require AppKit's real event
        // loop; XCTest's async scheduler alone leaves NSApp inactive/non-running.
        app.run()
        if let failure { throw failure }
    }

    private struct ClonePromptFixture: View {
        let store: RepositoryStore
        @ObservedObject var creation: RepositoryCreationOperation
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .auvGitSheet(isPresented: $creation.isPresented) { CreateRepositorySheet(store: store) }
                .background(RepositoryCreationAlerts(creation: creation))
                .disabled(!creation.isPresented) // Background project views cannot receive workspace actions.
        }
    }

    func testCloneReplacementAndRetryPresentRealAlertsAndAllowEscape() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            let defaults = UserDefaults.standard
            let keys = [CloneDestination.parentPreference, RepositoryCreationDraft.preference]
            let saved = keys.map { defaults.object(forKey: $0) }
            defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let target = root.appendingPathComponent("target"), trash = root.appendingPathComponent("trash")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try "keep".write(to: target.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = RepositoryStore(persistsSession: false)
            defer { store.closeTransientSession() }
            var attempts = 0
            let creation = RepositoryCreationOperation(store: store, trashItem: {
                try FileManager.default.moveItem(at: $0, to: trash)
            }) { _, _, url, _, _ in
                attempts += 1
                if attempts == 1 { throw GitError("fatal: remote repository unavailable") }
                return try await GitRepository.initialize(at: url)
            }
            store.creationOperation = creation
            creation.prepare(initialClone: true)
            creation.source = "https://example.invalid/team/repo.git"
            creation.destination = target.path
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.contentView = NSHostingView(rootView: ClonePromptFixture(store: store, creation: creation))
            defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) }; parent.close() }
            @MainActor func settle() async throws { try await Task.sleep(for: .milliseconds(500)) }
            @MainActor func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
            }
            @MainActor func action(_ title: String, in window: NSWindow) throws -> NSButton {
                try XCTUnwrap(buttons(try XCTUnwrap(window.contentView)).first { $0.title == workflowText(title) })
            }
            @MainActor func escape(_ window: NSWindow) throws {
                try app.sendEvent(XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
            }
            try await self.activateFixture(parent)
            creation.isPresented = true
            try await settle()
            let form = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
            creation.create()
            try await settle()
            let replacement = DialogAppearance.visibleWindow(for: try XCTUnwrap(form.attachedSheet))
            XCTAssertFalse(NativeFocusAppearance.isVisible(in: replacement))
            _ = try action("Move to Trash and Clone Again", in: replacement)
            try escape(replacement)
            try await settle()
            XCTAssertNil(creation.prompt)
            XCTAssertTrue(creation.isPresented)
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
            creation.create()
            try await settle()
            let confirmed = DialogAppearance.visibleWindow(for: try XCTUnwrap(form.attachedSheet))
            try action("Move to Trash and Clone Again", in: confirmed).performClick(nil)
            try await settle()
            XCTAssertFalse(creation.isPresented)
            XCTAssertEqual(attempts, 1)
            let retry = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
            XCTAssertFalse(NativeFocusAppearance.isVisible(in: retry))
            let retryButton = try action("Retry Clone", in: retry)
            XCTAssertTrue(retryButton.isEnabled, "A background project's failure alert must remain interactive")
            retryButton.performClick(nil)
            try await settle()
            XCTAssertEqual(attempts, 2)
            XCTAssertFalse(creation.busy)
            XCTAssertNil(creation.prompt)
            XCTAssertNil(parent.attachedSheet)
            XCTAssertNotNil(store.repository)
            XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("keep.txt")), "keep")
        }
    }

    private func activateFixture(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        try await ensureApplicationActive()
    }

    private func ensureApplicationActive() async throws {
        let app = NSApplication.shared
        let deadline = ContinuousClock.now + .seconds(2)
        repeat {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            app.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(50))
        } while !app.isActive && ContinuousClock.now < deadline
        XCTAssertTrue(app.isActive, "Real-window keyboard/pixel gates require an active fixture host")
        _ = try XCTUnwrap(app.isActive ? app : nil)
    }

    private func verifyRealSheet() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let model = SheetModel()
        let host = NSHostingView(rootView: RealSheetFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        try await activateFixture(window)
        model.presented = true
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await ensureApplicationActive()
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.sheetParent === window)
        XCTAssertTrue(sheet.canBecomeKey)
        let visible = DialogAppearance.visibleWindow(for: sheet)
        XCTAssertFalse(visible === sheet)
        XCTAssertTrue(visible.canBecomeKey)
        print("REAL_SHEET_KEY active=\(app.isActive) policy=\(app.activationPolicy().rawValue) running=\(app.isRunning) visibleKey=\(visible.isKeyWindow) anchorKey=\(sheet.isKeyWindow) parentKey=\(window.isKeyWindow) appKey=\(String(describing: app.keyWindow)) panel=\(visible)")
        XCTAssertTrue(visible.isKeyWindow)
        XCTAssertFalse(visible.styleMask.contains(.titled))
        XCTAssertEqual(visible.animationBehavior, .none)
        XCTAssertEqual(sheet.animationBehavior, .none)
        XCTAssertEqual(sheet.alphaValue, 0)
        XCTAssertNotNil(visible.defaultButtonCell)
        XCTAssertEqual(model.draft, "Unfinished draft")

        // Capture the real WindowServer silhouette; layer.cornerRadius alone did
        // not catch the system sheet mask that rounded 28 pt off our corners.
        if ProcessInfo.processInfo.environment["AUVGIT_DIALOG_CAPTURE"] == "1" {
            let output = URL(fileURLWithPath: "/tmp/auvgit-real-sheet-corner-test.png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let screenTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let frame = visible.frame
            let region = "\(Int(frame.minX)),\(Int(screenTop - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
            capture.arguments = ["-x", "-o", "-R", region, output.path]
            capture.standardOutput = Pipe(); capture.standardError = Pipe()
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0, "Real-sheet capture requires the current test host's Screen Recording permission")
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: output)))
            let scale = visible.backingScaleFactor
            XCTAssertEqual(CGFloat(image.pixelsWide), visible.frame.width * scale, accuracy: 1)
            XCTAssertEqual(CGFloat(image.pixelsHigh), visible.frame.height * scale, accuracy: 1)
            print("REAL_SHEET_CAPTURE frame=\(visible.frame) scale=\(scale) pixels=\(image.pixelsWide)x\(image.pixelsHigh)")
            let x = Int((AuvGitStyle.windowCornerRadius + 2) * scale)
            let y = max(1, Int(scale))
            let topEdge = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(topEdge.redComponent, 0.95)
            XCTAssertGreaterThan(topEdge.greenComponent, 0.95)
            XCTAssertGreaterThan(topEdge.blueComponent, 0.95,
                                 "At 10 pt from the side the white 8 pt sheet must reach the top edge")
            let outside = try XCTUnwrap(image.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
            XCTAssertLessThan(outside.redComponent, 0.95, "The screenshot must include the sheet's transparent corner over its dimmed parent")
        }
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        NSApplication.shared.sendEvent(tab)
        XCTAssertTrue(visible.firstResponder is NSView)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        // Return inside a text editor belongs to that editor. Verify the dialog
        // default from the window responder after ending the active edit.
        XCTAssertTrue(visible.makeFirstResponder(visible))
        NSApplication.shared.sendEvent(enter)
        XCTAssertEqual(model.confirmations, 1)
        let originalHeight = visible.frame.height
        model.showError = true
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(visible.frame.height, originalHeight + 50)
        XCTAssertEqual(visible.frame, sheet.frame)

        // Escape travels through the moved content and its original SwiftUI
        // Environment dismiss action, rather than mutating the binding directly.
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApplication.shared.sendEvent(escape)
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(visible.isVisible)
        XCTAssertFalse(model.presented)
        XCTAssertEqual(model.dismissals, 1)
        XCTAssertEqual(model.draft, "Unfinished draft")
        try await activateFixture(window)
        model.presented = true
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
        try await ensureApplicationActive()
        let reopenedAnchor = try XCTUnwrap(window.attachedSheet)
        let reopened = DialogAppearance.visibleWindow(for: reopenedAnchor)
        XCTAssertFalse(reopened === visible)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertTrue(reopened.isKeyWindow)
        model.presented = false
        for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(reopened.isVisible)
        XCTAssertEqual(model.dismissals, 2)
    }

    func testOversizedSheetFrameIsBoundedOnOffsetDisplay() {
        let visible = NSRect(x: -1440, y: 40, width: 1440, height: 860)
        let frame = DialogAppearance.boundedFrame(NSRect(x: -1500, y: -2000, width: 3000, height: 12000), visibleFrame: visible)
        XCTAssertTrue(visible.insetBy(dx: 16, dy: 16).contains(frame))
        XCTAssertEqual(frame.width, 1408)
        XCTAssertEqual(frame.height, 828)
    }

    private final class LongAlertModel: ObservableObject {
        @Published var presented = false
        @Published var lineCount = 1
        var confirmations = 0
    }
    private struct LongAlertFixture: View {
        @ObservedObject var model: LongAlertModel
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .auvGitAlert("Discard workspace changes", isPresented: $model.presented) {
                    AuvGitAlertButton("Cancel", role: .cancel)
                    AuvGitAlertButton("Continue") { model.confirmations += 1 }
                } message: {
                    Text((0..<model.lineCount).map { "file-\($0).txt" }.joined(separator: "\n"))
                }
        }
    }

    func testLongAlertMessagesScrollWhileActionsStayVisibleAndKeyboardReachable() throws {
        try runApplicationFixture { try await self.verifyLongAlerts() }
    }

    private final class PullNoticeModel: ObservableObject {
        @Published var notice: PullResultNotice?
    }
    private struct PullNoticeFixture: View {
        @ObservedObject var model: PullNoticeModel
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .auvGitAlert(item: $model.notice, focusesOnPresentation: false) { notice in
                    AuvGitAlert(title: networkText("pullRecoveryTitle"), message: notice.message,
                        buttons: [AuvGitAlertButton(networkText("close"), role: .cancel) { model.notice = nil }])
                }
        }
    }
    func testPullResultNoticeDoesNotFocusControlsAndEscapeDismissesIt() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            app.setActivationPolicy(.regular)
            defer { app.setActivationPolicy(policy) }
            let model = PullNoticeModel()
            let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            parent.contentView = NSHostingView(rootView: PullNoticeFixture(model: model))
            defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) }; parent.close() }
            try await self.activateFixture(parent)
            model.notice = PullResultNotice(error: GitError("Local conflicts: shared.txt. Changes retained in stash."))
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
            try await self.ensureApplicationActive()
            let panel = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
            XCTAssertFalse(panel.firstResponder is NSControl)
            XCTAssertFalse(NativeFocusAppearance.isVisible(in: panel))
            let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            app.sendEvent(escape)
            for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(model.notice); XCTAssertNil(parent.attachedSheet)
        }
    }

    private func verifyLongAlerts() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let model = LongAlertModel()
        let host = NSHostingView(rootView: LongAlertFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        for lines in [1, 81, 1000] {
            try await activateFixture(window)
            model.lineCount = lines
            model.presented = true
            for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
            try await ensureApplicationActive()
            let anchor = try XCTUnwrap(window.attachedSheet)
            let visible = DialogAppearance.visibleWindow(for: anchor)
            let content = try XCTUnwrap(visible.contentView)
            XCTAssertLessThan(visible.frame.height, lines == 1 ? 200 : 520)
            let screen = try XCTUnwrap(window.screen).visibleFrame
            XCTAssertTrue(screen.insetBy(dx: 16, dy: 16).contains(visible.frame))
            XCTAssertTrue(visible.isKeyWindow)
            func keyViews(_ view: NSView) -> [NSView] {
                (view.canBecomeKeyView ? [view] : []) + view.subviews.flatMap(keyViews)
            }
            // Selectable text participates in the key loop, but its scroll
            // document can exceed the panel. Only action buttons must fit.
            let actions = keyViews(content).compactMap { $0 as? NSButton }
            XCTAssertEqual(actions.count, 2)
            for action in actions {
                XCTAssertTrue(content.bounds.contains(action.convert(action.bounds, to: content)),
                              "Keyboard actions must remain inside the visible panel for \(lines) lines")
            }
            XCTAssertTrue(visible.makeFirstResponder(visible))
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: visible.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            app.sendEvent(enter)
            for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(visible.isVisible)
        }
        XCTAssertEqual(model.confirmations, 3)
    }

    func testFileListSummaryListsAtMostTwentyFiles() {
        let twenty = (0..<20).map { "file-\($0).txt" }
        XCTAssertEqual(DialogAppearance.fileListSummary(twenty), twenty.joined(separator: "\n"))
        XCTAssertEqual(DialogAppearance.fileListSummary([]), "")
        let large = twenty + ["file-20.txt"]
        XCTAssertEqual(DialogAppearance.fileListSummary(large), interactionText("File Count Summary", 21))
        XCTAssertFalse(DialogAppearance.fileListSummary(large).contains("file-0.txt"))
        XCTAssertFalse(DialogAppearance.fileListSummary(large).contains("\n"))
    }

    private struct ForcePushSheetFixture: View {
        @ObservedObject var model: SheetModel
        let preview: ForcePushPreview
        var body: some View {
            Text("Parent").frame(width: 500, height: 400)
                .auvGitSheet(isPresented: $model.presented) {
                    ForcePushConfirmation(preview: preview, cancel: { model.presented = false },
                        execute: { model.confirmations += 1; model.presented = false })
                }
        }
    }

    func testForcePushDefaultCancelUsesNativeFocusAndEqualButtonHeights() throws {
        try runApplicationFixture {
            let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
            let originalAppearance = app.appearance
            app.setActivationPolicy(.regular)
            defer { app.appearance = originalAppearance; app.setActivationPolicy(policy) }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            for arguments in [["init", "-b", "main"], ["config", "user.name", "Fixture"],
                ["config", "user.email", "fixture@example.invalid"],
                ["commit", "--allow-empty", "-m", "local"],
                ["commit", "--allow-empty", "-m", "remote"],
                ["update-ref", "refs/remotes/origin/main", "HEAD"],
                ["update-ref", "refs/heads/main", "HEAD~1"],
                ["remote", "add", "origin", "https://example.invalid/fixture.git"],
                ["config", "branch.main.remote", "origin"],
                ["config", "branch.main.merge", "refs/heads/main"]] {
                _ = try await GitProcess.run(at: root, arguments: arguments)
            }
            let preview = try await GitRepository(url: root).cachedForcePushPreview()
            let value = try XCTUnwrap(preview)
            for dark in [false, true] {
                app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let model = SheetModel()
                let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                    styleMask: [.titled], backing: .buffered, defer: false)
                parent.isReleasedWhenClosed = false
                parent.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                parent.contentView = NSHostingView(rootView: ForcePushSheetFixture(model: model, preview: value)
                    .environment(\.colorScheme, dark ? .dark : .light))
                defer { if let sheet = parent.attachedSheet { parent.endSheet(sheet) }; parent.close() }
                try await self.activateFixture(parent)
                model.presented = true
                for _ in 0..<40 { try await Task.sleep(for: .milliseconds(10)) }
                try await self.ensureApplicationActive()
                let panel = DialogAppearance.visibleWindow(for: try XCTUnwrap(parent.attachedSheet))
                let content = try XCTUnwrap(panel.contentView)
                func buttons(_ view: NSView) -> [KeyViewProxy.Button] {
                    (view as? KeyViewProxy.Button).map { [$0] } ?? view.subviews.flatMap(buttons)
                }
                let actions = buttons(content)
                XCTAssertEqual(actions.count, 2)
                let cancel = try XCTUnwrap(actions.first { $0.title == forcePushText("cancel") })
                let force = try XCTUnwrap(actions.first { $0.title == forcePushText("action") })
                XCTAssertTrue(panel.defaultButtonCell === cancel.cell)
                XCTAssertTrue(cancel.showsDefaultActionFocus)
                XCTAssertFalse(force.showsDefaultActionFocus)
                func ringPixels() throws -> Int {
                    let rect = cancel.convert(cancel.bounds.insetBy(dx: -4, dy: -4), to: content)
                    let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: rect))
                    content.cacheDisplay(in: rect, to: bitmap)
                    return (0..<bitmap.pixelsHigh).reduce(0) { count, y in
                        count + (0..<bitmap.pixelsWide).filter { x in
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                            return color.blueComponent > color.redComponent + 0.15 && color.blueComponent > color.greenComponent + 0.05
                        }.count
                    }
                }
                let initialRingPixels = try ringPixels()
                XCTAssertGreaterThan(initialRingPixels, 20)
                XCTAssertEqual(cancel.layer?.borderWidth ?? 0, 0)
                XCTAssertFalse(panel.firstResponder is NSControl)
                func tab(_ backwards: Bool = false) throws {
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                        modifierFlags: backwards ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: panel.windowNumber, context: nil, characters: "\t",
                        charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
                    app.sendEvent(event)
                }
                XCTAssertEqual(cancel.frame.height, AuvGitDialogButtonStyle.height, accuracy: 0.5)
                XCTAssertEqual(cancel.frame.height, force.frame.height, accuracy: 0.5)
                let cancelRect = cancel.convert(cancel.bounds, to: content)
                let forceRect = force.convert(force.bounds, to: content)
                XCTAssertEqual(cancelRect.minY, forceRect.minY, accuracy: 0.5)
                XCTAssertEqual(cancel.focusRingMaskBounds.height, force.focusRingMaskBounds.height, accuracy: 0.5)
                try tab()
                XCTAssertTrue(panel.firstResponder === force, "Tab must advance from the indicated default Cancel to the confirmation action")
                try tab(true)
                XCTAssertTrue(panel.firstResponder === cancel)
                try tab(true)
                XCTAssertTrue(panel.firstResponder === force, "Shift-Tab must wrap through both actions")
                try tab()
                XCTAssertTrue(panel.firstResponder === cancel)
                XCTAssertGreaterThanOrEqual(try ringPixels(), initialRingPixels * 3 / 4,
                    "Wrapping back to the default action must retain its visible focus outline in both appearances")
                if let path = ProcessInfo.processInfo.environment["AUVGIT_FORCE_PUSH_PREVIEW"],
                   let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: path + (dark ? "-dark.png" : "-light.png")))
                }
                let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                app.sendEvent(escape)
                for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertFalse(model.presented)
                XCTAssertEqual(model.confirmations, 0, "Checking default focus must never force-push")
            }
        }
    }

    func testNativeFrameIsHiddenBeforeShellInstallation() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                             styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = DialogFrameStyle.FrameView()
        XCTAssertEqual(window.alphaValue, 0)
        XCTAssertEqual(window.animationBehavior, .none)
    }

}
