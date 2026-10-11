import AppKit

/// Real controls in a dedicated display rail; no glyphs enter the document.
final class ComparisonActionRail: NSView {
    struct Entry {
        let text: NSTextView
        let range: NSRange
        let title: String
        var deletesContent = false
        let action: () -> Void
    }
    weak var scroll: NSScrollView?
    var pointsRight = true
    var color: NSColor = .systemBlue
    private var entries: [Entry] = []
    private var buttons: [NSButton] = []
    override var isFlipped: Bool { true }
    func setEntries(_ value: [Entry]) {
        entries = value
        buttons.forEach { $0.removeFromSuperview() }
        buttons = value.enumerated().map { index, entry in
            let button = NSButton(title: entry.deletesContent ? "" : pointsRight ? "→" : "←", target: self, action: #selector(accept(_:)))
            if entry.deletesContent { button.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil) }
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            let tint = entry.deletesContent ? NSColor.systemRed : color
            button.contentTintColor = tint
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.borderWidth = 1
            button.layer?.borderColor = tint.withAlphaComponent(0.25).cgColor
            button.layer?.backgroundColor = tint.withAlphaComponent(0.09).cgColor
            button.toolTip = entry.title
            button.setAccessibilityLabel(entry.title)
            addSubview(button)
            return button
        }
        refresh()
    }
    @objc private func accept(_ button: NSButton) {
        guard entries.indices.contains(button.tag) else { return }
        entries[button.tag].action()
    }
    private func documentRect(_ entry: Entry) -> NSRect? {
        let text = entry.text
        guard let layout = text.layoutManager, let container = text.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let length = text.string.utf16.count
        let location = min(entry.range.location, length)
        guard location < length, layout.numberOfGlyphs > 0 else {
            let rect = layout.extraLineFragmentRect
            return NSRect(x: 0, y: rect.minY + text.textContainerInset.height, width: bounds.width, height: max(16, rect.height))
        }
        let first = layout.glyphIndexForCharacter(at: location)
        let last = layout.glyphIndexForCharacter(at: min(max(location, NSMaxRange(entry.range) - 1), length - 1))
        let top = layout.lineFragmentRect(forGlyphAt: first, effectiveRange: nil).minY
        let bottom = layout.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).maxY
        return NSRect(x: 0, y: top + text.textContainerInset.height, width: bounds.width, height: max(16, bottom - top))
    }
    func refresh() {
        for (entry, button) in zip(entries, buttons) {
            guard let rect = documentRect(entry) else { button.isHidden = true; continue }
            let top = rect.minY - (scroll?.contentView.bounds.minY ?? 0)
            let visible = NSRect(x: 0, y: top, width: bounds.width, height: rect.height).intersection(bounds)
            let buttonWidth = ComparisonEditorMetrics.actionButtonWidth
            let buttonHeight = ComparisonEditorMetrics.actionButtonHeight
            let halfHeight = buttonHeight / 2
            button.isHidden = visible.isEmpty || bounds.width < buttonWidth
            // Keep a tall block's control usable while only part of it is in view.
            let center = min(max(top + rect.height / 2, halfHeight), max(halfHeight, bounds.height - halfHeight))
            button.frame = NSRect(x: max(0, (bounds.width - buttonWidth) / 2), y: center - halfHeight, width: buttonWidth, height: buttonHeight)
        }
        needsDisplay = true
    }
    override func layout() { super.layout(); refresh() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        for entry in entries {
            guard let rect = documentRect(entry) else { continue }
            let edge = NSRect(x: pointsRight ? bounds.width - 2 : 0, y: rect.minY - (scroll?.contentView.bounds.minY ?? 0), width: 2, height: rect.height).intersection(bounds)
            (entry.deletesContent ? NSColor.systemRed : color).withAlphaComponent(0.85).setFill()
            edge.fill()
        }
    }
}
