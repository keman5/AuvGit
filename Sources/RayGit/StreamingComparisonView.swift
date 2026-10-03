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
    private func label(_ key: String) -> String { L10n.text(key, table: "Streaming") }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(label("title")).font(.headline)
                    Text(label("historyLimit")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(label("reload")) { Task { await reopen() } }.disabled(busy)
                Button(label("previous")) { if history.count > 1 { history.removeLast(); Task { await load(history.last!) } } }.disabled(busy || history.count < 2)
                Button(label("next")) { if let next = page?.next { history.append(next); Task { await load(next) } } }.disabled(busy || page?.next == nil)
            }.padding(10)
            if let error { Text(error).foregroundStyle(.orange).textSelection(.enabled).padding(10) }
            if let page {
                ComparisonEditor(columns: [ComparisonEditorColumn(id: "stream", title: path, text: page.text, isEditable: false, message: nil)], wrapLines: false, showLineNumbers: true, synchronizeScroll: false, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: path)
                HStack {
                    Text(L10n.text("position", table: "Streaming", arguments: [page.cursor.line, Int64(page.cursor.offset), Int64(page.totalBytes)]))
                    Spacer()
                    Text(label("readonly"))
                }.font(.caption).foregroundStyle(.secondary).padding(8)
            } else { Spacer() }
        }.task { await reopen() }
    }
    private func reopen() async {
        busy = true; error = nil; page = nil; history = [.start]
        do { reader = try await repository.streamingWorktree(path: path) }
        catch { error = error.localizedDescription; reader = nil }
        busy = false
        if reader != nil { await load(.start) }
    }
    private func load(_ cursor: StreamingCursor) async {
        guard let reader else { return }
        busy = true; error = nil
        do { page = try await reader.page(at: cursor) }
        catch { error = error.localizedDescription }
        busy = false
    }
}
