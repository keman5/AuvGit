import SwiftUI
import AppKit
import GitCore

struct CompactComparisonProjection {
    struct Line: Identifiable {
        let number: Int
        let text: String
        let addition: Bool
        var id: Int { number }
    }
    struct Band: Identifiable {
        let id: Int
        let columns: [[Line]]
    }
    let bands: [Band]
    init(columns: [ComparisonEditorColumn], conflict: Bool) {
        let texts = columns.map(\.text)
        let baseline = conflict ? columns.firstIndex(where: { $0.id == "worktree" }) ?? 0 : 0
        guard texts.indices.contains(baseline) else { bands = []; return }
        let blocks = conflict ? ConflictDraft.blocks(in: texts[baseline]) : []
        let alignment = ComparisonAlignment(texts: texts, baseline: baseline, conflictBlocks: blocks)
        var changed = Array(repeating: Set<Int>(), count: texts.count)
        for pane in texts.indices where pane != baseline {
            let diff = TextLineDiff(source: texts[baseline], target: texts[pane])
            changed[baseline].formUnion(diff.sourceChangedLines)
            changed[pane].formUnion(diff.targetChangedLines)
        }
        let lines = texts.map { $0.components(separatedBy: "\n") }
        bands = alignment.bands.enumerated().compactMap { index, band in
            let isConflict = blocks.contains { (($0.startLine - 1)..<$0.endLine).overlaps(band[baseline]) }
            let selected = texts.indices.map { pane in
                band[pane].filter { isConflict || changed[pane].contains($0) }.map { line in
                    Line(number: columns[pane].firstLine + line, text: lines[pane][line], addition: conflict ? columns[pane].id == "theirs" : pane != baseline)
                }
            }
            return selected.allSatisfy(\.isEmpty) ? nil : Band(id: index, columns: selected)
        }
    }
}

