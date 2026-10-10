import AppKit
import SwiftUI
import XCTest
@testable import RayGit

@MainActor
final class NativeFocusBridgeTests: XCTestCase {
    private final class ScopeRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Bool] = []
        func append(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
        var last: Bool? { lock.lock(); defer { lock.unlock() }; return values.last }
    }
    private final class Model: ObservableObject {
        @Published var usernameVisible = false
        @Published var request: UUID?
        @Published var text = ""
        @Published var disabled = false
    }
    private struct Fixture: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack {
                StableTextField("Source", text: $model.text, initialFocus: true)
                if model.usernameVisible { StableTextField("Username", text: $model.text, focusRequest: model.request) }
                StableTextField("Disabled", text: .constant("")).disabled(model.disabled)
                KeyViewProxy(label: "Choose") {}
                KeyViewProxy(label: "Save", checked: false) {}
                StableTextField("Destination", text: .constant(""))
            }.padding().nativeFocusRoot()
        }
    }
    private struct ScopeProbe: NSViewRepresentable {
        @Environment(\.nativeFocusScope) private var scope
        let recorder: ScopeRecorder
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) { recorder.append(scope != nil) }
    }
    private final class SplitModel: ObservableObject { @Published var revision = 0 }
    private final class PresentationModel: ObservableObject { @Published var presented = false }
    private struct CloneSheetFixture: View {
        @ObservedObject var presentation: PresentationModel
        let store: RepositoryStore
        var body: some View {
            StableTextField("Parent", text: .constant(""))
                .frame(width: 400, height: 250).nativeFocusRoot()
                .rayGitSheet(isPresented: $presentation.presented) {
                    CreateRepositorySheet(store: store, initialClone: true)
                }
        }
    }
    private struct AlertSheetFixture: View {
        @ObservedObject var presentation: PresentationModel
        var body: some View {
            Text("Parent").frame(width: 400, height: 250).nativeFocusRoot()
                .rayGitAlert("Confirm", isPresented: $presentation.presented) {
                    RayGitAlertButton("Cancel", role: .cancel)
                    RayGitAlertButton("Disabled").disabled(true)
                    RayGitAlertButton("Continue")
                }
        }
    }
    func testRealAlertButtonsAreKeyboardReachableAndSkipDisabled() throws {
        _ = NSApplication.shared
        let model = PresentationModel()
        let host = NSHostingView(rootView: AlertSheetFixture(presentation: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet) }; window.close() }
        drain(host); model.presented = true; drain(host)
        let sheet = try XCTUnwrap(window.attachedSheet), content = try XCTUnwrap(sheet.contentView)
        drain(content)
        func candidates(_ view: NSView) -> [NSView] {
            (view.canBecomeKeyView ? [view] : []) + view.subviews.flatMap(candidates)
        }
        let reachable = candidates(content)
        XCTAssertEqual(reachable.count, 2, "Only the two enabled actions should participate in the loop")
        XCTAssertTrue(sheet.firstResponder === sheet)
        NSApplication.shared.sendEvent(tabEvent(in: sheet))
        let first = try XCTUnwrap(sheet.firstResponder as? NSView)
        XCTAssertTrue(reachable.contains { $0 === first })
        sheet.selectNextKeyView(nil)
        let second = try XCTUnwrap(sheet.firstResponder as? NSView)
        XCTAssertFalse(second === first)
        XCTAssertTrue(reachable.contains { $0 === second })
        sheet.selectPreviousKeyView(nil)
        XCTAssertTrue(sheet.firstResponder === first)
    }
    private func tabEvent(in window: NSWindow, backwards: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: backwards ? .shift : [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: backwards ? "\u{19}" : "\t", charactersIgnoringModifiers: backwards ? "\u{19}" : "\t", isARepeat: false, keyCode: 48)!
    }
    func testRealCloneSheetFirstTabEntersLoopFromWindowResponder() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let draft = defaults.object(forKey: RepositoryCreationDraft.preference)
        defaults.removeObject(forKey: RepositoryCreationDraft.preference)
        defer {
            if let draft { defaults.set(draft, forKey: RepositoryCreationDraft.preference) }
            else { defaults.removeObject(forKey: RepositoryCreationDraft.preference) }
        }
        let model = PresentationModel(), store = RepositoryStore(persistsSession: false)
        let host = NSHostingView(rootView: CloneSheetFixture(presentation: model, store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer {
            model.presented = false; drain(host)
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close(); drain(host)
        }
        drain(host)
        model.presented = true; drain(host)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let content = try XCTUnwrap(sheet.contentView)
        drain(content)
        let source = try XCTUnwrap(fields(content).first { $0.accessibilityLabel() == workflowText("Clone URL or local path") })
        XCTAssertTrue(sheet.canBecomeKey, "Styling must preserve the sheet's keyboard eligibility")
        XCTAssertTrue(sheet.firstResponder === sheet, "Opening a sheet must leave controls unfocused")
        XCTAssertEqual(source.focusRingType, .none)
        sheet.sendEvent(tabEvent(in: sheet))
        XCTAssertTrue(ownsFocus(source, sheet), "First real Tab must enter the loop when the sheet owns first responder")
        sheet.sendEvent(tabEvent(in: sheet))
        let destination = try XCTUnwrap(fields(content).first { $0.accessibilityLabel() == workflowText("Destination folder") })
        XCTAssertTrue(ownsFocus(destination, sheet))
        sheet.sendEvent(tabEvent(in: sheet, backwards: true))
        XCTAssertTrue(ownsFocus(source, sheet))
    }
    private struct SplitFixture: View {
        @ObservedObject var model: SplitModel
        let recorder: ScopeRecorder
        var body: some View {
            WorkspaceFooterSplit(
                history: ScopeProbe(recorder: recorder).id(model.revision),
                commit: EmptyView()
            )
        }
    }
    func testComparisonSearchWaitsForTabAfterAttachingToWindow() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ComparisonSearchPopover(options: .constant(ComparisonSearchOptions()),
            replacement: .constant(""), matchCount: 0, onNavigate: { _ in }))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 260)
        drain(host)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drain(host)
        let query = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == comparisonSearchText("Find") })
        XCTAssertFalse(ownsFocus(query, window))
        window.sendEvent(tabEvent(in: window))
        XCTAssertTrue(ownsFocus(query, window), "First Tab enters search after its presentation attaches")
    }
    func testComparisonPopoverDoesNotRebindParentScope() throws {
        _ = NSApplication.shared
        let scope = NativeFocusCoordinator()
        let parentHost = NSHostingView(rootView: StableTextField("Parent", text: .constant(""), initialFocus: true)
            .environment(\.nativeFocusScope, scope).background(NativeFocusBridge(scope: scope)))
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.contentView = parentHost; parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }
        drain(parentHost)
        let controller = NSViewController()
        let host = NSHostingView(rootView: ComparisonSearchPopover(options: .constant(ComparisonSearchOptions()),
            replacement: .constant(""), matchCount: 0, onNavigate: { _ in }).environment(\.nativeFocusScope, scope))
        controller.view = host
        let popover = NSPopover(); popover.contentViewController = controller; popover.contentSize = NSSize(width: 400, height: 260)
        popover.show(relativeTo: NSRect(x: 5, y: 5, width: 30, height: 30), of: parentHost, preferredEdge: .maxY)
        defer { popover.close() }
        drain(host)
        let query = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == comparisonSearchText("Find") })
        let popupWindow = try XCTUnwrap(host.window)
        func roots(_ view: NSView) -> [NativeFocusBridge.RootView] {
            (view as? NativeFocusBridge.RootView).map { [$0] } ?? view.subviews.flatMap(roots)
        }
        XCTAssertTrue(roots(host).contains { $0.scope !== scope }, "Interactive popover must own a scope instead of inheriting the parent")
        XCTAssertFalse(ownsFocus(query, popupWindow))
        NSApplication.shared.sendEvent(tabEvent(in: popupWindow))
        XCTAssertTrue(ownsFocus(query, popupWindow))
        popover.close(); drain(parentHost)
        let parentField = try XCTUnwrap(fields(parentHost).first)
        parent.makeFirstResponder(parent)
        NSApplication.shared.sendEvent(tabEvent(in: parent))
        XCTAssertTrue(ownsFocus(parentField, parent), "Closing search must leave the parent's coordinator attached to its own window")
    }
    private struct SearchFixture: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack {
                ComparisonSearchField(text: $model.text, placeholder: "Query", initialFocus: true,
                    onNavigate: { _ in }, onEscape: {}).disabled(model.disabled)
                StableTextField("After", text: .constant(""))
            }.padding().nativeFocusRoot()
        }
    }
    func testFloatingNoticePopoverOwnsIndependentFocusScope() throws {
        _ = NSApplication.shared
        let parentScope = NativeFocusCoordinator()
        let existingWindows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let host = NSHostingView(rootView: FloatingNotice(message: "Test notice", guidance: "Guidance")
            .environment(\.nativeFocusScope, parentScope)
            .background(NativeFocusBridge(scope: parentScope)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }; drain(host)
        let popup = try XCTUnwrap(NSApplication.shared.windows.first { $0 !== window && !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible })
        defer { popup.close() }
        func roots(_ view: NSView) -> [NativeFocusBridge.RootView] {
            (view as? NativeFocusBridge.RootView).map { [$0] } ?? view.subviews.flatMap(roots)
        }
        XCTAssertTrue(roots(try XCTUnwrap(popup.contentView)).contains { $0.scope !== parentScope })
    }
    func testComparisonSearchEnabledTargetStillWaitsForTab() throws {
        _ = NSApplication.shared
        let model = Model(); model.disabled = true
        let host = NSHostingView(rootView: SearchFixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }; drain(host)
        let query = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Query" })
        XCTAssertFalse(query.isEnabled)
        XCTAssertFalse(ownsFocus(query, window))
        model.disabled = false; drain(host)
        XCTAssertFalse(ownsFocus(query, window), "Enabling a field must not focus it automatically")
        window.sendEvent(tabEvent(in: window))
        XCTAssertTrue(ownsFocus(query, window))
        let after = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "After" })
        window.makeFirstResponder(after); model.text = "update"; drain(host)
        XCTAssertTrue(ownsFocus(after, window), "An acknowledged initial request must not steal focus")
    }
    func testInheritedFieldsCannotRebindParentWindowScope() throws {
        _ = NSApplication.shared
        let scope = NativeFocusCoordinator()
        let parentHost = NSHostingView(rootView: StableTextField("Parent", text: .constant(""), initialFocus: true)
            .environment(\.nativeFocusScope, scope).background(NativeFocusBridge(scope: scope)))
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.contentView = parentHost; parent.makeKeyAndOrderFront(nil)
        defer { parent.close() }; drain(parentHost)
        let responder = parent.nextResponder
        let host = NSHostingView(rootView: VStack {
            StableTextField("Foreign", text: .constant(""))
            ComparisonSearchField(text: .constant(""), placeholder: "Foreign search", onNavigate: { _ in }, onEscape: {})
        }.environment(\.nativeFocusScope, scope))
        let child = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        child.isReleasedWhenClosed = false; child.contentView = host; child.makeKeyAndOrderFront(nil)
        defer { child.close() }; drain(host)
        XCTAssertTrue(parent.nextResponder === responder, "Only the owning root may bind a presentation; inherited fields must not migrate it")
        parent.makeFirstResponder(parent); parent.sendEvent(tabEvent(in: parent))
        XCTAssertTrue(ownsFocus(try XCTUnwrap(fields(parentHost).first), parent))
    }
    func testRemovingNestedScopesPreservesOriginalResponderChain() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = NSResponder(); window.nextResponder = original
        let first = NativeFocusCoordinator(), second = NativeFocusCoordinator()
        first.attach(to: window); second.attach(to: window)
        first.cancel(); second.cancel()
        XCTAssertTrue(window.nextResponder === original, "Removing an inner scope must not break the remaining responder chain")
    }
    func testReleasingScopeRestoresOriginalResponderChain() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = NSResponder(); window.nextResponder = original
        var scope: NativeFocusCoordinator? = NativeFocusCoordinator()
        scope?.attach(to: window); scope = nil
        drain(NSView())
        XCTAssertTrue(window.nextResponder === original, "A field's fallback scope must restore the window chain when released")
    }
    private func drain(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded() }
    }
    private func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    private func ownsFocus(_ field: NSTextField, _ window: NSWindow) -> Bool {
        window.firstResponder === field || (field.currentEditor() != nil && window.firstResponder === field.currentEditor())
    }
    func testRepositoryToolsCloseActionIsKeyboardReachable() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: RepositoryTools(store: RepositoryStore(persistsSession: false)).nativeFocusRoot())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }; drain(host)
        func candidates(_ view: NSView) -> [NSView] { (view.canBecomeKeyView ? [view] : []) + view.subviews.flatMap(candidates) }
        let reachable = candidates(host)
        XCTAssertEqual(reachable.filter { !($0 is NSTextField) && type(of: $0) != NSView.self && String(describing: type(of: $0)) == "KeyViewProxy" }.count, 2,
            "The operation picker and enabled Close action retain SwiftUI's native key-view proxies")
    }
    func testPreferencesFormRetainsNativeKeyboardStops() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: PreferencesWindow(store: RepositoryStore(persistsSession: false)).nativeFocusRoot())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }; drain(host)
        let search = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == prefsText("Search preferences") })
        func candidates(_ view: NSView) -> [NSView] { (view.canBecomeKeyView ? [view] : []) + view.subviews.flatMap(candidates) }
        XCTAssertGreaterThan(candidates(host).count, 4, "Category actions and form controls must contribute keyboard stops")
        try XCTSkipUnless(window.isKeyWindow, "SwiftUI focus proxies require an active GUI key window; verify Preferences traversal in the installed app.")
        window.makeFirstResponder(search)
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<40 {
            window.selectNextKeyView(nil)
            if ownsFocus(search, window) { break }
            if let view = window.firstResponder as? NSView { visited.insert(ObjectIdentifier(view)) }
        }
        XCTAssertTrue(ownsFocus(search, window), "Preferences should have a closed native key-view loop")
        XCTAssertGreaterThan(visited.count, 4, "Category actions and form controls must contribute keyboard stops")
    }
    private func hosted(_ model: Model) -> (NSWindow, NSHostingView<Fixture>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Fixture(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        drain(host)
        return (window, host)
    }

    func testDynamicInsertionAndNewTokenMoveFocusOnce() throws {
        let model = Model(), (window, host) = hosted(model)
        defer { window.close() }
        window.sendEvent(tabEvent(in: window))
        let destination = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Destination" })
        window.makeFirstResponder(destination)
        model.usernameVisible = true; model.request = UUID()
        drain(host)
        let username = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Username" })
        XCTAssertTrue(ownsFocus(username, window))
        window.makeFirstResponder(destination)
        model.text = "ordinary update"
        drain(host)
        XCTAssertTrue(ownsFocus(destination, window))
        model.request = UUID(); drain(host)
        XCTAssertTrue(ownsFocus(username, window))
    }

    func testEmbeddedSplitHostKeepsFocusScopeAfterUpdate() {
        _ = NSApplication.shared
        let model = SplitModel(), recorder = ScopeRecorder()
        let host = NSHostingView(rootView: SplitFixture(model: model, recorder: recorder))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drain(host)
        XCTAssertEqual(recorder.last, true)

        model.revision += 1
        drain(host)
        XCTAssertEqual(recorder.last, true)
    }

    func testNativeTraversalSkipsDisabledControlsAndIncludesButtonAndToggle() throws {
        let model = Model(); model.disabled = true
        let (window, host) = hosted(model)
        defer { window.close() }
        let source = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Source" })
        XCTAssertFalse(ownsFocus(source, window))
        window.sendEvent(tabEvent(in: window))
        XCTAssertTrue(ownsFocus(source, window))
        // Native fields dispatch Tab through their field editor and editing
        // delegate, which selects the next key view relative to the owner.
        source.currentEditor()?.insertTab(nil)
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, "Choose")
        window.selectNextKeyView(nil)
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, "Save")
        window.selectPreviousKeyView(nil)
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, "Choose")
        window.selectPreviousKeyView(nil)
        XCTAssertTrue(ownsFocus(source, window))
    }

    func testIndependentWindowsKeepRequestsScoped() throws {
        let first = Model(), second = Model()
        let (windowA, hostA) = hosted(first), (windowB, hostB) = hosted(second)
        defer { windowA.close(); windowB.close() }
        windowA.sendEvent(tabEvent(in: windowA))
        let destinationB = try XCTUnwrap(fields(hostB).first { $0.accessibilityLabel() == "Destination" })
        windowB.makeFirstResponder(destinationB)
        first.usernameVisible = true; first.request = UUID(); drain(hostA)
        XCTAssertTrue(ownsFocus(destinationB, windowB))
        XCTAssertTrue(ownsFocus(try XCTUnwrap(fields(hostA).first { $0.accessibilityLabel() == "Username" }), windowA))
    }

    private struct Editor: NSViewRepresentable {
        func makeNSView(context: Context) -> ComparisonTextView { ComparisonTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80), textContainer: nil) }
        func updateNSView(_ view: ComparisonTextView, context: Context) {}
    }
    private struct EditorFixture: View {
        var body: some View {
            VStack { StableTextField("Before", text: .constant("")); Editor().frame(height: 80); StableTextField("After", text: .constant("")) }.padding().nativeFocusRoot()
        }
    }
    private struct NativeEditor: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }
    func testOtherTextEditorsSupportControlTab() throws {
        try verifyControlTab([CommitPlaceholderTextView(frame: .zero), ReadOnlyDiffTextView(frame: .zero)])
    }
    func testTerminalControlTabRequiresActiveGUIWindow() throws {
        try verifyControlTab([TerminalSession(directory: FileManager.default.temporaryDirectory).view])
    }
    private func verifyControlTab(_ editors: [NSView]) throws {
        _ = NSApplication.shared
        for editor in editors {
            let host = NSHostingView(rootView: VStack { StableTextField("Before", text: .constant("")); NativeEditor(view: editor).frame(height: 80); StableTextField("After", text: .constant("")) }.padding().nativeFocusRoot().background(TerminalShortcutMonitor(toggle: {})))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            drain(host)
            window.makeKey()
            if editor is RepositoryTerminalView {
                try XCTSkipUnless(window.isKeyWindow, "This XCTest process cannot activate a key window; verify the terminal's scoped event monitor in the installed app.")
            }
            let before = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Before" })
            let after = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "After" })
            func tab(_ flags: NSEvent.ModifierFlags) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)! }
            XCTAssertTrue(window.makeFirstResponder(editor))
            if editor is RepositoryTerminalView { NSApplication.shared.sendEvent(tab(.control)) }
            else { editor.keyDown(with: tab(.control)) }
            XCTAssertTrue(ownsFocus(after, window), "\(type(of: editor)) forward")
            window.makeFirstResponder(editor)
            if editor is RepositoryTerminalView { NSApplication.shared.sendEvent(tab([.control, .shift])) }
            else { editor.keyDown(with: tab([.control, .shift])) }
            XCTAssertTrue(ownsFocus(before, window), "\(type(of: editor)) backward")
        }
    }
    func testCodeEditorRetainsTabAndControlTabLeavesInBothDirections() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: EditorFixture())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 250), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drain(host)
        func find(_ view: NSView) -> ComparisonTextView? { (view as? ComparisonTextView) ?? view.subviews.compactMap(find).first }
        let editor = try XCTUnwrap(find(host))
        let before = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Before" })
        let after = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "After" })
        func tab(_ flags: NSEvent.ModifierFlags) -> NSEvent { NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)! }
        window.makeFirstResponder(editor)
        editor.keyDown(with: tab([]))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.string, "\t")
        editor.keyDown(with: tab(.control))
        XCTAssertTrue(ownsFocus(after, window))
        window.makeFirstResponder(editor)
        editor.keyDown(with: tab([.control, .shift]))
        XCTAssertTrue(ownsFocus(before, window))
    }

    func testSheetPreventsParentRequestFromTakingFocus() throws {
        let parent = Model(), sheet = Model()
        let (window, host) = hosted(parent), (panel, panelHost) = hosted(sheet)
        defer { window.endSheet(panel); panel.close(); window.close() }
        panel.orderOut(nil)
        window.beginSheet(panel)
        drain(panelHost)
        parent.usernameVisible = true; parent.request = UUID(); drain(host)
        let source = try XCTUnwrap(fields(panelHost).first { $0.accessibilityLabel() == "Source" })
        XCTAssertFalse(ownsFocus(source, panel))
        panel.sendEvent(tabEvent(in: panel))
        XCTAssertTrue(ownsFocus(source, panel))
        XCTAssertFalse(ownsFocus(try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Username" }), window))
    }
    func testDeferredParentRequestWaitsForTabAfterSheetCloses() throws {
        let parent = Model(), sheet = Model()
        let (window, host) = hosted(parent), (panel, panelHost) = hosted(sheet)
        defer { if window.attachedSheet != nil { window.endSheet(panel) }; panel.close(); window.close() }
        panel.orderOut(nil); window.beginSheet(panel); drain(panelHost)
        parent.usernameVisible = true; parent.request = UUID(); drain(host)
        let username = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == "Username" })
        XCTAssertFalse(ownsFocus(username, window))
        window.endSheet(panel); drain(host)
        XCTAssertFalse(ownsFocus(username, window), "Closing a sheet must not focus a parent control")
        window.sendEvent(tabEvent(in: window))
        XCTAssertTrue(ownsFocus(username, window))
    }
    func testClonePresentationWaitsForTabWithoutStealingFocusOnUpdate() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let draft = defaults.object(forKey: RepositoryCreationDraft.preference)
        defer { if let draft { defaults.set(draft, forKey: RepositoryCreationDraft.preference) } else { defaults.removeObject(forKey: RepositoryCreationDraft.preference) } }
        defaults.removeObject(forKey: RepositoryCreationDraft.preference)
        let store = RepositoryStore(persistsSession: false)
        let host = NSHostingView(rootView: CreateRepositorySheet(store: store, initialClone: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = false
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        drain(host)
        let source = try XCTUnwrap(fields(host).first { $0.placeholderString == workflowText("Clone URL or local path") || $0.accessibilityLabel() == workflowText("Clone URL or local path") })
        XCTAssertFalse(ownsFocus(source, window), "Opening clone must leave its source unfocused")
        window.sendEvent(tabEvent(in: window))
        XCTAssertTrue(ownsFocus(source, window))
        XCTAssertTrue(window.autorecalculatesKeyViewLoop, "The presentation should enable native key-view recalculation")
        let destination = try XCTUnwrap(fields(host).first { $0.accessibilityLabel() == workflowText("Destination folder") })
        window.makeFirstResponder(destination)
        store.isBusy = false
        drain(host)
        XCTAssertTrue(ownsFocus(destination, window), "An ordinary update must not steal focus")
        destination.currentEditor()?.insertTab(nil)
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, workflowText("Choose parent folder…"))
        window.selectNextKeyView(nil)
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, workflowText("Cancel"))
        window.makeFirstResponder(source)
        source.currentEditor()?.insertBacktab(nil)
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, workflowText("Clone existing repository"))
    }
}
