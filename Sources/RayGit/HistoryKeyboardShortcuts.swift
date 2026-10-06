import AppKit
import SwiftUI

/// History commands belong to their window; native text editing keeps copy and Return.
struct HistoryKeyboardRegion: NSViewRepresentable {
    let action: (HistoryAction) -> Void
    let find: () -> Void
    final class RegionView: NSView {
        var action: (HistoryAction) -> Void = { _ in }
        var find: () -> Void = {}
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
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                if (key == "c" && modifiers == .command) || (key == "\r" && modifiers.isEmpty) { return event }
            }
            if modifiers == .command, key == "f" { find(); return nil }
            let selectedAction: HistoryAction?
            switch (key, modifiers) {
            case ("r", .command): selectedAction = .reset
            case ("r", [.command, .shift]): selectedAction = .resetAdvanced
            case ("c", .command): selectedAction = .copyHash
            case ("l", .command): selectedAction = .viewLog
            case (String(UnicodeScalar(NSF7FunctionKey)!), []): selectedAction = .createBranch
            case (String(UnicodeScalar(NSF7FunctionKey)!), .shift): selectedAction = .createTag
            case ("\r", []): selectedAction = .show
            default: selectedAction = nil
            }
            guard let selectedAction else { return event }
            action(selectedAction); return nil
        }
    }
    func makeNSView(context: Context) -> RegionView { RegionView() }
    func updateNSView(_ view: RegionView, context: Context) { view.action = action; view.find = find }
}
