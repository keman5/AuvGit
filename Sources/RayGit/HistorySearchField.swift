import AppKit
import SwiftUI

/// A single native cell renders both the prompt and editing text. SwiftUI's
/// prompt overlay can change its baseline when its field editor gains focus.
struct HistorySearchField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.nativeFocusScope) private var scope
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    var onSubmit: (() -> Void)? = nil
    var rounded = false
    var initialFocus = false
    var focusRequest: UUID? = nil

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let fallbackScope = NativeFocusCoordinator()
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
        field.focusRingType = .default
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
        let focusScope = scope ?? context.coordinator.fallbackScope
        // Inherited scopes are bound by their presentation root. A field
        // carried into another host must never rebind its parent's scope.
        if scope == nil { focusScope.attach(to: field.window) }
        focusScope.register(field, initial: initialFocus, request: focusRequest)
        if scope == nil && field.window == nil {
            DispatchQueue.main.async { [weak field, weak focusScope] in
                focusScope?.attach(to: field?.window)
            }
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
    var focusRequest: UUID?
    init(_ placeholder: String, text: Binding<String>, onSubmit: (() -> Void)? = nil, rounded: Bool = true, initialFocus: Bool = false, focusRequest: UUID? = nil) {
        self.placeholder = placeholder; _text = text; self.onSubmit = onSubmit
        self.rounded = rounded; self.initialFocus = initialFocus
        self.focusRequest = focusRequest
    }
    var body: some View {
        HistorySearchField(text: $text, placeholder: placeholder, accessibilityLabel: placeholder, onSubmit: onSubmit, rounded: rounded, initialFocus: initialFocus, focusRequest: focusRequest)
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
