import AppKit
import SwiftUI

/// One coordinator per presentation. AppKit owns the key-view order; requests
/// only choose an initial target or explicitly move focus after an insertion.
@MainActor
final class NativeFocusCoordinator: ObservableObject {
    private final class Target {
        weak var view: NSView?
        var initial: Bool
        var request: UUID?
        var acknowledged: UUID?
        init(_ view: NSView, initial: Bool, request: UUID?) {
            self.view = view; self.initial = initial; self.request = request
        }
    }
    private var targets: [ObjectIdentifier: Target] = [:]
    private weak var window: NSWindow?
    private var initialApplied = false
    private var pending: DispatchWorkItem?
    private var shouldRecalculateLoop = false
    private var entryResponder: EntryResponder?
    private final class EntryResponder: NSResponder {
        weak var scope: NativeFocusCoordinator?
        init(scope: NativeFocusCoordinator) { self.scope = scope; super.init() }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               scope?.enterKeyViewLoop(backwards: event.modifierFlags.contains(.shift)) == true { return }
            super.keyDown(with: event)
        }
        override func insertTab(_ sender: Any?) {
            if scope?.enterKeyViewLoop(backwards: false) != true { super.insertTab(sender) }
        }
        override func insertBacktab(_ sender: Any?) {
            if scope?.enterKeyViewLoop(backwards: true) != true { super.insertBacktab(sender) }
        }
        func unlink(from window: NSWindow?) {
            var previous: NSResponder? = window
            var visited = Set<ObjectIdentifier>()
            while let node = previous, visited.insert(ObjectIdentifier(node)).inserted {
                if node.nextResponder === self { node.nextResponder = nextResponder; break }
                previous = node.nextResponder
            }
        }
    }
    deinit {
        pending?.cancel()
        // Keep the responder alive until its weak chain links are repaired
        // on the UI thread, including standalone fields' fallback scopes.
        DispatchQueue.main.async { [entryResponder, window] in entryResponder?.unlink(from: window) }
    }

    func attach(to window: NSWindow?) {
        guard let window else { return }
        let changedWindow = self.window !== window
        if changedWindow { removeEntryResponder() }
        self.window = window
        window.autorecalculatesKeyViewLoop = true
        if entryResponder == nil {
            let responder = EntryResponder(scope: self)
            responder.nextResponder = window.nextResponder
            window.nextResponder = responder
            entryResponder = responder
        }
        schedule(recalculatingLoop: changedWindow)
    }
    func register(_ view: NSView, initial: Bool = false, request: UUID? = nil) {
        let key = ObjectIdentifier(view)
        let changed: Bool
        if let target = targets[key] {
            changed = target.initial != initial || target.request != request
            target.initial = initial; target.request = request
        } else {
            targets[key] = Target(view, initial: initial, request: request)
            changed = true
        }
        schedule(recalculatingLoop: changed)
    }
    func unregister(_ view: NSView) {
        let removed = targets.removeValue(forKey: ObjectIdentifier(view)) != nil
        schedule(recalculatingLoop: removed)
    }
    func cancel() { pending?.cancel(); pending = nil; removeEntryResponder() }
    private func removeEntryResponder() {
        entryResponder?.unlink(from: window)
        entryResponder?.scope = nil; entryResponder = nil
    }
    private func enterKeyViewLoop(backwards: Bool) -> Bool {
        guard let window, window.firstResponder === window, window.attachedSheet == nil else { return false }
        window.recalculateKeyViewLoop()
        if let view = targets.values.first(where: { $0.initial && $0.view.map { isAvailable($0, in: window) } == true })?.view {
            if window.makeFirstResponder(view) { initialApplied = true; return true }
        }
        if backwards { window.selectPreviousKeyView(nil) } else { window.selectNextKeyView(nil) }
        return window.firstResponder !== window
    }
    func schedule(recalculatingLoop: Bool = false) {
        shouldRecalculateLoop = shouldRecalculateLoop || recalculatingLoop
        guard pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.refresh()
        }
        pending = work
        DispatchQueue.main.async(execute: work)
    }
    private func refresh() {
        guard let window else { return }
        if shouldRecalculateLoop { window.recalculateKeyViewLoop(); shouldRecalculateLoop = false }
        targets = targets.filter { $0.value.view != nil }
        guard window.attachedSheet == nil else { return }
        let available = targets.values.filter { $0.view.map { isAvailable($0, in: window) } == true }
        if let target = available.first(where: { $0.request != nil && $0.request != $0.acknowledged }), let view = target.view,
           window.makeFirstResponder(view) {
            target.acknowledged = target.request
            initialApplied = true
        } else if let view = available.first(where: { $0.initial })?.view {
            window.initialFirstResponder = view
            if !initialApplied, window.makeFirstResponder(view) { initialApplied = true }
        }
    }
    private func isAvailable(_ view: NSView, in window: NSWindow) -> Bool {
        view.window === window && !view.isHiddenOrHasHiddenAncestor && view.acceptsFirstResponder && (view as? NSControl)?.isEnabled != false
    }
}

