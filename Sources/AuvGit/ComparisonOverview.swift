import AppKit
import SwiftUI
import GitCore

struct ComparisonOverviewMarker: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case addition, deletion, modification }
    let lower: Double
    let upper: Double
    let kind: Kind
    let index: Int
    var color: NSColor {
        switch kind { case .addition: .systemGreen; case .deletion: .systemRed; case .modification: .systemOrange }
    }
    static func nearest(to fraction: Double, in markers: [Self]) -> Self? {
        markers.min { distance(fraction, $0) < distance(fraction, $1) }
    }
    private static func distance(_ value: Double, _ marker: Self) -> Double {
        max(marker.lower - value, value - marker.upper, 0)
    }
}

/// Reserves a rail beside the actual scrollbar, with exactly its native width.
/// Navigation is explicit, so it never depends on manual scroll synchronization.
final class ComparisonOverviewScrollView: NSScrollView {
    let overview = ComparisonOverviewView()
    private var tilingOverview = false
    var isUpdatingGeometry: Bool { tilingOverview }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .legacy
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none
        autohidesScrollers = false
        verticalScroller = ComparisonChangeScroller()
        addSubview(overview)
        overview.scroll = self
    }
    required init?(coder: NSCoder) { fatalError() }
    override func tile() {
        guard !tilingOverview else { return }
        let position = contentView.bounds.origin
        tilingOverview = true; defer { tilingOverview = false }
        super.tile()
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        var content = contentView.frame
        content.size.width = max(0, content.width - width)
        contentView.frame = content
        overview.frame = NSRect(x: content.maxX, y: content.minY, width: width, height: content.height)
        overview.needsLayout = true
        if let horizontalScroller { var frame = horizontalScroller.frame; frame.size.width = max(0, frame.width - width); horizontalScroller.frame = frame }
        // Changing the clip frame can make AppKit bottom-align a detached text
        // document. Comparison decorations and navigation use document-local y.
        if let text = documentView as? NSTextView { text.setFrameOrigin(.zero) }
        var bounds = contentView.bounds; bounds.origin = position
        contentView.scroll(to: contentView.constrainBoundsRect(bounds).origin)
        overview.needsDisplay = true
    }
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView); invalidateChangeBackgrounds()
    }
    func invalidateChangeBackgrounds() {
        overview.needsDisplay = true
        verticalScroller?.needsDisplay = true
    }
    func drawChangeBackground(in view: NSView, rect: NSRect) {
        guard let text = documentView as? ComparisonTextView, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // AppKit may supply a dirty rect extending beyond an unclipped sibling.
        context.clip(to: view.bounds)
        text.backgroundColor.setFill(); rect.intersection(view.bounds).fill()
        let documentRect = text.convert(rect.intersection(view.bounds), from: view)
        let origin = view.convert(NSPoint.zero, from: text)
        context.translateBy(x: 0, y: origin.y)
        context.scaleBy(x: 1, y: view.isFlipped == text.isFlipped ? 1 : -1)
        text.drawChangeBackgrounds(in: NSRect(x: 0, y: documentRect.minY, width: view.bounds.width, height: documentRect.height), width: view.bounds.width)
    }
}
private final class ComparisonChangeScroller: NSScroller {
    override func draw(_ dirtyRect: NSRect) {
        guard let scroll = superview as? ComparisonOverviewScrollView, scroll.documentView is ComparisonTextView else {
            super.draw(dirtyRect); return
        }
        // Keep the native thumb and hit testing, without an opaque track severing the change band.
        scroll.drawChangeBackground(in: self, rect: dirtyRect)
        if isEnabled { drawKnob() }
    }
}
final class ComparisonOverviewView: NSView {
    weak var scroll: NSScrollView?
    var markers: [ComparisonOverviewMarker] = [] { didSet { if oldValue != markers { markerImage = nil; synchronizeMarkerButtons(); needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    var onNavigate: ((Double) -> Void)?
    var usesLocalViewport = true
    private var markerImage: NSImage?
    private var markerImageSize = NSSize.zero
    private var markerImageAppearance: NSAppearance.Name?
    private var keyboardMarker = 0
    private var markerButtons: [Int: OverviewMarkerButton] = [:]
    private var accessibilityMaterialized = false
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        (scroll as? ComparisonOverviewScrollView)?.drawChangeBackground(in: self, rect: dirtyRect)
        let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if markerImage == nil || markerImageSize != bounds.size || markerImageAppearance != appearance {
            let size = bounds.size
            if size.width > 0, size.height > 0 {
                let image = NSImage(size: size)
                image.lockFocusFlipped(true)
                for marker in markers {
                    marker.color.withAlphaComponent(0.85).setFill()
                    NSRect(x: 2, y: size.height * marker.lower, width: max(1, size.width - 4),
                           height: max(3, size.height * (marker.upper - marker.lower))).intersection(NSRect(origin: .zero, size: size)).fill()
                }
                image.unlockFocus()
                markerImage = image
            }
            markerImageSize = size
            markerImageAppearance = appearance
        }
        markerImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        if usesLocalViewport, let scroll, let document = scroll.documentView, document.bounds.height > 0 {
            let visible = scroll.contentView.bounds
            NSColor.labelColor.withAlphaComponent(0.4).setStroke()
            let rect = NSRect(x: 0.5, y: bounds.height * visible.minY / document.bounds.height, width: max(0, bounds.width - 1), height: max(3, bounds.height * visible.height / document.bounds.height))
            NSBezierPath(rect: rect.intersection(bounds)).stroke()
        }
    }
    override func keyDown(with event: NSEvent) {
        guard !markers.isEmpty else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 125, 124: keyboardMarker = min(markers.count - 1, keyboardMarker + 1)
        case 126, 123: keyboardMarker = max(0, keyboardMarker - 1)
        case 36, 49: break
        default: super.keyDown(with: event); return
        }
        onSelect?(markers[min(keyboardMarker, markers.count - 1)].index)
    }
    func navigate(to fraction: Double) {
        let fraction = min(1, max(0, fraction))
        if let onNavigate { onNavigate(fraction) }
        else if let marker = ComparisonOverviewMarker.nearest(to: fraction, in: markers) { onSelect?(marker.index) }
    }
    private func navigate(with event: NSEvent) {
        navigate(to: Double(convert(event.locationInWindow, from: nil).y / max(1, bounds.height)))
    }
    override func mouseDown(with event: NSEvent) { navigate(with: event) }
    override func mouseDragged(with event: NSEvent) { navigate(with: event) }
    override func mouseUp(with event: NSEvent) { navigate(with: event) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { comparisonSearchText("Change overview") }
    override func accessibilityChildren() -> [Any]? {
        // Drawing and mouse navigation do not need thousands of native controls.
        // Keep the concrete AppKit buttons when an accessibility client asks for them.
        if !accessibilityMaterialized {
            accessibilityMaterialized = true
            synchronizeMarkerButtons()
        }
        return markers.compactMap { markerButtons[$0.index] }
    }
    override func accessibilityVisibleChildren() -> [Any]? { accessibilityChildren() }
    private func synchronizeMarkerButtons() {
        guard accessibilityMaterialized else { return }
        let current = Set(markers.map(\.index))
        for index in Array(markerButtons.keys) where !current.contains(index) {
            markerButtons.removeValue(forKey: index)?.removeFromSuperview()
        }
        for marker in markers {
            let button: OverviewMarkerButton
            if let existing = markerButtons[marker.index] { button = existing }
            else {
                button = OverviewMarkerButton(frame: .zero)
                button.title = ""; button.isBordered = false
                button.tag = marker.index; button.target = self; button.action = #selector(selectMarker(_:))
                markerButtons[marker.index] = button
                addSubview(button)
            }
            button.setAccessibilityLabel(comparisonSearchText("Change") + " \(marker.index + 1)")
            button.setAccessibilityParent(self)
        }
        layoutMarkerButtons()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }
    override func layout() { super.layout(); layoutMarkerButtons() }
    private func layoutMarkerButtons() {
        guard !markerButtons.isEmpty else { return }
        for marker in markers {
            let height = min(bounds.height, max(6, bounds.height * (marker.upper - marker.lower)))
            let y = min(max(0, bounds.height * marker.lower), max(0, bounds.height - height))
            markerButtons[marker.index]?.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        }
    }
    @objc private func selectMarker(_ sender: NSButton) { onSelect?(sender.tag) }
}
private final class OverviewMarkerButton: NSButton {
    // Keep concrete controls visible/enabled for AppKit's AX tree without adding
    // button chrome over the colored rail that its parent already paints.
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return sendAction(action, to: target)
    }
}

/// SwiftUI projections retain native accessibility controls and drag tracking.
struct ComparisonOverviewRail: NSViewRepresentable {
    let markers: [ComparisonOverviewMarker]
    let onSelect: (Int) -> Void
    var onNavigate: ((Double) -> Void)? = nil
    func makeNSView(context: Context) -> ComparisonOverviewView { ComparisonOverviewView() }
    func updateNSView(_ view: ComparisonOverviewView, context: Context) {
        view.markers = markers; view.onSelect = onSelect; view.onNavigate = onNavigate
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ComparisonOverviewView, context: Context) -> CGSize? {
        CGSize(width: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), height: proposal.height ?? 100)
    }
}

