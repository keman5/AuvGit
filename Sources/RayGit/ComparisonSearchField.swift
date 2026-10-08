import AppKit
import SwiftUI

/// A native field keeps empty replacement fields clickable and provides explicit
/// Return / Shift-Return / Escape handling without stealing the editor's focus.
struct ComparisonSearchField: NSViewRepresentable {
    @Environment(\.nativeFocusScope) private var scope
    @Environment(\.isEnabled) private var enabled
    @Binding var text: String
    let placeholder: String
    var initialFocus = false
    let onNavigate: (Bool) -> Void
    let onEscape: () -> Void
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ComparisonSearchField
        let fallbackScope = NativeFocusCoordinator()
        init(_ parent: ComparisonSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                parent.onNavigate(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)); return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = ClickableSearchTextField()
        field.cell = StableSingleLineCell(textCell: "")
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12)
        field.delegate = context.coordinator
        field.setAccessibilityLabel(placeholder)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        let focusScope = scope ?? context.coordinator.fallbackScope
        if scope == nil { focusScope.attach(to: field.window) }
        focusScope.register(field, initial: initialFocus)
        if scope == nil && field.window == nil {
            DispatchQueue.main.async { [weak field, weak focusScope] in focusScope?.attach(to: field?.window) }
        }
    }
}
private final class ClickableSearchTextField: NSTextField {
    override func accessibilityPerformPress() -> Bool {
        guard window?.makeFirstResponder(self) == true else { return false }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
