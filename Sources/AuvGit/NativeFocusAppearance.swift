import AppKit
import Combine

/// Focus ownership and editing stay native. Keyboard navigation or an explicit
/// dialog default reveals rings, including when its window becomes key again.
/// Roots and standalone fields share one mode for their window, while sheets
/// and popovers start with their own hidden mode.
@MainActor
final class NativeFocusAppearance: ObservableObject {
    private static let windows = NSMapTable<NSWindow, NativeFocusAppearance>.weakToWeakObjects()
    // SwiftUI sheet content can move into a native panel while its rings are hidden.
    // Preserve the control's original style across those window-scoped states.
    private static let originalRings = NSMapTable<NSView, NSNumber>.weakToStrongObjects()
    @Published private(set) var isVisible = false
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var hasInteracted = false
    private var restoresKeyboardFocus = false
    let contextRowFocus = NativeContextRowFocus()
    weak var navigationScope: NativeFocusCoordinator?
    private struct Ring {
        weak var view: NSView?
        let original: NSFocusRingType
    }
    private var rings: [ObjectIdentifier: Ring] = [:]
    private var applicationPending = false

    static func forWindow(_ window: NSWindow) -> NativeFocusAppearance {
        if let existing = windows.object(forKey: window) { return existing }
        let state = NativeFocusAppearance(window: window)
        windows.setObject(state, forKey: window)
        return state
    }

    static func isVisible(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windows.object(forKey: window)?.isVisible ?? false
    }

    static func rememberOriginalRing(for view: NSView) {
        originalRings.setObject(NSNumber(value: view.focusRingType.rawValue), forKey: view)
    }

    private init(window: NSWindow) {
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.apply() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.restoresKeyboardFocus = self.isVisible
                    self.contextRowFocus.clear()
                    self.setVisible(false)
                }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.restoresKeyboardFocus { self.setVisible(true) }
                    self.clearInitialFocus()
                }
            })
        clearInitialFocus()
        DispatchQueue.main.async { [weak self] in self?.clearInitialFocus() }
        apply()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach(NotificationCenter.default.removeObserver)
        let saved = Array(rings.values)
        DispatchQueue.main.async { [weak window] in
            for ring in saved where ring.view?.window === window { ring.view?.focusRingType = ring.original }
        }
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil else { return false }
        hasInteracted = true
        contextRowFocus.handle(event, in: window)
        if event.type != .keyDown { restoresKeyboardFocus = false; setVisible(false); return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 48, flags.subtracting([.control, .shift]).isEmpty {
            // Tab remains literal input in editors and during shortcut capture.
            if let recorder = window.firstResponder as? ShortcutRecorder.RecorderView, recorder.isRecording { return false }
            if !flags.contains(.control), ownsEditorInput(window.firstResponder) { return false }
            setVisible(true)
            // Popover presentation can replace window.nextResponder. Enter
            // through the monitor before AppKit dispatches this first Tab.
            return navigationScope?.enterKeyViewLoop(backwards: flags.contains(.shift)) ?? false
        } else if event.keyCode == 53, flags.isEmpty {
            // Let IME composition and the control's own Escape action run first.
            if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
            restoresKeyboardFocus = false
            setVisible(false)
            let responder = window.firstResponder
            DispatchQueue.main.async { [weak window, weak responder] in
                guard let window, let responder, window.attachedSheet == nil,
                      window.firstResponder === responder else { return }
                window.makeFirstResponder(window)
            }
        }
        return false
    }

    func beginNavigation() {
        hasInteracted = true
        setVisible(true)
    }

    func preserveExplicitFocus() { hasInteracted = true }

    private func clearInitialFocus() {
        guard !hasInteracted, let window, window.attachedSheet == nil else { return }
        window.initialFirstResponder = nil
        window.makeFirstResponder(window)
    }

    func apply() {
        guard let content = window?.contentView else { return }
        rings = rings.filter { $0.value.view?.window === window }
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            let id = ObjectIdentifier(view)
            if rings[id] == nil {
                let original = Self.originalRings.object(forKey: view).flatMap { NSFocusRingType(rawValue: $0.uintValue) } ?? view.focusRingType
                Self.originalRings.setObject(NSNumber(value: original.rawValue), forKey: view)
                rings[id] = Ring(view: view, original: original)
            }
            let desired = isVisible ? rings[id]!.original : .none
            if view.focusRingType != desired {
                view.focusRingType = desired
                view.needsDisplay = true
            }
            view.subviews.forEach(visit)
        }
        visit(content)
        contextRowFocus.apply()
        clearInitialFocus()
    }

    func scheduleApply() {
        guard !applicationPending else { return }
        applicationPending = true
        DispatchQueue.main.async { [weak self] in
            self?.applicationPending = false
            self?.apply()
        }
    }

    private func setVisible(_ visible: Bool) {
        if isVisible != visible {
            isVisible = visible
            func redraw(_ view: NSView) {
                if view is ShortcutRecorder.RecorderView { view.needsDisplay = true }
                view.subviews.forEach(redraw)
            }
            if let content = window?.contentView { redraw(content) }
        }
        apply()
    }

    private func ownsEditorInput(_ responder: NSResponder?) -> Bool {
        if let text = responder as? NSTextView, !text.isFieldEditor { return true }
        var view = responder as? NSView
        while let current = view {
            if current is RepositoryTerminalView { return true }
            view = current.superview
        }
        return false
    }
}
