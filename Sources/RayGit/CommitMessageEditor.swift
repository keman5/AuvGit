import AppKit
import SwiftUI

/// The placeholder uses the editor's own font, paragraph style and text-container
/// metrics, so its first baseline is exactly where the first typed line appears.
struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CommitMessageScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let editor = CommitPlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false; editor.isAutomaticTextReplacementEnabled = false
        editor.minSize = NSSize(width: 0, height: 80)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.textContainer?.lineFragmentPadding = 0
        editor.font = .systemFont(ofSize: 13); editor.textColor = .textColor
        editor.drawsBackground = false; editor.allowsUndo = true
        editor.defaultParagraphStyle = NSParagraphStyle.default
        editor.delegate = context.coordinator
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? CommitPlaceholderTextView else { return }
        editor.placeholder = placeholder
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        editor.needsDisplay = true
        if focused, editor.window?.firstResponder !== editor {
            DispatchQueue.main.async { [weak editor] in guard let editor, context.coordinator.parent.focused else { return }; editor.window?.makeFirstResponder(editor) }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CommitMessageEditor
        init(_ parent: CommitMessageEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            if parent.text != editor.string { parent.text = editor.string }
            editor.needsDisplay = true
        }
        func textDidBeginEditing(_ notification: Notification) { if !parent.focused { parent.focused = true } }
        func textDidEndEditing(_ notification: Notification) { if parent.focused { parent.focused = false } }
    }
}

private final class CommitMessageScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let editor = documentView as? NSTextView else { return }
        editor.minSize = NSSize(width: 0, height: max(80, contentSize.height))
        var size = editor.frame.size
        size.width = contentSize.width
        size.height = max(size.height, editor.minSize.height)
        if editor.frame.size != size { editor.setFrameSize(size) }
    }
}

final class CommitPlaceholderTextView: NSTextView {
    var placeholder = ""
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let textContainer else { return }
        let storage = NSTextStorage(string: placeholder, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor, .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: textContainer.containerSize)
        container.lineFragmentPadding = textContainer.lineFragmentPadding
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.drawGlyphs(forGlyphRange: layout.glyphRange(for: container), at: textContainerOrigin)
    }
}
