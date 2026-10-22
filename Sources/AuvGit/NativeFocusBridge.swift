import AppKit
import SwiftUI
import Combine

/// AppKit owns the key-view order. Controls wait for Tab before entering the loop
/// unless a presentation explicitly opts into initial focus.
@MainActor
final class NativeFocusCoordinator: ObservableObject {
    @Published private(set) var showsKeyboardFocus = false
    private var appearance: NativeFocusAppearance?
    private var appearanceSubscription: AnyCancellable?
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
    private var pending: DispatchWorkItem?
    private var shouldRecalculateLoop = false
    private var entryResponder: EntryResponder?
    var focusesOnPresentation = false
    private var presentationFocused = false
    private var popoverObserver: NSObjectProtocol?
    private var presentationObserver: NSObjectProtocol?
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
        if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver) }
        if let presentationObserver { NotificationCenter.default.removeObserver(presentationObserver) }
        // Keep the responder alive until its weak chain links are repaired
        // on the UI thread, including standalone fields' fallback scopes.
        DispatchQueue.main.async { [entryResponder, window] in entryResponder?.unlink(from: window) }
    }

    func attach(to window: NSWindow?) {
        guard let window else { return }
        let changedWindow = self.window !== window
        if changedWindow { removeEntryResponder(); presentationFocused = false }
        self.window = window
        if changedWindow {
            if let presentationObserver { NotificationCenter.default.removeObserver(presentationObserver) }
            presentationObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.focusesOnPresentation,
                          !self.presentationFocused || self.window?.firstResponder === self.window,
                          self.window?.isVisible == true else { return }
                    self.schedule()
                }
            }
            if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver) }
            popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.didShowNotification,
                object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.focusesOnPresentation,
                          let popover = notification.object as? NSPopover,
                          popover.contentViewController?.view.window === self.window else { return }
                    // AppKit resets the responder while presenting the popover.
                    self.presentationFocused = false
                    self.schedule()
                }
            }
            appearance = NativeFocusAppearance.forWindow(window)
            appearanceSubscription = appearance?.$isVisible.sink { [weak self] visible in
                guard self?.showsKeyboardFocus != visible else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.showsKeyboardFocus = self.appearance?.isVisible ?? false
                }
            }
        }
        appearance?.navigationScope = self
        appearance?.scheduleApply()
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
    func cancel() {
        pending?.cancel(); pending = nil; removeEntryResponder()
        if let popoverObserver { NotificationCenter.default.removeObserver(popoverObserver) }
        popoverObserver = nil
        if let presentationObserver { NotificationCenter.default.removeObserver(presentationObserver) }
        presentationObserver = nil
        appearanceSubscription = nil; appearance = nil
        window = nil
    }
    private func removeEntryResponder() {
        entryResponder?.unlink(from: window)
        entryResponder?.scope = nil; entryResponder = nil
    }
    func enterKeyViewLoop(backwards: Bool) -> Bool {
        guard let window, window.firstResponder === window, window.attachedSheet == nil else { return false }
        appearance?.beginNavigation()
        window.recalculateKeyViewLoop()
        let available = targets.values.filter { $0.view.map { isAvailable($0, in: window) } == true }
        if !backwards, let target = available.first(where: { $0.request != nil && $0.request != $0.acknowledged })
            ?? available.first(where: { $0.initial }), let view = target.view, window.makeFirstResponder(view) {
            target.acknowledged = target.request
            return true
        }
        // NSWindow.selectNextKeyView cannot always enter a SwiftUI button loop
        // when the window itself owns first responder. Start at its content.
        if let content = window.contentView,
           let view = backwards ? content.previousValidKeyView : content.nextValidKeyView,
           window.makeFirstResponder(view) { return true }
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
        appearance?.scheduleApply()
        targets = targets.filter { $0.value.view != nil }
        if focusesOnPresentation, (!presentationFocused || window.firstResponder === window), window.isVisible, window.attachedSheet == nil {
            if window.isVisible && window.canBecomeKey { window.makeKey() }
            DialogAppearance.configureDefaultButton(in: window)
            let initial = targets.values.first { $0.initial && $0.view.map { isAvailable($0, in: window) } == true }?.view
            func input(in view: NSView) -> NSView? {
                guard !view.isHiddenOrHasHiddenAncestor else { return nil }
                if let field = view as? NSTextField, field.isEditable, isAvailable(field, in: window) { return field }
                if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor, isAvailable(editor, in: window) { return editor }
                return view.subviews.lazy.compactMap { input(in: $0) }.first
            }
            let editable = window.contentView.flatMap { input(in: $0) }
            let button = window.defaultButtonCell?.controlView.flatMap { isAvailable($0, in: window) ? $0 : nil }
            let fallback = window.contentView?.nextValidKeyView
            if let view = button ?? initial ?? editable ?? fallback, isAvailable(view, in: window) {
                appearance?.beginNavigation()
                window.initialFirstResponder = view
                if window.makeFirstResponder(view) {
                    if !presentationFocused, let field = view as? NSTextField { field.selectText(nil) }
                    presentationFocused = true
                }
            }
        }
        guard window.attachedSheet == nil, appearance?.isVisible == true, window.firstResponder !== window else { return }
        let available = targets.values.filter { $0.view.map { isAvailable($0, in: window) } == true }
        if let target = available.first(where: { $0.request != nil && $0.request != $0.acknowledged }), let view = target.view,
           window.makeFirstResponder(view) {
            target.acknowledged = target.request
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
    var focusesOnPresentation = false
    func makeNSView(context: Context) -> RootView {
        scope.focusesOnPresentation = focusesOnPresentation
        return RootView(scope: scope)
    }
    func updateNSView(_ view: RootView, context: Context) {
        scope.focusesOnPresentation = focusesOnPresentation
        scope.attach(to: view.window); scope.schedule()
    }
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
    var focusesOnPresentation: Bool
    @Environment(\.nativeFocusScope) private var inherited
    @StateObject private var scope = NativeFocusCoordinator()
    @ViewBuilder func body(content: Content) -> some View {
        if reusingParent && inherited != nil { content }
        else {
            content.environment(\.nativeFocusScope, scope)
                .focusEffectDisabled(!scope.showsKeyboardFocus)
                .background(NativeFocusBridge(scope: scope, focusesOnPresentation: focusesOnPresentation).frame(width: 0, height: 0))
        }
    }
}
extension View {
    func nativeFocusRoot(reusingParent: Bool = false, focusesOnPresentation: Bool = false) -> some View {
        modifier(NativeFocusRoot(reusingParent: reusingParent, focusesOnPresentation: focusesOnPresentation))
    }
}

/// Native action/checkbox for controls whose SwiftUI host has no key-view stop.
/// NSButton supplies activation, accessibility actions and the system focus ring.
struct KeyViewProxy: NSViewRepresentable {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.nativeFocusScope) private var scope
    let label: String
    var checked: Bool? = nil
    var keyEquivalent = ""
    var prominent = false
    var minimumWidth: CGFloat = 0
    var tint: NSColor? = nil
    let action: () -> Void
    private var nativeControlSize: NSControl.ControlSize {
        guard checked != nil else { return .regular }
        // SwiftUI reapplies its environment size after representable updates.
        // Match it from the first draw instead of starting checkboxes at small.
        switch controlSize {
        case .mini: return .mini
        case .small: return .small
        case .large: return .large
        default: return .regular
        }
    }
    final class Button: NSButton {
        var activate: (() -> Void)?
        var declaredKeyEquivalent: String?
        var isPrimaryAction = false
        var isCheckbox = false
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            if !isCheckbox { size.height = AuvGitDialogButtonStyle.height }
            return size
        }
        override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
        override var canBecomeKeyView: Bool { acceptsFirstResponder && window != nil }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; noteFocusRingMaskChanged(); return acceptsFirstResponder }
        override func resignFirstResponder() -> Bool { needsDisplay = true; noteFocusRingMaskChanged(); return true }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 5, yRadius: 5).fill()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.sheetParent != nil || window is NSPanel {
                DialogAppearance.configureDefaultButton(in: window)
            }
        }
        @objc func invoke(_ sender: Any?) { activate?() }
        override func keyDown(with event: NSEvent) {
            if isCheckbox, event.keyCode == 49,
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                if isEnabled && !event.isARepeat { invoke(nil) }
                return
            }
            super.keyDown(with: event)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if declaredKeyEquivalent == "\u{1b}", event.keyCode == 53,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty, isEnabled {
                invoke(nil); return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button(title: label, target: nil, action: nil)
        button.target = button; button.action = #selector(Button.invoke(_:))
        button.bezelStyle = .rounded
        button.isCheckbox = checked != nil
        button.setButtonType(checked == nil ? .momentaryPushIn : .switch)
        button.controlSize = nativeControlSize
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        button.focusRingType = .exterior
        NativeFocusAppearance.rememberOriginalRing(for: button)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.title = label; button.setAccessibilityLabel(label)
        button.isEnabled = enabled; button.activate = action
        button.keyEquivalent = keyEquivalent.isEmpty && prominent && checked == nil ? "\r" : keyEquivalent; button.keyEquivalentModifierMask = []
        button.declaredKeyEquivalent = button.keyEquivalent
        button.isPrimaryAction = prominent && checked == nil
        if button.isCheckbox != (checked != nil) {
            button.setButtonType(checked == nil ? .momentaryPushIn : .switch)
            button.isCheckbox = checked != nil
        }
        // AppKit type changes reset cell metrics. Configure type first, then
        // apply the same size/font on creation and every state update.
        button.controlSize = nativeControlSize
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: button.controlSize))
        button.bezelColor = prominent ? .controlAccentColor : nil
        button.contentTintColor = tint
        if let checked { button.state = checked ? .on : .off }
        scope?.register(button)
        if let window = button.window, window.sheetParent != nil || window is NSPanel {
            DialogAppearance.configureDefaultButton(in: window)
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? {
        CGSize(width: max(minimumWidth, nsView.intrinsicContentSize.width),
               height: checked == nil ? AuvGitDialogButtonStyle.height : nsView.intrinsicContentSize.height)
    }
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
