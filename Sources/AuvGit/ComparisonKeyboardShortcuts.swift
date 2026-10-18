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
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }; return self.handle(event)
                }
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, !isHiddenOrHasHiddenAncestor else { return event }
            let controlFind = event.charactersIgnoringModifiers?.lowercased() == "f" && event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control
            let command = controlFind && (commands?.contains(.compareFind) ?? true) ? ShortcutCommand.compareFind : ShortcutCommand.allCases.first(where: { $0.scopes.contains(.comparison) && (commands?.contains($0) ?? true) && shortcuts.binding($0).matches(event) })
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
            _ = action(command)
            return nil
        }
    }
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.standalone = standalone; view.commands = commands; view.action = action }
}
