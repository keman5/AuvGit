import AppKit
import SwiftUI

/// A native responder gives Select All / Copy their normal macOS behavior.
struct OperationLogTextView: NSViewRepresentable {
    let content: String
    let focused: Bool
    let onFocus: () -> Void
    final class Coordinator { var focused = false }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let text = OperationDetailTextView(frame: NSRect(x: 0, y: 0, width: 680, height: 100))
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 5, height: 5)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize.height = CGFloat.greatestFiniteMagnitude
        text.drawsBackground = false
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? OperationDetailTextView else { return }
        text.onFocus = onFocus
        if text.string != content { text.string = content; text.sizeToFit(); text.setFrameOrigin(.zero) }
        if focused && !context.coordinator.focused {
            DispatchQueue.main.async { [weak text] in
                guard let text, let window = text.window else { return }
                window.makeFirstResponder(text)
            }
        }
        context.coordinator.focused = focused
    }
}
private final class OperationDetailTextView: NSTextView {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
}
