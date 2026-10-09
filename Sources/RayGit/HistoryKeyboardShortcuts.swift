import AppKit
import SwiftUI

/// History commands belong to their window; native text editing keeps copy and Return.
struct HistoryKeyboardRegion: NSViewRepresentable {
    let action: (HistoryAction) -> Void
    let find: () -> Void
    var navigate: (Bool) -> Void = { _ in }
    var showChanges: () -> Void = {}
    final class RegionView: NSView {
        var shortcuts = KeyboardShortcuts.shared
        var action: (HistoryAction) -> Void = { _ in }
        var find: () -> Void = {}
        var navigate: (Bool) -> Void = { _ in }
        var showChanges: () -> Void = {}
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    return self.handle(event)
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, window.attachedSheet == nil, event.window === window,
                  !isHiddenOrHasHiddenAncestor else { return event }
            if Self.terminalOwnsFocus(window.firstResponder) { return event }
            if window.firstResponder is ReadOnlyDiffTextView || window.firstResponder is ComparisonTextView { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                if (key == "c" && modifiers == .command) || (key == "\r" && modifiers.isEmpty) { return event }
                if shortcuts.binding(.selectChildCommit).matches(event) || shortcuts.binding(.selectParentCommit).matches(event) { return event }
                if [.checkout, .rebase, .useCommitMessage, .showChanges].contains(where: { shortcuts.binding($0).matches(event) }) { return event }
            }
            if shortcuts.binding(.showChanges).matches(event) { showChanges(); return nil }
            if shortcuts.binding(.selectChildCommit).matches(event) { navigate(true); return nil }
            if shortcuts.binding(.selectParentCommit).matches(event) { navigate(false); return nil }
            if shortcuts.binding(.find).matches(event) { find(); return nil }
            guard let command = ShortcutCommand.allCases.first(where: { $0.historyAction != nil && shortcuts.binding($0).matches(event) }),
                  let selectedAction = command.historyAction else { return event }
            action(selectedAction); return nil
        }
        private static func terminalOwnsFocus(_ responder: NSResponder?) -> Bool {
            var view = responder as? NSView
            while let current = view {
                if current is RepositoryTerminalView { return true }
                view = current.superview
            }
            return false
        }
    }
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.action = action; view.find = find; view.navigate = navigate; view.showChanges = showChanges }
}
