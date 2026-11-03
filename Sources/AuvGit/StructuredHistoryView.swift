import SwiftUI
import AppKit
import GitCore
import AuvGitLocalization

func sessionText(_ key: String) -> String { L10n.text(key, table: "SessionWorkflows") }

struct StructuredHistoryView: View {
    let repository: GitRepository
    let blamePath: String?
    let revision: String
    @State private var lines: [BlameLine] = []
    @State private var entries: [ReflogEntry] = []
    @State private var selection: Int?
    @State private var rangeSelection = ListSelectionState<Int>()
    @State private var error = ""
    @State private var loading = false
    @State private var request = UUID()
    var body: some View {
        VStack(spacing: 0) {
            if loading { ProgressView().controlSize(.small).padding(12) }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            if blamePath != nil { blameTable } else { reflogTable }
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(sessionText("Copy code or action")) { copySelected() }.disabled(selection == nil)
                Button(sessionText("Open commit")) { openSelected() }.disabled(selectedHash == nil)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
        }.task(id: repository.url.path + "\0" + (blamePath ?? "") + "\0" + revision) { await load() }
    }
    private var blameTable: some View {
        Table(lines, selection: ListSelectionState.binding($rangeSelection, primary: $selection, orderedIDs: lines.map(\.id))) {
            TableColumn(sessionText("Line")) { row in Text(String(row.line)) }.width(45)
            TableColumn(sessionText("Author"), value: \.author).width(min: 90, ideal: 130)
            TableColumn(sessionText("Date")) { row in Text(row.date, format: .dateTime.year().month().day().locale(L10n.locale)) }.width(105)
            TableColumn(sessionText("Commit")) { row in Text(String(row.hash.prefix(10))).font(.system(.caption, design: .monospaced)) }.width(90)
            TableColumn(sessionText("Code")) { row in Text(row.code).font(.system(size: 12, design: .monospaced)) }
        }.contextMenu(forSelectionType: Int.self) { ids in if let row = ids.first { Button(sessionText("Open commit")) { open(lines.first { $0.id == row }?.hash) } } } primaryAction: { ids in if let row = ids.first { open(lines.first { $0.id == row }?.hash) } }
    }
    private var reflogTable: some View {
        Table(entries, selection: ListSelectionState.binding($rangeSelection, primary: $selection, orderedIDs: entries.map(\.id))) {
            TableColumn(sessionText("Reference"), value: \.selector).width(min: 140, ideal: 190)
            TableColumn(sessionText("Author"), value: \.author).width(min: 90, ideal: 130)
            TableColumn(sessionText("Date")) { row in Text(row.date, format: .dateTime.year().month().day().hour().minute().second().locale(L10n.locale)) }.width(150)
            TableColumn(sessionText("Commit")) { row in Text(String(row.hash.prefix(10))).font(.system(.caption, design: .monospaced)) }.width(90)
            TableColumn(sessionText("Action"), value: \.action)
        }.contextMenu(forSelectionType: Int.self) { ids in if let row = ids.first { Button(sessionText("Open commit")) { open(entries.first { $0.id == row }?.hash) } } } primaryAction: { ids in if let row = ids.first { open(entries.first { $0.id == row }?.hash) } }
    }
    private var selectedHash: String? { blamePath != nil ? lines.first { $0.id == selection }?.hash : entries.first { $0.id == selection }?.hash }
    private func load() async {
        let token = UUID(); request = token; loading = true; error = ""; selection = nil; lines = []; entries = []
        do { if let blamePath { let result = try await repository.blameLines(path: blamePath, revision: revision); if request == token, !Task.isCancelled { lines = result } } else { let result = try await repository.reflogEntries(); if request == token, !Task.isCancelled { entries = result } } }
        catch is CancellationError {} catch { if request == token { self.error = OperationFailure.message(error, repository: repository.url) } }
        if request == token { loading = false }
    }
    private func openSelected() { open(selectedHash) }
    private func open(_ hash: String?) { guard let hash else { return }; Task { do { if let commit = try await repository.log(limit: 1, ref: hash).first { CommitDetailPresenter.show(commit: commit, repository: repository) } } catch { self.error = OperationFailure.message(error, repository: repository.url) } } }
    private func copySelected() {
        let ids = rangeSelection.selected(primary: selection, orderedIDs: blamePath != nil ? lines.map(\.id) : entries.map(\.id))
        let content = blamePath != nil ? lines.filter { ids.contains($0.id) }.map(\.code) : entries.filter { ids.contains($0.id) }.map(\.action)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content.joined(separator: "\n"), forType: .string)
    }
}
