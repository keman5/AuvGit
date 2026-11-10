import AppKit
import SwiftUI

extension Notification.Name { static let auvGitWorkspaceShortcut = Notification.Name("AuvGitWorkspaceShortcut") }

struct WorkspaceKeyboardRegion: NSViewRepresentable {
    let action: (ShortcutCommand) -> Bool
    var onWindow: (NSWindow?) -> Void = { _ in }
    var menuAction: ((ShortcutCommand) -> Bool)? = nil
    final class RegionView: NSView {
        var shortcuts = KeyboardShortcuts.shared
        var action: (ShortcutCommand) -> Bool = { _ in false }
        var onWindow: (NSWindow?) -> Void = { _ in }
        var menuAction: ((ShortcutCommand) -> Bool)?
        private var monitor: Any?
        private var observer: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in guard let self else { return }; onWindow(window) }
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return handle(event)
            }
            observer = NotificationCenter.default.addObserver(forName: .auvGitWorkspaceShortcut, object: nil, queue: .main) { [weak self] notification in
                guard let self, let window, !isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
                      let target = notification.userInfo?["window"] as? NSWindow, target === window,
                      let raw = notification.object as? String, let command = ShortcutCommand(rawValue: raw) else { return }
                _ = (menuAction ?? action)(command)
            }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return event }
            // SwiftTerm is an NSView, not an NSTextView. A remembered file scope
            // must not consume Return, Delete or shell editing chords from it.
            var inputView = window.firstResponder as? NSView
            while let current = inputView {
                if current is RepositoryTerminalView { return event }
                inputView = current.superview
            }
            let responder = window.firstResponder as? NSView
            let textEditing = (responder is NSTextView || responder is NSTextField) &&
                responder.map { WorkspaceFileFocus.isExposed($0, in: window) } == true
            for command in ShortcutCommand.allCases where (command.scopes.contains(.workspace) || command.scopes.contains(.files)) && shortcuts.binding(command).matches(event) {
                if textEditing && !command.worksWhileEditingText { continue }
                if command == .reset || command == .resetAdvanced {
                    if window.firstResponder is ReadOnlyDiffTextView || window.firstResponder is ComparisonTextView { continue }
                }
                if action(command) { return nil }
            }
            return event
        }
    }
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.action = action; view.onWindow = onWindow; view.menuAction = menuAction }
}