private struct NativeFocusScopeKey: EnvironmentKey {
    static let defaultValue: NativeFocusCoordinator? = nil
}
extension EnvironmentValues {
    var nativeFocusScope: NativeFocusCoordinator? {
        get { self[NativeFocusScopeKey.self] }
        set { self[NativeFocusScopeKey.self] = newValue }
    }
}

struct NativeFocusBridge: NSViewRepresentable {
    let scope: NativeFocusCoordinator
    func makeNSView(context: Context) -> RootView { RootView(scope: scope) }
    func updateNSView(_ view: RootView, context: Context) { scope.attach(to: view.window); scope.schedule() }
    static func dismantleNSView(_ view: RootView, coordinator: ()) { view.scope.cancel() }
    final class RootView: NSView {
        let scope: NativeFocusCoordinator
        init(scope: NativeFocusCoordinator) { self.scope = scope; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scope.attach(to: window) }
    }
}

private struct NativeFocusRoot: ViewModifier {
    var reusingParent: Bool
    @Environment(\.nativeFocusScope) private var inherited
    @StateObject private var scope = NativeFocusCoordinator()
    @ViewBuilder func body(content: Content) -> some View {
        if reusingParent && inherited != nil { content }
        else { content.environment(\.nativeFocusScope, scope).background(NativeFocusBridge(scope: scope).frame(width: 0, height: 0)) }
    }
}
extension View {
    func nativeFocusRoot(reusingParent: Bool = false) -> some View { modifier(NativeFocusRoot(reusingParent: reusingParent)) }
}

/// Native action/checkbox for controls whose SwiftUI host has no key-view stop.
/// NSButton supplies activation, accessibility actions and the system focus ring.
struct KeyViewProxy: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeFocusScope) private var scope
    let label: String
    var checked: Bool? = nil
    var keyEquivalent = ""
    var prominent = false
    let action: () -> Void
    final class Button: NSButton {
        var activate: (() -> Void)?
        override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
        override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return acceptsFirstResponder }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
        @objc func invoke(_ sender: Any?) { activate?() }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button(title: label, target: nil, action: nil)
        button.target = button; button.action = #selector(Button.invoke(_:))
        button.bezelStyle = .rounded
        button.focusRingType = .default
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.title = label; button.setAccessibilityLabel(label)
        button.isEnabled = enabled; button.activate = action
        button.controlSize = .small
        button.keyEquivalent = keyEquivalent; button.keyEquivalentModifierMask = []
        button.bezelColor = prominent ? .controlAccentColor : nil
        if let checked { button.setButtonType(.switch); button.state = checked ? .on : .off }
        else { button.setButtonType(.momentaryPushIn) }
        scope?.register(button)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? { nsView.intrinsicContentSize }
}

enum NativeFocusNavigation {
    static var editorHelp: String { workflowText("Use Control-Tab or Control-Shift-Tab to leave the terminal or code editor.") }
    /// Editors keep Tab for input; only this exact Control chord leaves them.
    static func leaveEditor(_ event: NSEvent, from view: NSView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 48, flags == .control || flags == [.control, .shift],
              let window = view.window, window.firstResponder === view, window.attachedSheet == nil else { return false }
        window.recalculateKeyViewLoop()
        if flags.contains(.shift) { window.selectPreviousKeyView(nil) }
        else { window.selectNextKeyView(nil) }
        return true
    }
}
