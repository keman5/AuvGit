import XCTest
import AppKit
import SwiftUI
@testable import AuvGit
import GitCore

@MainActor
final class NativeCompactHistoryTableTests: XCTestCase {
    func testRetinaNodeRenderingSeparatesCurrentOtherLocalRemoteAndMerge() throws {
        func commit(_ hash: String, parents: [String] = [], refs: [String] = []) -> GitCommit {
            GitCommit(hash: hash, parents: parents, author: "Test", date: .distantPast,
                subject: hash, body: "", refs: refs)
        }
        let commits = [
            commit("incoming-current", parents: ["merge"], refs: ["origin/main"]),
            commit("incoming-other", parents: ["base"], refs: ["origin/review"]),
            commit("merge", parents: ["local", "side"], refs: ["HEAD -> main"]),
            commit("local", parents: ["base"]),
            commit("side", parents: ["base"], refs: ["feature/login"]),
            commit("base", refs: ["tag: v1.0"])
        ]
        let graph = CommitGraph(commits: commits)
        let styles = HistoryGraphStylePlan(commits: commits, remoteBranchNames: ["origin/main", "origin/review"],
            localUnpushedHashes: ["merge", "local", "side"])
        let view = NativeCompactHistoryTable(commits: commits, graph: graph, styles: styles,
            selection: .constant(nil), navigationGeneration: nil, graphWidth: 48, nameWidth: 70, dateWidth: 65,
            showAvatars: false, showNames: false, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1300, pixelsHigh: 264,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            context.cgContext.scaleBy(x: 2, y: -2)
            context.cgContext.translateBy(x: 0, y: -132)
            let effectiveAppearance = try XCTUnwrap(NSAppearance(named: appearance))
            effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.textBackgroundColor.setFill()
                NSRect(x: 0, y: 0, width: 650, height: 132).fill()
                for index in commits.indices {
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 0, y: CGFloat(index) * 22)
                    let cell = CompactHistoryCell(frame: NSRect(x: 0, y: 0, width: 650, height: 22))
                    cell.configure(parent: view, index: index)
                    cell.draw(cell.bounds)
                    context.cgContext.restoreGState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            for index in 0..<5 {
                let row = graph.rows[index]
                let x = Int((HistoryColumnLayout.leadingInset + HistoryColumnLayout.laneSpacing / 2 + CGFloat(row.nodeLane) * HistoryColumnLayout.laneSpacing) * 2)
                let y = index * 44 + 22
                let center = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: y)?.usingColorSpace(.deviceRGB))
                if index < 2 {
                    XCTAssertEqual(center.redComponent, background.redComponent, accuracy: 0.02, "Remote-only nodes must remain hollow")
                } else {
                    let contrast = max(abs(center.redComponent - background.redComponent),
                        abs(center.greenComponent - background.greenComponent), abs(center.blueComponent - background.blueComponent))
                    XCTAssertGreaterThan(contrast, 0.2, "Local nodes and merge inner dots must stay visible")
                }
                if index == 2 {
                    let gap = try XCTUnwrap(bitmap.colorAt(x: x + 4, y: y)?.usingColorSpace(.deviceRGB))
                    XCTAssertEqual(gap.redComponent, background.redComponent, accuracy: 0.1, "The merge dot must be separated from its ring")
                }
            }
            if let preview = ProcessInfo.processInfo.environment["AUVGIT_GRAPH_PREVIEW"] {
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: preview + (appearance == .aqua ? "-light.png" : "-dark.png")))
            }
        }
    }

    func testRetinaGraphDrawsRoundedReferenceDashesAndBecomesSolidAfterPush() throws {
        let commits = ["head", "base", "root"].enumerated().map { index, hash in
            GitCommit(hash: hash, parents: index < 2 ? [index == 0 ? "base" : "root"] : [],
                author: "Test", date: .distantPast, subject: hash, body: "", refs: index == 0 ? ["HEAD -> main"] : [])
        }
        var samples: [[Bool]] = []
        for unpushed: Set<String> in [["head", "base"], []] {
            let view = NativeCompactHistoryTable(commits: commits, graph: CommitGraph(commits: commits),
                styles: HistoryGraphStylePlan(commits: commits, remoteBranchNames: [], localUnpushedHashes: unpushed),
                selection: .constant(nil), navigationGeneration: nil, graphWidth: 24, nameWidth: 70, dateWidth: 65,
                showAvatars: false, showNames: false, showRemoteLabels: false, showTagLabels: false,
                isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
            let cell = CompactHistoryCell(frame: NSRect(x: 0, y: 0, width: 650, height: 22))
            cell.configure(parent: view, index: 1)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1300, pixelsHigh: 44,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: 2, y: 2)
            cell.draw(cell.bounds)
            NSGraphicsContext.restoreGraphicsState()
            // Stop before the node's background-colored outer halo.
            samples.append(try (0..<12).map { y in
                let color = try XCTUnwrap(bitmap.colorAt(x: Int((HistoryColumnLayout.leadingInset + HistoryColumnLayout.laneSpacing / 2) * 2), y: y)?.usingColorSpace(.deviceRGB))
                return abs(color.blueComponent - color.redComponent) > 0.2
            })
        }
        let dashed = samples[0], solid = samples[1]
        let strokes = dashed.indices.filter { dashed[$0] && ($0 == 0 || !dashed[$0 - 1]) }.count
        XCTAssertTrue((1...2).contains(strokes), "The short visible segment must show distinct short strokes instead of dense ticks")
        XCTAssertTrue(dashed.contains(false), "Dashes must retain visible gaps")
        XCTAssertTrue(solid.allSatisfy { $0 }, "Pushing must render an uninterrupted solid line")
    }

    func testDoubleClickOpensLogForClickedCommitInsteadOfPreviousSelection() {
        final class ClickedHistoryTable: NSTableView {
            override var clickedRow: Int { 1 }
        }
        let commits = ["first", "second"].map {
            GitCommit(hash: $0, parents: [], author: "Test", date: .distantPast, subject: $0, body: "", refs: [])
        }
        var performed: (HistoryAction, String)?
        let view = NativeCompactHistoryTable(commits: commits, graph: CommitGraph(commits: commits),
            styles: HistoryGraphStylePlan(commits: commits, remoteBranchNames: []),
            selection: .constant("first"), navigationGeneration: nil, graphWidth: 24, nameWidth: 70, dateWidth: 65,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {},
            onAction: { performed = ($0, $1.hash) })
        let coordinator = view.makeCoordinator()
        let table = ClickedHistoryTable()
        coordinator.table = table
        coordinator.showCommit()
        XCTAssertEqual(performed?.0, .viewLog)
        XCTAssertEqual(performed?.1, "second")
    }

    private func pane(_ hash: String, selection: Binding<String?> = .constant(nil), action: @escaping (HistoryAction, GitCommit) -> Void = { _, _ in }) -> NativeCompactHistoryTable {
        let commits = [GitCommit(hash: hash, parents: [], author: "Test", date: .distantPast, subject: "Commit", body: "", refs: [])]
        return NativeCompactHistoryTable(commits: commits, graph: CommitGraph(commits: commits),
            styles: HistoryGraphStylePlan(commits: commits, remoteBranchNames: []),
            selection: selection, navigationGeneration: nil, graphWidth: 24, nameWidth: 70, dateWidth: 65,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: action)
    }
    func testExpandedHistoryUsesNativeSelectedTextColorDuringTracking() async throws {
        _ = NSApplication.shared
        let commit = GitCommit(hash: "123456789abcdef", parents: [], author: "Test", date: .distantPast,
            subject: "WWWWWWWWWWWWWWWWWWWW", body: "", refs: [])
        let second = GitCommit(hash: "second", parents: [], author: "Test", date: .distantPast,
            subject: commit.subject, body: "", refs: [])
        let host = NSHostingView(rootView: HistoryPane(commits: [commit, second], selection: .constant(commit.hash),
            search: .constant(""), isLoading: false, hasMore: false, onLoadMore: {},
            showsDetails: false, authorFilter: .constant("")).frame(width: 900, height: 200))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let native = try XCTUnwrap(table(in: host))
        let previous = try XCTUnwrap(native.rowView(atRow: 0, makeIfNecessary: true))
        let row = try XCTUnwrap(native.rowView(atRow: 1, makeIfNecessary: true))
        native.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertFalse(previous.isSelected)
        XCTAssertTrue(row.isSelected)
        func graph(in view: NSView) -> CommitGraphView? {
            if let graph = view as? CommitGraphView { return graph }
            for child in view.subviews { if let found = graph(in: child) { return found } }
            return nil
        }
        XCTAssertFalse(try XCTUnwrap(graph(in: previous)).nativeSelected)
        XCTAssertTrue(try XCTUnwrap(graph(in: row)).nativeSelected)
        row.isEmphasized = true
        previous.needsDisplay = true
        let oldBitmap = try XCTUnwrap(previous.bitmapImageRepForCachingDisplay(in: previous.bounds))
        previous.cacheDisplay(in: previous.bounds, to: oldBitmap)
        let oldScale = CGFloat(oldBitmap.pixelsWide) / previous.bounds.width
        let oldBackground = try XCTUnwrap(oldBitmap.colorAt(x: Int(80 * oldScale), y: Int(2 * oldScale))?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(abs(oldBackground.blueComponent - oldBackground.redComponent), 0.05,
            "The old row must stop showing blue even when the SwiftUI binding still points to it")
        row.needsDisplay = true
        let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / row.bounds.width
        let background = try XCTUnwrap(bitmap.colorAt(x: Int(80 * scale), y: Int(2 * scale))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(background.blueComponent - background.redComponent, 0.1, "Verify a selected background, not white canvas")
        let whiteText = (Int(80 * scale)..<Int(230 * scale)).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9
            }
        }
        XCTAssertTrue(whiteText, "Native selection must color the message before SwiftUI's binding changes")
    }

    func testNativeSelectionPaintsWhiteTextBeforeSwiftUISelectionUpdates() throws {
        let cell = CompactHistoryCell(frame: NSRect(x: 0, y: 0, width: 650, height: 24))
        cell.configure(parent: pane("123456789abcdef"), index: 0)
        cell.appearance = NSAppearance(named: .aqua)
        let row = CompactHistoryRowView(frame: cell.frame)
        row.addSubview(cell)
        let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = row
        defer { window.close() }
        cell.needsDisplay = false
        row.isSelected = true
        XCTAssertTrue(cell.needsDisplay)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 650, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(cell.bounds)
        cell.draw(cell.bounds)
        let glyphs = (420..<485).flatMap { x in (0..<24).compactMap { y in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) } }
            .filter { $0.alphaComponent > 0.95 }
        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertTrue(glyphs.allSatisfy { $0.redComponent > 0.9 && $0.greenComponent > 0.9 && $0.blueComponent > 0.9 })
        cell.needsDisplay = false
        row.needsDisplay = false
        row.isSelected = false
        XCTAssertTrue(row.needsDisplay)
        XCTAssertTrue(cell.needsDisplay)
    }

    func testCellFirstBitmapDrawIncludesSystemAndMonospacedText() throws {
        // Run this test alone to cover cold font resolution, without an AppKit warmup.
        let commit = GitCommit(hash: "123456789abcdef", parents: [], author: "Author", date: .distantPast,
            subject: "A commit with text", body: "", refs: ["HEAD -> main"])
        let view = NativeCompactHistoryTable(commits: [commit], graph: CommitGraph(commits: [commit]),
            styles: HistoryGraphStylePlan(commits: [commit], remoteBranchNames: []),
            selection: .constant(nil), navigationGeneration: nil, graphWidth: 18, nameWidth: 50, dateWidth: 80,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: false, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
        let cell = CompactHistoryCell(frame: NSRect(x: 0, y: 0, width: 650, height: 24))
        cell.configure(parent: view, index: 0)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 650, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(cell.bounds)
        cell.draw(cell.bounds)
        XCTAssertEqual(cell.displayedCommitHash, commit.hash)
        // The hash is the last column; alpha there proves the monospace glyphs rendered.
        let hasHashGlyph = (420..<485).contains { x in
            (0..<24).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
        }
        XCTAssertTrue(hasHashGlyph)
    }

    func testCoordinatorUsesCurrentRepositoryForSelectionAndContextActions() {
        var selected: String?
        var performed: String?
        let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
        let coordinator = pane("first", selection: binding).makeCoordinator()
        coordinator.parent = pane("second", selection: binding, action: { _, commit in performed = commit.hash })
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertEqual(selected, "second")
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        let copy = menu.items.first { ($0.representedObject as? (HistoryAction, GitCommit, UUID?))?.0 == .copyHash }
        XCTAssertNotNil(copy)
        if let copy { coordinator.performAction(copy) }
        XCTAssertEqual(performed, "second")
        performed = nil
        coordinator.parent = pane("third", selection: binding, action: { _, commit in performed = commit.hash })
        if let copy { coordinator.performAction(copy) }
        XCTAssertNil(performed, "A menu retained across repository changes cannot target the new repository")
    }
    func testBusyMenuDisablesMutationsAndKeepsCopyAvailable() {
        var view = pane("first")
        // Supply the busy state via the memberwise initializer's existing immutable input.
        view = NativeCompactHistoryTable(commits: view.commits, graph: view.graph, styles: view.styles,
            selection: .constant(nil), navigationGeneration: nil, graphWidth: 24, nameWidth: 70, dateWidth: 65,
            showAvatars: false, showNames: true, showRemoteLabels: true, showTagLabels: true,
            isBusy: true, hasMore: false, isLoading: false, onLoadMore: {}, onAction: { _, _ in })
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        coordinator.table = table
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = NSMenu()
        coordinator.menuNeedsUpdate(menu)
        for item in menu.items {
            guard let (action, _, _) = item.representedObject as? (HistoryAction, GitCommit, UUID?) else { continue }
            XCTAssertEqual(item.isEnabled, !action.isMutation)
        }
    }
    func testHostedCompactHistoryRetainsTableThroughEmptyRepositoryAndSelectionReload() async throws {
        _ = NSApplication.shared
        var selected: String? = "first"
        let binding = Binding<String?>(get: { selected }, set: { selected = $0 })
        func history(_ hash: String?) -> some View {
            HistoryPane(commits: hash.map { pane($0).commits } ?? [], selection: binding,
                search: .constant(""), isLoading: false, hasMore: false, onLoadMore: {},
                compact: true, showsSearch: false, authorFilter: .constant(""))
                .frame(width: 650, height: 150)
        }
        let host = NSHostingView(rootView: history("first"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 150),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try await settle()
        let original = try XCTUnwrap(table(in: host))
        XCTAssertEqual(original.selectedRow, 0)
        XCTAssertEqual((original.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CompactHistoryCell)?.displayedCommitHash, "first")

        selected = nil
        host.rootView = history(nil)
        try await settle()
        XCTAssertTrue(table(in: host) === original)
        XCTAssertEqual(original.numberOfRows, 0)

        selected = "second"
        host.rootView = history("second")
        try await settle()
        XCTAssertTrue(table(in: host) === original)
        XCTAssertEqual(selected, "second")
        XCTAssertEqual(original.selectedRow, 0)
        let cell = try XCTUnwrap(original.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CompactHistoryCell)
        XCTAssertEqual(cell.displayedCommitHash, "second")
        XCTAssertTrue(cell.accessibilityLabel()?.contains("second") == true)

        // Reload populated history too: NSTableView clears its selection during reloadData.
        selected = "third"
        host.rootView = history("third")
        try await settle()
        XCTAssertEqual(selected, "third")
        XCTAssertEqual(original.selectedRow, 0)
        XCTAssertEqual((original.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CompactHistoryCell)?.displayedCommitHash, "third")
    }

}