/// A separate, read-only projection leaves the mounted native document and undo
/// manager intact. Each shared band has one height across all panes.
struct CompactComparisonView: View {
    let columns: [ComparisonEditorColumn]
    let conflict: Bool
    let wraps: Bool
    let numbers: Bool
    let onReturnToEditor: () -> Void
    var onRevealLine: ((String, Int) -> Void)? = nil
    @State private var bandFrames: [Int: CGRect] = [:]
    @State private var nativeScroll: NSScrollView?
    @StateObject private var horizontalSync = CompactHorizontalSynchronization()
    @StateObject private var projectionCache = CompactProjectionCache()
    private var projection: CompactComparisonProjection { projectionCache.value(columns: columns, conflict: conflict) }
    var body: some View {
        let projection = self.projection
        let overviewFrames = wraps ? bandFrames : unwrappedBandFrames(projection)
        let overviewHeight = max(1, overviewFrames.values.map(\.maxY).max() ?? 1)
        VStack(spacing: 0) {
            HStack {
                Text(comparisonSearchText("Compact differences are read-only.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(comparisonSearchText("Return to editor"), action: onReturnToEditor)
            }.padding(.horizontal, 12).frame(height: 30)
            HStack(spacing: 1) {
                ForEach(columns) { column in
                    Text(column.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).help(column.title)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                }
            }.frame(height: 28).auvGitChrome()
            Divider()
            if projection.bands.isEmpty { Text(comparisonSearchText("No differences")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollViewReader { proxy in
                HStack(spacing: 0) {
                ScrollView(.vertical) {
                    if !wraps {
                        unwrappedColumns(projection)
                            .background(CompactScrollProbe { nativeScroll = $0 })
                    } else {
                    VStack(spacing: 1) {
                        ForEach(projection.bands) { band in
                            HStack(alignment: .top, spacing: 1) {
                                ForEach(columns.indices, id: \.self) { pane in
                                    VStack(alignment: .leading, spacing: 0) {
                                        ForEach(band.columns[pane]) { line in
                                            HStack(alignment: .top, spacing: 4) {
                                                if numbers { Text("\(line.number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing) }
                                                Text(line.addition ? "+" : "−").foregroundStyle(line.addition ? Color.green : Color.red).frame(width: 10)
                                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                                                    .fixedSize(horizontal: !wraps, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                            }.font(.system(size: 12, design: .monospaced)).padding(.vertical, 2)
                                                .contentShape(Rectangle())
                                                .onTapGesture { onRevealLine?(columns[pane].id, line.number) }
                                                .accessibilityAction { onRevealLine?(columns[pane].id, line.number) }
                                        }
                                    }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 19, alignment: .topLeading)
                                        .clipped().background(pane == columns.firstIndex(where: { $0.id == "worktree" }) && conflict ? Color.orange.opacity(0.10) : (band.columns[pane].first?.addition == true ? Color.green : Color.red).opacity(0.08))
                                }
                            }.id(band.id).background(GeometryReader { geometry in
                                Color.clear.preference(key: CompactBandFrames.self, value: [band.id: geometry.frame(in: .named("compactDocument"))])
                            })
                        }
                    }.coordinateSpace(name: "compactDocument").onPreferenceChange(CompactBandFrames.self) { bandFrames = $0 }.background(CompactScrollProbe { nativeScroll = $0 })
                    }
                }
                ComparisonOverviewRail(markers: projection.bands.enumerated().map { index, band in
                    let first = band.columns.first?.isEmpty == true
                    let deletion = band.columns.dropFirst().contains(where: \.isEmpty)
                    let frame = overviewFrames[band.id] ?? .zero
                    return ComparisonOverviewMarker(lower: frame.minY / overviewHeight, upper: frame.maxY / overviewHeight, kind: first ? .addition : deletion ? .deletion : .modification, index: band.id)
                }, onSelect: { index in proxy.scrollTo(index, anchor: .top) }, onNavigate: { fraction in
                    guard let scroll = nativeScroll, let document = scroll.documentView else { return }
                    let y = CGFloat(fraction) * document.bounds.height - scroll.contentView.bounds.height / 2
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(max(0, y), max(0, document.bounds.height - scroll.contentView.bounds.height))))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }).frame(width: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
                }
                }
            }
        }
    }
    private func unwrappedBandFrames(_ projection: CompactComparisonProjection) -> [Int: CGRect] {
        var y: CGFloat = 0, frames: [Int: CGRect] = [:]
        for band in projection.bands {
            let height = CGFloat(max(1, band.columns.map(\.count).max() ?? 1)) * 19
            frames[band.id] = CGRect(x: 0, y: y, width: 1, height: height); y += height + 1
        }
        return frames
    }
    private func unwrappedColumns(_ projection: CompactComparisonProjection) -> some View {
        let frames = unwrappedBandFrames(projection)
        let height = frames.values.map(\.maxY).max() ?? 19
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let contentWidth = (projection.bands.flatMap { $0.columns.flatMap { $0 } }.map { ($0.text as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + (numbers ? 64 : 22)
        return GeometryReader { geometry in
            HStack(alignment: .top, spacing: 1) {
                ForEach(columns.indices, id: \.self) { pane in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(projection.bands) { band in
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(band.columns[pane]) { line in
                                        HStack(spacing: 4) {
                                            if numbers { Text("\(line.number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing) }
                                            Text(line.addition ? "+" : "−").foregroundStyle(line.addition ? Color.green : Color.red).frame(width: 10)
                                            Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).fixedSize()
                                        }.font(.system(size: 12, design: .monospaced)).frame(height: 19)
                                            .contentShape(Rectangle()).onTapGesture { onRevealLine?(columns[pane].id, line.number) }
                                            .accessibilityAction { onRevealLine?(columns[pane].id, line.number) }
                                    }
                                }.frame(width: max(contentWidth, (geometry.size.width - CGFloat(columns.count - 1)) / CGFloat(columns.count)), height: frames[band.id]?.height ?? 19, alignment: .topLeading)
                                    .background(pane == columns.firstIndex(where: { $0.id == "worktree" }) && conflict ? Color.orange.opacity(0.10) : (band.columns[pane].first?.addition == true ? Color.green : Color.red).opacity(0.08))
                                    .id(band.id)
                            }
                        }.background(CompactScrollProbe { horizontalSync.register($0, pane: pane) })
                    }.frame(width: max(1, (geometry.size.width - CGFloat(columns.count - 1)) / CGFloat(columns.count)), height: height + 16)
                }
            }
        }.frame(height: height + 16)
    }

}

private final class CompactProjectionCache: ObservableObject {
    private var texts: [String] = []
    private var identity: [String] = []
    private var conflict = false
    private var projection: CompactComparisonProjection?
    func value(columns: [ComparisonEditorColumn], conflict: Bool) -> CompactComparisonProjection {
        let newTexts = columns.map(\.text), newIdentity = columns.map { $0.id + ":" + String($0.firstLine) }
        if projection == nil || texts != newTexts || identity != newIdentity || self.conflict != conflict {
            texts = newTexts; identity = newIdentity; self.conflict = conflict
            projection = CompactComparisonProjection(columns: columns, conflict: conflict)
        }
        return projection!
    }
}

private struct CompactScrollProbe: NSViewRepresentable {
    let onResolve: (NSScrollView) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let scroll = view.enclosingScrollView { onResolve(scroll) } }
    }
}

private struct CompactBandFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, next in next }) }
}

/// Each compact pane owns a viewport; only its code offset follows its peers.
final class CompactHorizontalSynchronization: ObservableObject {
    private final class WeakScroll { weak var value: NSScrollView?; init(_ value: NSScrollView) { self.value = value } }
    private var scrolls: [Int: WeakScroll] = [:]
    private var observers: [Int: NSObjectProtocol] = [:]
    private var syncing = false
    deinit { for token in observers.values { NotificationCenter.default.removeObserver(token) } }
    func register(_ scroll: NSScrollView, pane: Int) {
        guard scrolls[pane]?.value !== scroll else { return }
        if let token = observers.removeValue(forKey: pane) { NotificationCenter.default.removeObserver(token) }
        scrolls[pane] = WeakScroll(scroll); scroll.contentView.postsBoundsChangedNotifications = true
        observers[pane] = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
            guard let self, let scroll, !self.syncing else { return }
            self.syncing = true; defer { self.syncing = false }
            for other in self.scrolls.values.compactMap(\.value) where other !== scroll {
                let clip = other.contentView
                clip.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: clip.bounds.minY))
                other.reflectScrolledClipView(clip)
            }
        }
    }
}
