import AppKit
import SwiftUI

/// Scope membership stays green, independently of the blue selected reference.
struct LogScopeCheckbox: NSViewRepresentable {
    @Environment(\.nativeFocusScope) private var scope
    @Environment(\.isEnabled) private var enabled
    let title: String
    @Binding var isOn: Bool
    func makeNSView(context: Context) -> Button {
        let button = Button(checkboxWithTitle: "", target: nil, action: nil)
        button.target = button; button.action = #selector(Button.toggleScope)
        button.focusRingType = .exterior
        NativeFocusAppearance.rememberOriginalRing(for: button)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        button.state = isOn ? .on : .off
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        button.changed = { isOn = $0 }
        button.needsDisplay = true
        scope?.register(button)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Button, context: Context) -> CGSize? { CGSize(width: 22, height: 24) }
    final class Button: NSButton {
        var changed: ((Bool) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
        override func accessibilityValue() -> Any? { state == .on ? 1 : 0 }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if !event.isARepeat { performClick(nil) }
            } else { super.keyDown(with: event) }
        }
        @objc func toggleScope() { changed?(state == .on); needsDisplay = true }
        private var box: NSRect { NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14) }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            let color: NSColor = isEnabled ? .systemGreen : .disabledControlTextColor
            (state == .on ? color : .textBackgroundColor).setFill(); path.fill()
            (state == .on ? color : .separatorColor).setStroke(); path.lineWidth = 1; path.stroke()
            if state == .on {
                let check = NSBezierPath()
                // NSButton uses flipped coordinates; keep the checkmark rising to the right.
                let lowY = isFlipped ? box.maxY - 4 : box.minY + 4
                let highY = isFlipped ? box.minY + 4 : box.maxY - 4
                check.move(to: NSPoint(x: box.minX + 3, y: box.midY))
                check.line(to: NSPoint(x: box.minX + 6, y: lowY))
                check.line(to: NSPoint(x: box.maxX - 3, y: highY))
                NSColor.white.setStroke(); check.lineWidth = 1.7; check.lineCapStyle = .round; check.lineJoinStyle = .round; check.stroke()
            }
        }
        override var focusRingMaskBounds: NSRect { box }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill() }
    }
}
