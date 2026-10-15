import AppKit
import SwiftUI

// Shared by keyDown and performKeyEquivalent so Command chords never reach menus.
func recordedShortcut(_ event: NSEvent, preserving value: ShortcutBinding) -> ShortcutBinding? {
    guard event.type == .keyDown, let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first else { return nil }
    let special: [UInt32: String] = [13: "Return", 3: "Return", 127: "Backspace", 9: "Tab", 32: "Space", UInt32(NSDeleteFunctionKey): "Delete", UInt32(NSUpArrowFunctionKey): "Up", UInt32(NSDownArrowFunctionKey): "Down", UInt32(NSLeftArrowFunctionKey): "Left", UInt32(NSRightArrowFunctionKey): "Right", UInt32(NSPageUpFunctionKey): "PageUp", UInt32(NSPageDownFunctionKey): "PageDown", UInt32(NSHomeFunctionKey): "Home", UInt32(NSEndFunctionKey): "End"]
    let key: String
    if let name = special[scalar.value] { key = name }
    else if (UInt32(NSF1FunctionKey)...UInt32(NSF20FunctionKey)).contains(scalar.value) { key = "F\(scalar.value - UInt32(NSF1FunctionKey) + 1)" }
    else if characters.count == 1, ShortcutBinding.supportsKey(characters.lowercased()) { key = characters.lowercased() }
    else { return nil }
    var result = value
    result.key = key
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    if !flags.isEmpty { result.modifiers = [(1, NSEvent.ModifierFlags.command), (2, .shift), (4, .option), (8, .control)].reduce(0) { $0 | (flags.contains($1.1) ? $1.0 : 0) } }
    return result
}

struct ShortcutRecorder: NSViewRepresentable {
    var value: ShortcutBinding
    var label: String
    var onChange: (ShortcutBinding) -> Void
    func makeNSView(context: Context) -> RecorderView { RecorderView() }
    func updateNSView(_ view: RecorderView, context: Context) {
        view.value = value; view.onChange = onChange
        view.setAccessibilityValue(value.key)
        view.setAccessibilityLabel(label)
        view.needsDisplay = true
    }
    final class RecorderView: NSView {
        var value = ShortcutBinding(key: "", modifiers: 0)
        var onChange: ((ShortcutBinding) -> Void)?
        private var keyMonitor: Any?
        private var recording = false
        var isRecording: Bool { recording }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.recording, self.window?.firstResponder === self, event.window === self.window else { return event }
                self.keyDown(with: event)
                return nil
            }
        }
        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.textField) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
        override func resignFirstResponder() -> Bool { recording = false; needsDisplay = true; return true }
        override func accessibilityPerformPress() -> Bool {
            guard window?.makeFirstResponder(self) == true else { return false }
            recording = true; needsDisplay = true; return true
        }
        override func mouseDown(with event: NSEvent) { _ = accessibilityPerformPress() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self else { return false }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            if !recording {
                let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
                if event.keyCode == 48, flags.isEmpty || flags == .shift {
                    if flags.contains(.shift) { window?.selectPreviousKeyView(nil) } else { window?.selectNextKeyView(nil) }
                } else if flags.isEmpty, event.keyCode == 49 || event.keyCode == 36 { _ = accessibilityPerformPress() }
                else { super.keyDown(with: event) }
                return
            }
            if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
            if let captured = recordedShortcut(event, preserving: value) { onChange?(captured); window?.makeFirstResponder(nil) }
        }
        override func draw(_ dirtyRect: NSRect) {
            let focused = window?.firstResponder === self && NativeFocusAppearance.isVisible(in: window)
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            NSColor.textBackgroundColor.setFill(); shape.fill()
            (focused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke(); shape.lineWidth = focused ? 2 : 1; shape.stroke()
            let text = recording ? shortcutText("Press a key") : (value.key.isEmpty ? shortcutText("Unassigned") : ShortcutBinding(key: value.key, modifiers: 0).displayString)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(in: NSRect(x: 4, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - 28), height: size.height), withAttributes: attributes)
        }
    }
}

struct ShortcutModifiers: NSViewRepresentable {
    @Binding var modifiers: Int
    private static let segments = [(1, "⌘", "Command"), (4, "⌥", "Option"), (8, "⌃", "Control"), (2, "⇧", "Shift")]
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let view = NSSegmentedControl(labels: Self.segments.map { $0.1 }, trackingMode: .selectAny, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        view.controlSize = .small
        for (index, segment) in Self.segments.enumerated() { view.setToolTip(shortcutText(segment.2), forSegment: index) }
        view.setAccessibilityLabel(shortcutText("Modifiers"))
        return view
    }
    func updateNSView(_ view: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        for (index, segment) in Self.segments.enumerated() { view.setSelected(modifiers & segment.0 != 0, forSegment: index) }
    }
    final class Coordinator: NSObject {
        var parent: ShortcutModifiers
        init(_ parent: ShortcutModifiers) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) { parent.modifiers = ShortcutModifiers.segments.enumerated().reduce(0) { $0 | (sender.isSelected(forSegment: $1.offset) ? $1.element.0 : 0) } }
    }
}