/// Aligned virtual rows map global rail positions to each original document.
/// Adjacent one-to-one bands are compressed, keeping unchanged spans inexpensive.
struct ComparisonOverviewLineMap: Sendable {
    struct Segment: Sendable { var units: Range<Int>; var lines: [Range<Int>] }
    let segments: [Segment]
    let count: Int
    init(bands: [[Range<Int>]]) {
        var result: [Segment] = [], position = 0
        for band in bands {
            let height = max(1, band.map(\.count).max() ?? 1)
            if let last = result.last,
               zip(last.lines, band).allSatisfy({ previous, next in
                   previous.isEmpty == next.isEmpty && (previous.isEmpty ? previous.lowerBound == next.lowerBound : previous.upperBound == next.lowerBound && previous.count == last.units.count && next.count == height)
               }) {
                result[result.count - 1] = Segment(units: last.units.lowerBound..<(position + height), lines: zip(last.lines, band).map { $0.lowerBound..<$1.upperBound })
            } else { result.append(Segment(units: position..<(position + height), lines: band)) }
            position += height
        }
        segments = result; count = position
    }
    func bounds(for band: [Range<Int>]) -> (Double, Double) {
        let units = segments.compactMap { segment -> Range<Int>? in
            let spans = zip(segment.lines, band).compactMap { source, changed -> Range<Int>? in
                let lower = max(source.lowerBound, changed.lowerBound), upper = min(source.upperBound, changed.upperBound)
                guard lower < upper else { return nil }
                return (segment.units.lowerBound + lower - source.lowerBound)..<min(segment.units.upperBound, segment.units.lowerBound + upper - source.lowerBound)
            }
            guard let lower = spans.map(\.lowerBound).min(), let upper = spans.map(\.upperBound).max() else { return nil }
            return lower..<upper
        }
        return (Double(units.map(\.lowerBound).min() ?? 0) / Double(max(1, count)), Double(units.map(\.upperBound).max() ?? 1) / Double(max(1, count)))
    }
    func lines(at fraction: Double) -> [Int] {
        guard count > 0 else { return [] }
        let row = min(count - 1, max(0, Int(min(1, max(0, fraction)) * Double(count))))
        var lower = 0, upper = segments.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if segments[middle].units.upperBound <= row { lower = middle + 1 } else { upper = middle }
        }
        let segment = segments[min(lower, segments.count - 1)], offset = row - segments[min(lower, segments.count - 1)].units.lowerBound
        return segment.lines.map { $0.lowerBound + min(offset, max(0, $0.count - 1)) }
    }
}

