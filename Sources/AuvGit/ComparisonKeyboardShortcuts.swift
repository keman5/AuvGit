import AppKit
import SwiftUI

/// Embedded previews own shortcuts only while a comparison document has focus.
struct ComparisonKeyboardRegion: NSViewRepresentable {
    var standalone = false
    var commands: Set<ShortcutCommand>? = nil
    var action: (ShortcutCommand) -> Bool
    final class RegionView: NSView {
        var standalone = false
        var commands: Set<ShortcutCommand>?
        var shortcuts = KeyboardShortcuts.shared
        var action: (ShortcutCommand) -> Bool = { _ in false }
        private var monitor: Any?
        private var searchPresentationObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            cancelSearchFocusRequest()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                    guard let self else { return event }
                    if event.type == .leftMouseDown { self.cancelSearchFocusRequest(); return event }
                    return self.handle(event)
                }
            }
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let searchPresentationObserver { NotificationCenter.default.removeObserver(searchPresentationObserver) }
        }
        private func cancelSearchFocusRequest() {
            if let searchPresentationObserver { NotificationCenter.default.removeObserver(searchPresentationObserver) }
            searchPresentationObserver = nil
        }
        private func requestSearchFocus(in window: NSWindow) {
            cancelSearchFocusRequest()
            // SwiftUI creates the search field after the shortcut handler returns;
            // AppKit may reset its responder again while presenting the popover.
            searchPresentationObserver = NotificationCenter.default.addObserver(forName: NSPopover.didShowNotification,
                object: nil, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, self.window === window else { return }
                    if ComparisonSearchField.focusQuery(in: window) { self.cancelSearchFocusRequest() }
                }
            }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.searchPresentationObserver != nil else { return }
                _ = ComparisonSearchField.focusQuery(in: window)
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return event }
            cancelSearchFocusRequest()
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // Once the query owns typing, Shift-F must still insert an uppercase F.
            if modifiers == .shift, ComparisonSearchField.isEditingQuery(in: window) { return event }
            let findAlias = event.charactersIgnoringModifiers?.lowercased() == "f" &&
                [NSEvent.ModifierFlags.control, .shift].contains(modifiers)
            let command = findAlias && (commands?.contains(.compareFind) ?? true) ? ShortcutCommand.compareFind : ShortcutCommand.allCases.first(where: { $0.scopes.contains(.comparison) && (commands?.contains($0) ?? true) && shortcuts.binding($0).matches(event) })
            guard let command else { return event }
            // A popover can receive keys addressed to its comparison parent window.
            if command == .compareFind, ComparisonSearchField.focusQuery(in: window) { return nil }
            if !standalone {
                guard let responder = window.firstResponder as? NSView, responder is ReadOnlyDiffTextView || responder is ComparisonTextView else { return event }
                let center = NSPoint(x: responder.visibleRect.midX, y: responder.visibleRect.midY)
                guard bounds.contains(responder.convert(center, to: self)) else { return event }
            }
            let editingField = (window.firstResponder as? NSTextView)?.isFieldEditor == true || window.firstResponder is NSTextField
            if editingField, ![.compareFind, .compareFindNext, .compareFindPrevious].contains(command) { return event }
            if command == .compareFind { requestSearchFocus(in: window) }
            if !action(command) { cancelSearchFocusRequest() }
            return nil
        }
    }
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.standalone = standalone; view.commands = commands; view.action = action }
}
