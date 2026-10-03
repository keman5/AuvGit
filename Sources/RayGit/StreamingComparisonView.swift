import SwiftUI
import GitCore
import RayGitLocalization

struct StreamingComparisonView: View {
    let repository: GitRepository
    let path: String
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
    private func label(_ key: String) -> String { L10n.text(key, table: "Streaming") }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label("title")).font(.system(size: 12, weight: .semibold))
                    Text(label("historySupport")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Picker(label("revision"), selection: $revision) {
                    ForEach(revisions, id: \.self) { item in Text(label(item.rawValue)).tag(item) }
                }.frame(width: 180).disabled(busy)
                if busy { ProgressView().controlSize(.small); Button(label("cancel")) { operation?.cancel() }.disabled(operation == nil) }
                Button(label("reload")) { start() }.disabled(busy)
                Button(label("previous")) { if history.count > 1 { history.removeLast(); Task { await load(history.last!) } } }.disabled(busy || history.count < 2)
                Button(label("next")) { if let next = page?.next { history.append(next); Task { await load(next) } } }.disabled(busy || page?.next == nil)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
            if let page {
                ComparisonEditor(columns: [ComparisonEditorColumn(id: "stream", title: path, text: page.text, isEditable: false, message: nil, firstLine: page.cursor.line)], wrapLines: false, showLineNumbers: true, synchronizeScroll: false, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: path)
                HStack {
                    Text(L10n.text("position", table: "Streaming", arguments: [page.cursor.line, Int64(page.cursor.offset), Int64(page.totalBytes)]))
                    Spacer()
                    Text(label("readonly"))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            } else { Spacer() }
        }.onAppear { start() }
        .onChange(of: revision) { _, _ in start() }
        .onDisappear { operation?.cancel(); reader = nil }
    }
    private func start() {
        operation?.cancel()
        let token = UUID(); generation = token
        operation = Task { await reopen(token) }
    }
    private func reopen(_ token: UUID) async {
        busy = true; error = nil; page = nil; reader = nil; history = [.start]; displayedHistory = [.start]
        do {
            let available = try await repository.availableStreamingRevisions(path: path)
            guard generation == token else { return }
            revisions = available
            let selected = available.contains(revision) ? revision : available.first ?? .worktree
            if selected != revision { revision = selected; return }
            let result = try await repository.streamingContent(path: path, revision: selected)
            try Task.checkCancellation()
            guard generation == token else { return }
            reader = result
            page = try await result.page()
        } catch is CancellationError {
            guard generation == token else { return }
            self.error = label("cancelled"); reader = nil; page = nil
        } catch {
            guard generation == token else { return }
            self.error = error.localizedDescription; reader = nil; page = nil
        }
        guard generation == token else { return }
        busy = false; operation = nil
    }
    private func load(_ cursor: StreamingCursor) async {
        guard let reader else { return }
        busy = true; error = nil
        do {
            page = try await reader.page(at: cursor)
            displayedHistory = history
        } catch is CancellationError {
            self.error = label("cancelled"); page = nil; history = displayedHistory
        } catch {
            self.error = error.localizedDescription; page = nil; history = displayedHistory
        }
        busy = false
    }
}
