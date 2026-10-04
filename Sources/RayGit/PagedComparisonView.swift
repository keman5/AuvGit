import SwiftUI
import GitCore
import RayGitLocalization

private func pagedText(_ key: String) -> String { L10n.text(key, table: "AdvancedDiff") }
struct PagedComparisonView: View {
    let snapshot: FileComparisonSnapshot
    var layout = "automatic"
    var baseline = "index"
    var showBase = false
    var initialSearchOptions = ComparisonSearchOptions()
    var initialReplacement = ""
    var compact = false
    var searchRequested = false
    var onSearchClosed: (() -> Void)? = nil
    @State private var page = 0
    @State private var pageAnchors: [String: PagedTextAnchor] = [:]
    @State private var anchorHistory: [[String: PagedTextAnchor]] = []
    @State private var columns: [ComparisonEditorColumn] = []
    @State private var firstColumns: [String: Int] = [:]
    @State private var hasNext = false
    @State private var pageTask: Task<Void, Never>?
    @State private var pageToken = UUID()
    @State private var searchOptions = ComparisonSearchOptions()
    @State private var replacement = ""
    @State private var showSearch = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchToken = UUID()
    @State private var isSearching = false
    @State private var hits: [(String, LargeTextSearchHit)] = []
    @State private var matchIndex = -1
    @State private var searchError: String?
    @State private var resultsLimited = false
    @State private var compactDisplay = false
    @State private var patch = ""
    @State private var patchTask: Task<Void, Never>?
    @State private var patchToken = UUID()
    @State private var patchBusy = false
    @State private var compactSource = ""
    @StateObject private var commands = ComparisonEditingCommands()
    private func largeText(_ key: String) -> String { L10n.text(key, table: "LargeComparison") }
    private var revisions: [(String, String, FileRevisionContent)] {
        let three = layout == "three" || (layout == "automatic" && snapshot.presentation.layout == .three)
        if snapshot.isConflict {
            let left = showBase ? ("base", pagedText("base"), snapshot.base) : ("ours", compareText("Ours (HEAD)"), snapshot.ours)
            let result = ("worktree", pagedText("worktree"), Optional(snapshot.worktree))
            let versions = three ? [left, result, ("theirs", pagedText("theirs"), snapshot.theirs)] : [left, result]
            return versions.compactMap { id, title, content in content.map { (id, title, $0) } }
        }
        let working = ("worktree", pagedText("worktree"), snapshot.worktree)
        if three { return [("head", "HEAD", snapshot.head), ("index", pagedText("index"), snapshot.index), working] }
        let head = layout == "automatic" ? snapshot.presentation.leftRevision == .head : baseline == "head"
        return [head ? ("head", "HEAD", snapshot.head) : ("index", pagedText("index"), snapshot.index), working]
    }
    private var texts: [(String, String, String)] { revisions.map { ($0.0, $0.1, $0.2.text ?? "") } }
    private var selectedSource: (String, String, FileRevisionContent)? { revisions.first(where: { $0.0 == compactSource && $0.0 != "worktree" }) ?? revisions.first(where: { $0.0 != "worktree" }) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let searchError, compactDisplay { Text(searchError).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(8) }
            if compactDisplay {
                DiffPane(text: patch, title: snapshot.path, isLoading: patchBusy, leftRevisionTitle: snapshot.path + " - " + (selectedSource?.1 ?? ""), rightRevisionTitle: snapshot.path + " - " + pagedText("worktree"), forceCompact: true, initialSearchOptions: searchOptions, initialReplacement: replacement)
            } else {
                ComparisonEditor(columns: columns, wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: searchOptions.query, navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: snapshot.path, editingCommands: commands, searchOptions: searchOptions)
                ForEach(columns.filter { (firstColumns[$0.id] ?? 1) > 1 }, id: \.id) { column in
                    Text(column.title + ": " + L10n.text("Page starts at column %@; this is a continuation of source line %@.", table: "LargeComparison", arguments: [String(firstColumns[column.id] ?? 1), String(column.firstLine)])).font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
        }.onAppear {
            searchOptions = initialSearchOptions; replacement = initialReplacement; compactDisplay = compact; showSearch = searchRequested
            compactSource = revisions.first?.0 ?? ""; loadPages(); search(); if compactDisplay { loadPatch() }
        }
        .onChange(of: compact) { _, value in compactDisplay = value }
        .onChange(of: compactDisplay) { _, value in if value { loadPatch() } }
        .onChange(of: compactSource) { _, _ in if compactDisplay { loadPatch() } }
        .onChange(of: baseline) { _, _ in reloadPresentation() }
        .onChange(of: layout) { _, _ in reloadPresentation() }
        .onChange(of: showBase) { _, _ in reloadPresentation() }
        .onChange(of: searchRequested) { _, value in if value { showSearch = true } }
        .onChange(of: initialSearchOptions) { _, value in searchOptions = value }
        .onChange(of: initialReplacement) { _, value in replacement = value }
        .onChange(of: searchOptions) { _, _ in search() }
        .onDisappear { pageTask?.cancel(); searchTask?.cancel(); patchTask?.cancel(); onSearchClosed?() }
    }
    private var toolbar: some View {
        HStack {
            Text(pagedText("pagedReadOnly")).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Toggle(largeText("Changes only"), isOn: $compactDisplay).toggleStyle(.checkbox)
            if compactDisplay && revisions.count > 2 {
                Picker(largeText("Compare source"), selection: $compactSource) {
                    ForEach(revisions.filter { $0.0 != "worktree" }, id: \.0) { Text($0.1).tag($0.0) }
                }.frame(width: 120)
            }
            Button { showSearch.toggle() } label: { Image(systemName: "magnifyingglass").frame(width: 24, height: 24) }
                .popover(isPresented: $showSearch) {
                    VStack(alignment: .leading, spacing: 6) {
                        ComparisonSearchPopover(options: $searchOptions, replacement: $replacement, matchCount: hits.count, matchIndex: matchIndex + 1, isSearching: isSearching,
                            onNavigate: locate, error: searchError, onCancelSearch: { searchTask?.cancel(); isSearching = false }, onClose: closeSearch)
                        Text(largeText("Search scans complete revisions line by line. Regex is line-based; lines above 1 MiB are reported. Results are capped at 10,000 per revision.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                        if resultsLimited { Text(largeText("Result limit reached; narrow the query.")).font(.caption).foregroundStyle(.orange).padding(.horizontal, 14) }
                    }
                }.onChange(of: showSearch) { _, value in if !value { onSearchClosed?() } }
            Button(pagedText("previousPage")) { previousPage() }.disabled((columns.allSatisfy { $0.firstLine == 1 && (firstColumns[$0.id] ?? 1) == 1 }) || compactDisplay)
            Text(L10n.text("page", table: "AdvancedDiff", arguments: [page + 1, columns.first?.firstLine ?? 1]))
            Button(pagedText("nextPage")) { nextPage() }.disabled(!hasNext || compactDisplay)
            ExternalComparisonButton(snapshot: snapshot)
        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }
    private func closeSearch() { showSearch = false; onSearchClosed?(); commands.focusEditor() }
    private func reloadPresentation() { pageAnchors = [:]; anchorHistory = []; page = 0; loadPages(); search(); if compactDisplay { loadPatch() } }
    private func nextPage() {
        anchorHistory.append(pageAnchors)
        pageAnchors = Dictionary(uniqueKeysWithValues: columns.map { column in
            (column.id, PagedTextAnchor.after(column.text, firstLine: column.firstLine, firstColumn: firstColumns[column.id] ?? 1))
        })
        page += 1; loadPages()
    }
    private func previousPage() {
        if let previous = anchorHistory.popLast() { pageAnchors = previous }
        else { pageAnchors = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, PagedTextAnchor(line: max(1, $0.firstLine - 500), column: 1)) }) }
        page = max(0, page - 1); loadPages()
    }
    private func loadPages(hit: (String, LargeTextSearchHit)? = nil) {
        pageTask?.cancel(); let token = UUID(); pageToken = token
        let values = texts, pageIndex = page, anchors = pageAnchors
        pageTask = Task {
            let task = Task.detached { () throws -> [(String, String, TextPage, Int)] in
                let source = hit.flatMap { selected in values.first(where: { $0.0 == selected.0 })?.2 }
                return try values.map { id, title, text in
                    try Task.checkCancellation()
                    if let hit, let source {
                        let requested = hit.1.cursor.line - 1
                        let mapped: Int
                        if id == hit.0 { mapped = requested }
                        else { let mapping = TextLineDiff(source: source, target: text).sourceToTarget; mapped = mapping.indices.contains(requested) ? mapping[requested] : 0 }
                        let location = hit.1.pageLocation(maximumUTF16: 100_000)
                        let startColumn = id == hit.0 ? location.firstColumn : 1
                        return (id, title, TextPager.pageFromLine(text, firstLine: mapped + 1, columnOffset: startColumn - 1), startColumn)
                    }
                    if let anchor = anchors[id] { return (id, title, TextPager.pageFromLine(text, firstLine: anchor.line, columnOffset: anchor.column - 1), anchor.column) }
                    return (id, title, TextPager.page(text, index: pageIndex), 1)
                }
            }
            do {
                let pages = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard pageToken == token else { return }
                columns = pages.map { ComparisonEditorColumn(id: $0.0, title: $0.1, text: $0.2.text, isEditable: false, message: nil, firstLine: $0.2.firstLine) }
                firstColumns = Dictionary(uniqueKeysWithValues: pages.map { ($0.0, $0.3) })
                hasNext = pages.contains { $0.2.hasNext }
                pageAnchors = Dictionary(uniqueKeysWithValues: pages.map { ($0.0, PagedTextAnchor(line: $0.2.firstLine, column: $0.3)) })
                if let hit { let location = hit.1.pageLocation(maximumUTF16: 100_000); DispatchQueue.main.async { commands.revealRange(paneID: hit.0, range: location.range) } }
            } catch is CancellationError {}
            catch { if pageToken == token { searchError = largeText(error.localizedDescription) } }
        }
    }
    private func search() {
        searchTask?.cancel(); let token = UUID(); searchToken = token
        hits = []; matchIndex = -1; resultsLimited = false; searchError = nil
        guard !searchOptions.query.isEmpty else { isSearching = false; return }
        let values = texts, options = LargeTextSearchOptions(query: searchOptions.query, caseSensitive: searchOptions.caseSensitive, regularExpression: searchOptions.regularExpression)
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                var found: [(String, LargeTextSearchHit)] = [], limited = false
                for (id, _, text) in values {
                    let result = try await LargeTextSearch.text(text, options: options); try Task.checkCancellation()
                    found += result.hits.map { (id, $0) }; limited = limited || result.isLimited
                }
                guard searchToken == token else { return }; hits = found; resultsLimited = limited
            } catch is CancellationError {}
            catch { if searchToken == token { searchError = largeText(error.localizedDescription) } }
            if searchToken == token { isSearching = false }
        }
    }
    private func locate(_ forward: Bool) {
        guard !hits.isEmpty else { return }
        matchIndex = matchIndex < 0 ? (forward ? 0 : hits.count - 1) : (matchIndex + (forward ? 1 : -1) + hits.count) % hits.count
        page = max(0, (hits[matchIndex].1.cursor.line - 1) / 500); anchorHistory = []
        compactDisplay = false; loadPages(hit: hits[matchIndex])
    }
    private func loadPatch() {
        patchTask?.cancel(); let token = UUID(); patchToken = token; patchBusy = true; patch = ""
        let source = selectedSource?.2.text ?? "", target = snapshot.worktree.text ?? ""
        patchTask = Task {
            do { let value = try await LargeTextComparison.patch(source: source, target: target); try Task.checkCancellation(); if patchToken == token { patch = value } }
            catch is CancellationError {}
            catch { if patchToken == token { searchError = largeText(error.localizedDescription) } }
            if patchToken == token { patchBusy = false }
        }
    }
}

/// A bounded page may end inside a long source line; retain its exact continuation column.
struct PagedTextAnchor: Equatable, Sendable {
    let line: Int
    let column: Int
    static func after(_ text: String, firstLine: Int, firstColumn: Int) -> Self {
        let source = text as NSString
        var offset = 0, line = firstLine, column = firstColumn
        while offset < source.length {
            var start = 0, end = 0, contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            if end > contentsEnd { line += 1; column = 1 }
            else { column += end - offset }
            offset = end
        }
        return Self(line: line, column: column)
    }
}