struct ComparisonToolbarIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.system(size: 11, weight: .medium))
            .frame(width: 22, height: 24).contentShape(Rectangle())
    }
}

struct ComparisonPatchChange: Equatable {
    let firstLine: Int
    let lastLine: Int
    let kind: ComparisonOverviewMarker.Kind
}
enum ComparisonPatchOverview {
    /// Hunk headers include surrounding context; navigation uses changed rows.
    static func changes(in diff: ParsedDiff) -> [ComparisonPatchChange] {
        diff.hunks.enumerated().map { index, hunk in
            let end = index + 1 < diff.hunks.count ? diff.hunks[index + 1].lineIndex : diff.lines.count
            var nextTarget = max(1, hunk.newStart), changed: [Int] = []
            var added = false, deleted = false
            for row in diff.lines[hunk.lineIndex..<end] {
                if row.kind == .deletion { deleted = true; changed.append(nextTarget) }
                if let number = row.newNumber {
                    if row.kind == .addition { added = true; changed.append(number) }
                    nextTarget = number + 1
                }
            }
            return ComparisonPatchChange(firstLine: changed.min() ?? max(1, hunk.newStart), lastLine: changed.max() ?? max(1, hunk.newStart), kind: added && !deleted ? .addition : deleted && !added ? .deletion : .modification)
        }
    }
}
