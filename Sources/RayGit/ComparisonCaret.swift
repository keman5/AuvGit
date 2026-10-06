import AppKit

/// Read-only panes keep a visible insertion point using native text geometry
/// without enabling editing commands.
enum ComparisonCaret {
    static func isVisible(isSelectable: Bool, isFocused: Bool, isKeyWindow: Bool, selection: NSRange) -> Bool {
        isSelectable && isFocused && isKeyWindow && selection.location != NSNotFound && selection.length == 0
    }

    static func shouldDraw(in view: NSTextView) -> Bool {
        isVisible(isSelectable: view.isSelectable,
                  isFocused: view.window?.firstResponder === view,
                  isKeyWindow: view.window?.isKeyWindow == true,
                  selection: view.selectedRange())
    }

    static func rect(in view: NSTextView) -> NSRect? {
        guard let window = view.window, let layout = view.layoutManager, let container = view.textContainer,
              view.selectedRange().location <= (view.string as NSString).length else { return nil }
        layout.ensureLayout(for: container)
        // NSTextInputClient supplies the actual insertion geometry, including
        // wrapped lines, tabs, composed characters and alignment paragraph spacing.
        let screenRect = view.firstRect(forCharacterRange: NSRange(location: view.selectedRange().location, length: 0), actualRange: nil)
        guard screenRect.height > 0 else { return nil }
        var caret = view.convert(window.convertFromScreen(screenRect), from: nil)
        caret.size.width = 1.5
        return caret
    }

    static func draw(in view: NSTextView, dirtyRect: NSRect) {
        guard !view.isEditable, shouldDraw(in: view), let caret = rect(in: view), caret.intersects(dirtyRect) else { return }
        // AppKit's insertion timer does not paint for a noneditable text view,
        // even when shouldDrawInsertionPoint returns true. Keep this caret
        // steadily visible; mutation remains governed by isEditable=false.
        NSColor.labelColor.setFill()
        caret.intersection(dirtyRect).fill()
    }
}
