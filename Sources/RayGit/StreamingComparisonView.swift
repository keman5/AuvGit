import SwiftUI
import GitCore
import RayGitLocalization

struct StreamingComparisonView: View {
    let repository: GitRepository
    let path: String
    var initialSearchOptions = ComparisonSearchOptions()
    var initialReplacement = ""
    var compact = false
    var searchRequested = false
    var onSearchClosed: (() -> Void)? = nil
    var changeNavigation = 0
    var searchNavigation = 0
    var onCursorChange: ((ComparisonCursorStatus) -> Void)? = nil
    @State private var reader: StreamingTextFile?
    @State private var page: StreamingTextPage?
    @State private var history: [StreamingCursor] = [.start]
    @State private var busy = false
    @State private var error: String?
    @State private var revision = StreamingRevision.worktree
    @State private var revisions: [StreamingRevision] = []
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var displayedHistory: [StreamingCursor] = [.start]
    @State private var cursorColumns: [UInt64: Int] = [0: 1]
    @State private var pageFirstColumn = 1
    @State private var searchOptions = ComparisonSearchOptions()
    @State private var replacement = ""
    @State private var showSearch = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchToken = UUID()
    @State private var isSearching = false
    @State private var results: [LargeTextSearchHit] = []
    @State private var resultIndex = -1
    @State private var searchError: String?
    @State private var resultsLimited = false
    @State private var compactDisplay = false
    @State private var patch = ""
    @State private var overviewMarkers: [ComparisonOverviewMarker] = []
    @State private var overviewLineCount = 1
    @State private var pendingOverviewFraction: Double?
    @State private var overviewDragTask: Task<Void, Never>?
    @State private var overviewDragToken = UUID()
    @State private var overviewLines: [Int] = []
    @State private var overviewTask: Task<Void, Never>?
    @State private var selectedChange = -1
    @State private var revealRequest: ComparisonRevealRequest?
    @State private var overviewToken = UUID()
    @State private var overviewBusy = false
    @StateObject private var commands = ComparisonEditingCommands()
    private func label(_ key: String) -> String { L10n.text(key, table: "Streaming") }
    private func largeText(_ key: String) -> String { L10n.text(key, table: "LargeComparison") }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let error { FloatingNotice(message: error, guidance: noticeText("Review the file and reload the comparison before trying again. Save any draft you want to keep before reloading. The message remains available here until the next operation.")) }
                Text(label("title")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker(label("revision"), selection: $revision) { ForEach(revisions, id: \.self) { Text(label($0.rawValue)).tag($0) } }.frame(width: 145).disabled(busy)
                Toggle(largeText("Changes only"), isOn: $compactDisplay).toggleStyle(.checkbox)
                Button { showSearch.toggle() } label: { ComparisonToolbarIcon(name: "magnifyingglass") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .popover(isPresented: $showSearch) {
                        VStack(alignment: .leading, spacing: 6) {
                            ComparisonSearchPopover(options: $searchOptions, replacement: $replacement, matchCount: results.count, matchIndex: resultIndex + 1,
                                isSearching: isSearching, onNavigate: { direction in Task { await locate(direction) } }, error: searchError,
                                onCancelSearch: { searchTask?.cancel(); isSearching = false }, onClose: closeSearch)
                            Text(largeText("Search scans the complete UTF-8 file line by line. Regex is line-based; lines above 1 MiB are reported. Results are capped at 10,000.")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
                            if resultsLimited { Text(largeText("Result limit reached; narrow the query.")).font(.caption).foregroundStyle(.orange).padding(.horizontal, 14) }
                        }
                    }.onChange(of: showSearch) { _, value in if !value { onSearchClosed?() } }
                if busy { ProgressView().controlSize(.small); Button(label("cancel")) { operation?.cancel() } }
                Button(label("reload")) { start() }.disabled(busy)
                Button(label("previous")) { if history.count > 1 { history.removeLast(); Task { await load(history.last!) } } }.disabled(busy || history.count < 2 || compactDisplay)
                Button(label("next")) { if let next = page?.next { history.append(next); Task { await load(next) } } }.disabled(busy || page?.next == nil || compactDisplay)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            if compactDisplay {
                if (busy || overviewBusy) && patch.isEmpty { ProgressView() }
                else { DiffPane(text: patch, title: path, isLoading: busy || overviewBusy, leftRevisionTitle: sourceTitle, rightRevisionTitle: targetTitle,
                                forceCompact: true, initialSearchOptions: searchOptions, initialReplacement: replacement) }
            } else if let page {
                ComparisonEditor(columns: [ComparisonEditorColumn(id: "stream", title: path + " - " + label(revision.rawValue), text: page.text, isEditable: false, message: nil, firstLine: page.cursor.line)], wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: searchOptions.query, navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: path, onCursorChange: onCursorChange, editingCommands: commands, revealRequest: revealRequest, overviewMarkers: overviewMarkers, onOverviewJump: { index in Task { await jumpToChange(index) } }, onOverviewNavigate: navigateOverview, searchOptions: searchOptions)
                HStack {
                    Text(L10n.text("position", table: "Streaming", arguments: [page.cursor.line, Int64(page.cursor.offset), Int64(page.totalBytes)]))
                    Spacer(); Text(label("readonly"))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
                if pageFirstColumn > 1 { Text(L10n.text("Page starts at column %@; this is a continuation of source line %@.", table: "LargeComparison", arguments: [String(pageFirstColumn), String(page.cursor.line)])).font(.caption).foregroundStyle(.secondary).padding(6) }
                if !page.text.hasSuffix("\n"), page.next != nil { Text(largeText("The source line continues on the next page.")).font(.caption).foregroundStyle(.secondary).padding(6) }
            } else { Spacer() }
        }.onAppear { searchOptions = initialSearchOptions; replacement = initialReplacement; compactDisplay = compact; showSearch = searchRequested; start() }
        .onChange(of: searchNavigation) { old, new in Task { await locate(new > old) } }
        .onChange(of: changeNavigation) { old, new in
            guard !overviewLines.isEmpty else { return }
            let index = selectedChange < 0 ? (new > old ? 0 : overviewLines.count - 1) : (selectedChange + (new > old ? 1 : overviewLines.count - 1)) % overviewLines.count
            Task { await jumpToChange(index) }
        }
        .onChange(of: revision) { _, _ in start() }
        .onChange(of: compactDisplay) { _, value in if value && reader != nil { loadPatch() } }
        .onChange(of: compact) { _, value in compactDisplay = value }
        .onChange(of: searchRequested) { _, value in if value { showSearch = true } }
        .onChange(of: initialSearchOptions) { _, value in searchOptions = value }
        .onChange(of: initialReplacement) { _, value in replacement = value }
        .onChange(of: searchOptions) { _, _ in search() }
        .onDisappear { operation?.cancel(); searchTask?.cancel(); overviewTask?.cancel(); overviewDragTask?.cancel(); overviewDragToken = UUID(); reader = nil; onSearchClosed?() }
    }
    private var sourceTitle: String { path + " - " + (revision == .worktree ? label(revisions.contains(.ours) ? "ours" : "index") : revision == .index ? "HEAD" : revision == .head ? largeText("Parent revision") : label(revision.rawValue)) }
    private var targetTitle: String { path + " - " + (revision == .index ? label("index") : revision == .head ? "HEAD" : label("worktree")) }
    private func closeSearch() { showSearch = false; onSearchClosed?(); commands.focusEditor() }
    private func start() {
        operation?.cancel(); searchTask?.cancel(); overviewTask?.cancel(); results = []; resultIndex = -1
        overviewDragTask?.cancel(); overviewDragTask = nil; pendingOverviewFraction = nil; overviewDragToken = UUID()
        patch = ""; overviewMarkers = []; overviewLines = []; selectedChange = -1; overviewToken = UUID(); overviewBusy = false; overviewTask = nil
        let token = UUID(); generation = token
        operation = Task { await reopen(token) }
    }
    private func reopen(_ token: UUID) async {
        busy = true; error = nil; page = nil; reader = nil; history = [.start]; displayedHistory = [.start]; cursorColumns = [0: 1]; pageFirstColumn = 1
        do {
            let available = try await repository.availableStreamingRevisions(path: path)
            guard generation == token else { return }; revisions = available
            let selected = available.contains(revision) ? revision : available.first ?? .worktree
            if selected != revision { revision = selected; return }
            let result = try await repository.streamingContent(path: path, revision: selected)
            try Task.checkCancellation(); guard generation == token else { return }
            reader = result; page = try await result.page()
        } catch is CancellationError { if generation == token { self.error = label("cancelled") } }
        catch { if generation == token { self.error = OperationFailure.message(error, repository: repository.url) } }
        guard generation == token else { return }; busy = false; operation = nil
        search(); loadOverview(); if compactDisplay { loadPatch() }
    }
    private func load(_ cursor: StreamingCursor) async {
        guard let reader else { return }; busy = true; error = nil
        if let page, cursor == page.next {
            let tail = page.text.components(separatedBy: "\n").last ?? ""
            cursorColumns[cursor.offset] = tail.utf16.count + (page.text.contains("\n") ? 1 : pageFirstColumn)
        }
        pageFirstColumn = cursorColumns[cursor.offset] ?? 1
        do {
            page = try await reader.page(at: cursor); displayedHistory = history
            revealRequest = ComparisonRevealRequest(paneID: "stream", firstLine: cursor.line, number: cursor.line)
        }
        catch is CancellationError { self.error = label("cancelled"); history = displayedHistory }
        catch { self.error = OperationFailure.message(error, repository: repository.url); history = displayedHistory }
        busy = false
    }
    private func loadOverview() {
        guard let reader else { return }
        overviewTask?.cancel(); let token = UUID(), selected = revision; overviewToken = token; overviewBusy = true
        overviewTask = Task {
            do {
                async let count = reader.lineCount()
                async let changes = repository.streamingDiff(path: path, revision: selected)
                let values = try await (count, changes)
                let parsed = DiffParser.parse(values.1)
                let total = Double(max(1, values.0))
                let patchChanges = ComparisonPatchOverview.changes(in: parsed)
                let markers = patchChanges.enumerated().map { index, change in
                    ComparisonOverviewMarker(lower: min(1, Double(max(0, change.firstLine - 1)) / total), upper: min(1, Double(change.lastLine) / total), kind: change.kind, index: index)
                }
                try Task.checkCancellation(); guard token == overviewToken else { return }
                overviewLineCount = values.0; patch = values.1; overviewLines = patchChanges.map(\.firstLine); overviewMarkers = markers
            } catch is CancellationError { }
            catch { if token == overviewToken { self.error = OperationFailure.message(error, repository: repository.url) } }
            if token == overviewToken { overviewBusy = false; overviewTask = nil }
        }
    }
    private func navigateOverview(_ fraction: Double) {
        pendingOverviewFraction = fraction
        guard overviewDragTask == nil, let reader else { return }
        let token = overviewDragToken
        overviewDragTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    guard let fraction = pendingOverviewFraction else { break }
                    pendingOverviewFraction = nil
                    let line = min(overviewLineCount, max(1, Int(fraction * Double(overviewLineCount)) + 1))
                    let cursor = try await reader.cursor(atLine: line)
                    let next = try await reader.page(at: cursor)
                    try Task.checkCancellation(); guard overviewDragToken == token else { break }
                    if pendingOverviewFraction != nil { continue }
                    selectedChange = -1; compactDisplay = false; pageFirstColumn = 1
                    history = [cursor]; displayedHistory = history; page = next
                    revealRequest = ComparisonRevealRequest(paneID: "stream", firstLine: cursor.line, number: cursor.line)
                } catch is CancellationError { break }
                catch { if overviewDragToken == token { self.error = OperationFailure.message(error, repository: repository.url) }; break }
            }
            overviewDragTask = nil
        }
    }
    private func jumpToChange(_ index: Int) async {
        guard overviewLines.indices.contains(index), let reader else { return }
        selectedChange = index; compactDisplay = false
        do {
            let cursor = try await reader.cursor(atLine: overviewLines[index])
            history = [cursor]; await load(cursor)
            revealRequest = ComparisonRevealRequest(paneID: "stream", firstLine: cursor.line, number: cursor.line)
        } catch { self.error = OperationFailure.message(error, repository: repository.url) }
    }
    private func loadPatch() {
        guard patch.isEmpty, overviewTask == nil else { return }
        operation?.cancel(); let token = UUID(); generation = token; busy = true; patch = ""
        operation = Task {
            do { let value = try await repository.streamingDiff(path: path, revision: revision); try Task.checkCancellation(); if generation == token { patch = value } }
            catch is CancellationError {}
            catch { if generation == token { self.error = OperationFailure.message(error, repository: repository.url) } }
            if generation == token { busy = false; operation = nil }
        }
    }
    private func search() {
        searchTask?.cancel(); let token = UUID(); searchToken = token
        results = []; resultIndex = -1; searchError = nil; resultsLimited = false
        guard let reader, !searchOptions.query.isEmpty else { isSearching = false; return }
        let options = LargeTextSearchOptions(query: searchOptions.query, caseSensitive: searchOptions.caseSensitive, regularExpression: searchOptions.regularExpression)
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let value = try await reader.search(options); try Task.checkCancellation()
                guard searchToken == token else { return }; results = value.hits; resultsLimited = value.isLimited
            } catch is CancellationError {}
            catch { if searchToken == token { searchError = largeText(error.localizedDescription) } }
            if searchToken == token { isSearching = false }
        }
    }
    private func locate(_ forward: Bool) async {
        guard !results.isEmpty else { return }
        resultIndex = resultIndex < 0 ? (forward ? 0 : results.count - 1) : (resultIndex + (forward ? 1 : -1) + results.count) % results.count
        let hit = results[resultIndex]; operation?.cancel(); generation = UUID(); compactDisplay = false
        let location = hit.pageLocation(maximumBytes: 128 * 1024)
        let cursor = location.cursor
        cursorColumns[cursor.offset] = location.firstColumn
        history = [cursor]; await load(cursor)
        revealRequest = ComparisonRevealRequest(paneID: "stream", firstLine: cursor.line, range: location.range)
    }
}
