import AppKit

/// Real controls in a dedicated display rail; no glyphs enter the document.
final class ComparisonActionRail: NSView {
    struct Entry {
        let text: NSTextView
        let range: NSRange
        var sourceText: NSTextView? = nil
        var sourceRange: NSRange? = nil
        var insertionLine: Int? = nil
        var sourceInsertionLine: Int? = nil
        var tint: NSColor? = nil
        let title: String
        var deletesContent = false
        let action: () -> Void
    }
    weak var scroll: NSScrollView?
    weak var oppositeRail: ComparisonActionRail?
    var pointsRight = true
    var color: NSColor = .systemBlue
    private var entries: [Entry] = []
    private var buttons: [Int: NSButton] = [:]
    private var geometry: [(NSRect?, NSRect?)] = []
    private var geometryIndex: [(index: Int, lower: CGFloat, upper: CGFloat)] = []
    private var geometryPrefixUpper: [CGFloat] = []
    private var geometryKeys: [GeometryKey] = []
    private var storageObservers: [NSObjectProtocol] = []
    private var geometryInvalid = true
    private struct GeometryKey: Equatable {
        let identity: ObjectIdentifier
        let size: NSSize
        let inset: NSSize
        let containerSize: NSSize
        let laidCharacters: Int
        let font: NSFont?
    }
    private var geometryTexts: [NSTextView] = []
    private var connectors: [(NSBezierPath, NSColor)] = []
    override var isFlipped: Bool { true }
    deinit { storageObservers.forEach(NotificationCenter.default.removeObserver) }
    /// Call when custom paragraph/layout metrics change without editing storage.
    func invalidateDocumentGeometry() { geometryInvalid = true }
    func setEntries(_ value: [Entry]) {
        buttons.values.forEach { $0.removeFromSuperview() }
        buttons.removeAll(keepingCapacity: true)
        storageObservers.forEach(NotificationCenter.default.removeObserver)
        storageObservers.removeAll()
        entries = value
        var identities = Set<ObjectIdentifier>()
        geometryTexts = value.flatMap { [$0.text, $0.sourceText].compactMap { $0 } }.filter {
            identities.insert(ObjectIdentifier($0)).inserted
        }
        for text in geometryTexts {
            if let storage = text.textStorage {
                storageObservers.append(NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { [weak self] _ in
                    self?.geometryInvalid = true
                })
            }
        }
        geometryInvalid = true
        refresh()
    }
    private func makeButton(for index: Int) -> NSButton {
        let entry = entries[index]
        let button = NSButton(title: "", target: self, action: #selector(accept(_:)))
        let font = entry.sourceText?.font ?? entry.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        button.image = NSImage(systemSymbolName: entry.deletesContent ? "xmark" : pointsRight ? "chevron.right.2" : "chevron.left.2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: max(8, font.pointSize - 3), weight: .regular))
        button.tag = index
        button.isBordered = false
        button.contentTintColor = DiffVisualStyle.actionColor
        button.toolTip = entry.title
        button.setAccessibilityLabel(entry.title)
        return button
    }
    @objc private func accept(_ button: NSButton) {
        guard entries.indices.contains(button.tag) else { return }
        entries[button.tag].action()
    }
    /// Read existing TextKit geometry; drawing must not lay out an offscreen document.
    static func documentRect(_ range: NSRange, in text: NSTextView, insertionLine: Int? = nil) -> NSRect? {
        guard let layout = text.layoutManager else { return nil }
        let length = (text.string as NSString).length
        let location = min(range.location, length)
        // UTF-16 EOF alone cannot distinguish insertion before or after the final empty line.
        if range.length == 0, location == length, let insertionLine, let text = text as? ComparisonTextView {
            guard location == 0 || location - 1 < layout.firstUnlaidCharacterIndex() else { return nil }
            return NSRect(x: 0, y: text.missingChangeY(at: insertionLine), width: 1, height: 0)
        }
        let inset = text.textContainerInset.height
        if range.length == 0 || location == length {
            guard location > 0 else {
                let top = text is ComparisonTextView ? ComparisonEditorMetrics.textInset.height : inset
                return NSRect(x: 0, y: top, width: 1, height: 0)
            }
            guard location - 1 < layout.firstUnlaidCharacterIndex() else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: location - 1)
            let bottom = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY
            return NSRect(x: 0, y: bottom + inset, width: 1, height: 0)
        }
        let lastCharacter = min(max(location, NSMaxRange(range) - 1), length - 1)
        guard lastCharacter < layout.firstUnlaidCharacterIndex() else { return nil }
        let first = layout.glyphIndexForCharacter(at: location)
        let top = layout.lineFragmentUsedRect(forGlyphAt: first, effectiveRange: nil).minY + inset
        let last = layout.glyphIndexForCharacter(at: lastCharacter)
        let bottom = layout.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY + inset
        return NSRect(x: 0, y: top, width: 1, height: bottom - top)
    }
    static func connectorPath(left: NSRect, right: NSRect, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let edge = min(6, width / 8)
        let middle = width / 2
        path.move(to: NSPoint(x: 0, y: left.minY))
        path.line(to: NSPoint(x: edge, y: left.minY))
        path.curve(to: NSPoint(x: width - edge, y: right.minY), controlPoint1: NSPoint(x: middle, y: left.minY), controlPoint2: NSPoint(x: middle, y: right.minY))
        path.line(to: NSPoint(x: width, y: right.minY))
        path.line(to: NSPoint(x: width, y: right.maxY))
        path.line(to: NSPoint(x: width - edge, y: right.maxY))
        path.curve(to: NSPoint(x: edge, y: left.maxY), controlPoint1: NSPoint(x: middle, y: right.maxY), controlPoint2: NSPoint(x: middle, y: left.maxY))
        path.line(to: NSPoint(x: 0, y: left.maxY))
        path.close()
        return path
    }
    func refresh() {
        let keys = geometryTexts.map {
            GeometryKey(identity: ObjectIdentifier($0), size: $0.frame.size, inset: $0.textContainerInset,
                        containerSize: $0.textContainer?.containerSize ?? .zero,
                        laidCharacters: $0.layoutManager?.firstUnlaidCharacterIndex() ?? 0, font: $0.font)
        }
        if geometryInvalid || keys != geometryKeys {
            geometry = entries.map { entry in
                (Self.documentRect(entry.range, in: entry.text, insertionLine: entry.insertionLine),
                 entry.sourceText.flatMap { text in entry.sourceRange.flatMap { Self.documentRect($0, in: text, insertionLine: entry.sourceInsertionLine) } })
            }
            geometryIndex = geometry.enumerated().compactMap { index, pair in
                guard let target = pair.0 else { return nil }
                let source = pair.1 ?? target
                return (index, min(target.minY, source.minY), max(target.maxY, source.maxY))
            }.sorted { $0.lower < $1.lower }
            var maximum = -CGFloat.infinity
            geometryPrefixUpper = geometryIndex.map { maximum = max(maximum, $0.upper); return maximum }
            geometryKeys = keys
            geometryInvalid = false
        }
        connectors.removeAll(keepingCapacity: true)
        var visibleButtons = Set<Int>()
        let bridge = oppositeRail.flatMap { $0.bounds.width > 0 ? bounds.union(convert($0.bounds, from: $0)) : nil } ?? bounds
        // Translation changes during scrolling, while document intervals stay fixed.
        // Use a conservative interval across both panes so crossing curves survive.
        let offsets = geometryTexts.map { convert(NSPoint.zero, from: $0).y }
        let lower = bounds.minY - (offsets.max() ?? 0)
        let upper = bounds.maxY - (offsets.min() ?? 0)
        var start = 0, end = geometryIndex.count
        while start < end {
            let middle = (start + end) / 2
            if geometryPrefixUpper[middle] < lower { start = middle + 1 } else { end = middle }
        }
        for item in geometryIndex.dropFirst(start) {
            if item.lower > upper { break }
            guard item.upper >= lower else { continue }
            let index = item.index, entry = entries[index]
            guard let document = geometry[index].0 else { continue }
            let rect = convert(document, from: entry.text)
            var source = rect
            if let sourceText = entry.sourceText, entry.sourceRange != nil {
                guard let document = geometry[index].1 else { continue }
                source = convert(document, from: sourceText)
            }
            // A bridge can cross the viewport even when both endpoints are outside.
            let bridgeTop = min(rect.minY, source.minY), bridgeBottom = max(rect.maxY, source.maxY)
            guard bridgeBottom >= bounds.minY, bridgeTop <= bounds.maxY else { continue }
            let tint = entry.tint ?? (entry.deletesContent ? NSColor.systemRed : color)
            // Both editable panes clip the same bridge instead of drawing mirrored curves.
            let path = Self.connectorPath(left: pointsRight ? source : rect, right: pointsRight ? rect : source, width: bridge.width)
            path.transform(using: AffineTransform(translationByX: bridge.minX, byY: 0))
            connectors.append((path, tint))
            var host = self
            if !entry.deletesContent, let oppositeRail, oppositeRail.bounds.width > 0,
               entry.range.length > 0 || oppositeRail.bounds.width >= ComparisonEditorMetrics.actionRailWidth { host = oppositeRail }
            let button = buttons[index] ?? makeButton(for: index)
            buttons[index] = button
            visibleButtons.insert(index)
            if button.superview !== host { host.addSubview(button) }
            let anchor = host.convert(entry.deletesContent ? rect : source, from: self)
            let top = anchor.minY
            let visible = NSRect(x: 0, y: top, width: host.bounds.width, height: max(1, anchor.height)).intersection(host.bounds)
            let buttonWidth = ComparisonEditorMetrics.actionButtonWidth
            let font = entry.sourceText?.font ?? entry.text.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
            let buttonHeight = ceil((entry.sourceText ?? entry.text).layoutManager?.defaultLineHeight(for: font) ?? font.boundingRectForFont.height)
            let halfHeight = buttonHeight / 2
            button.isHidden = visible.isEmpty || host.bounds.width < buttonWidth
            // Keep a tall block's control usable while only part of it is in view.
            let center = min(max(anchor.midY, halfHeight), max(halfHeight, host.bounds.height - halfHeight))
            let onLeft = entry.deletesContent ? !pointsRight : pointsRight
            // Two editable copies also offer copying an insertion; keep its arrow beside, not over, ×.
            let inset = !entry.deletesContent && entry.range.length == 0 && host !== self ? buttonWidth : 0
            let x = onLeft ? 2 + inset : max(0, host.bounds.width - buttonWidth - 2 - inset)
            button.frame = NSRect(x: x, y: center - halfHeight, width: buttonWidth, height: buttonHeight)
        }
        for index in Array(buttons.keys) where !visibleButtons.contains(index) {
            buttons.removeValue(forKey: index)?.removeFromSuperview()
        }
        needsDisplay = true
    }
    override func layout() { super.layout(); refresh() }
    override func draw(_ dirtyRect: NSRect) {
        DiffVisualStyle.actionBackgroundColor.setFill()
        dirtyRect.fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        for (path, tint) in connectors {
            guard path.bounds.intersects(dirtyRect) else { continue }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            DiffVisualStyle.lineBackground(tint, dark: dark).setFill()
            path.fill()
            tint.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}
