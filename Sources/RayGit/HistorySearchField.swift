import AppKit
import SwiftUI

/// A single native cell renders both the prompt and editing text. SwiftUI's
/// prompt overlay can change its baseline when its field editor gains focus.
struct HistorySearchField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var onSubmit: (() -> Void)? = nil
    var rounded = false
    var initialFocus = false
    var focusRequest: UUID? = nil

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var didFocus = false
        var focusRequest: UUID?
        var parent: HistorySearchField
        init(_ parent: HistorySearchField) { self.parent = parent }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let submit = parent.onSubmit else { return false }
            submit(); return true
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.cell = StableSingleLineCell(textCell: "")
        field.isEditable = true; field.isSelectable = true
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        if field.stringValue != text { field.stringValue = text }
        field.isBezeled = rounded
        field.bezelStyle = .roundedBezel
        if (initialFocus && !context.coordinator.didFocus) || (focusRequest != nil && focusRequest != context.coordinator.focusRequest) {
            context.coordinator.focusRequest = focusRequest
            context.coordinator.didFocus = true
            DispatchQueue.main.async { [weak field] in field?.window?.makeFirstResponder(field) }
        }
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: field.font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor
        ])
        field.setAccessibilityLabel(accessibilityLabel)
    }
}

/// Native prompt and editor share a baseline, including when empty and focused.
struct StableTextField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)?
    var rounded: Bool
    var initialFocus: Bool
    init(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil, rounded: Bool = true, initialFocus: Bool = false) {
        self.placeholder = placeholder; _text = text; self.onSubmit = onSubmit
        self.rounded = rounded; self.initialFocus = initialFocus
    }
    var body: some View {
        HistorySearchField(text: $text, placeholder: placeholder, accessibilityLabel: placeholder, onSubmit: onSubmit, rounded: rounded, initialFocus: initialFocus)
            .frame(minHeight: rounded ? 24 : 20)
    }
}

/// Drawing, placeholder and field editor use the same vertically centered rect.
final class StableSingleLineCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var result = super.drawingRect(forBounds: rect)
        let height = min(result.height, ceil((font ?? NSFont.systemFont(ofSize: 13)).ascender - (font ?? NSFont.systemFont(ofSize: 13)).descender + 2))
        result.origin.y += floor((result.height - height) / 2)
        result.size.height = height
        return result
    }
    // AppKit applies the bezel/editor inset itself. Passing drawingRect here
    // applies that inset twice and clips focused glyphs.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: rect, in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}
