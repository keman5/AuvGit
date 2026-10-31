import SwiftUI
import GitCore
import AuvGitLocalization

struct OperationLogView: View {
    @ObservedObject var store: RepositoryStore
    @ObservedObject private var commandRecords: RepositoryCommandRecords
    init(store: RepositoryStore) {
        self.store = store
        commandRecords = store.commandRecords
    }
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<UUID>()
    @State private var activeDetail: UUID?
    @State private var fullRecord: GitCommandRecord?
    @State private var exportError: String?
    @State private var outputTask: Task<Void, Never>?
    @State private var outputGeneration = UUID()
    private func text(_ key: String) -> String { L10n.text(key, table: "OperationLog") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(text("Operation log")).font(.headline); DialogButton(text("Close"), prominent: true, role: .cancel) { dismiss() } }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
            if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.operationLog.isEmpty { Text(text("No operations recorded")).foregroundStyle(.secondary) }
                    ForEach(store.operationLog) { record in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(record.id) }, set: { value in
                            if value { expanded.insert(record.id); activeDetail = record.id }
                            else { expanded.remove(record.id) }
                        })) {
                            let available = fullOutputAvailable(record)
                            HStack {
                                Button(text("View full output")) { fullRecord = record }.disabled(!available).accessibilityLabel(text("View full output"))
                                Button(text("Copy full output")) { copy(record) }.disabled(!available)
                                Button(text("Export output")) { export(record) }.disabled(!available)
                            }.controlSize(.small)
                            OperationLogPreviewView(snapshot: snapshot(record), focused: activeDetail == record.id,
                                onFocus: { activeDetail = record.id }).padding(.top, 8)
                        } label: {
                            HStack {
                                Image(systemName: record.cancelled ? "minus.circle" : record.error == nil ? "checkmark.circle" : "exclamationmark.triangle").foregroundStyle(record.error == nil ? Color.secondary : .red)
                                Text(record.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                                Text(record.command.isEmpty ? record.operation : "git " + record.operation).fontWeight(.medium)
                                Text(record.error.flatMap { GitFailureSummary.message(for: $0, localize: text) } ?? text(record.cancelled ? "Cancelled" : record.error == nil ? "Completed" : "Failed"))
                                Spacer()
                                Text(String(format: "%.2fs", record.duration)).foregroundStyle(.secondary)
                            }.font(.caption)
                        }.disclosureGroupStyle(OperationLogDisclosureStyle())
                            .accessibilityLabel(record.command.isEmpty ? record.operation : "git " + record.operation)
                        Divider()
                    }
                }
            }
            if let exportError { Text(exportError).foregroundStyle(.red).textSelection(.enabled) }
        }.auvGitSheet(item: $fullRecord) { record in
            FullOperationLogView(snapshot: snapshot(record), title: text("Full sanitized output"), closeTitle: text("Close")) { fullRecord = nil }
        }.buttonBorderShape(.roundedRectangle(radius: 6)).padding(20).frame(width: 760, height: 510)
            .onDisappear { outputTask?.cancel(); outputGeneration = UUID() }
    }

    private func fullOutputAvailable(_ record: GitCommandRecord) -> Bool {
        record.fullOutputAvailable && store.commands(for: record).allSatisfy { $0.fullOutputAvailable }
    }
    private func unavailable() {
        exportError = OperationFailure.message(GitError(text("Preview truncated at 32K characters. Full output cache has expired.")), repository: store.repositoryURL)
    }
    private func snapshot(_ record: GitCommandRecord) -> OperationLogSnapshot {
        OperationLogSnapshot(records: [record] + store.commands(for: record), exitLabel: text("Exit status"), expiredMessage: text("Preview truncated at 32K characters. Full output cache has expired."), captureLimitMessage: text("Process output exceeded 32 MiB. Complete output was not captured."))
    }
    private func perform(_ record: GitCommandRecord, destination: URL? = nil) {
        outputTask?.cancel()
        let generation = UUID(); outputGeneration = generation
        let captured = snapshot(record)
        outputTask = Task { @MainActor in
            do {
                let contents = try await OperationLogContentLoader.shared.load(captured)
                try Task.checkCancellation()
                guard generation == outputGeneration else { return }
                guard contents.complete, fullOutputAvailable(record) else { unavailable(); return }
                if let destination {
                    try await Task.detached(priority: .userInitiated) {
                        try contents.text.write(to: destination, atomically: true, encoding: .utf8)
                    }.value
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(contents.text, forType: .string)
                }
                if generation == outputGeneration { exportError = nil }
            } catch is CancellationError { }
            catch {
                guard generation == outputGeneration else { return }
                exportError = OperationFailure.message(error, repository: store.repositoryURL)
            }
        }
    }
    private func copy(_ record: GitCommandRecord) { perform(record) }
    private func export(_ record: GitCommandRecord) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "AuvGit-operation.txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform(record, destination: url)
        }
    }
}

private struct OperationLogPreviewView: View {
    let snapshot: OperationLogSnapshot
    let focused: Bool
    let onFocus: () -> Void
    @State private var preview: OperationLogPreview?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let preview {
                if preview.truncated {
                    Text(L10n.text(preview.fullOutputAvailable ? "Preview truncated at 32K characters. Full sanitized output is available." : "Preview truncated at 32K characters. Full output cache has expired.", table: "OperationLog"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                OperationLogTextView(content: preview.text, focused: focused, onFocus: onFocus)
                    .frame(height: min(240, max(60, CGFloat(preview.text.filter { $0 == "\n" }.count + 1) * 15 + 12)))
            } else { ProgressView().controlSize(.small).frame(height: 60) }
        }.task(id: snapshot.identity) {
            let loaded = try? await OperationLogContentLoader.shared.preview(snapshot)
            guard !Task.isCancelled else { return }
            preview = loaded
        }
    }
}

private struct FullOperationLogView: View {
    let snapshot: OperationLogSnapshot
    let title: String
    let closeTitle: String
    let close: () -> Void
    @State private var content: OperationLogContent?
    @State private var page = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.headline); DialogButton(closeTitle, prominent: true, role: .cancel, action: close) }
                .buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity)
            if let content {
                if content.pages.count > 1 {
                    HStack {
                        Button { page = max(0, page - 1) } label: { Image(systemName: "chevron.left") }.disabled(page == 0)
                        Text("\(page + 1) / \(content.pages.count)").monospacedDigit()
                        Button { page = min(content.pages.count - 1, page + 1) } label: { Image(systemName: "chevron.right") }.disabled(page == content.pages.count - 1)
                    }
                }
                OperationLogTextView(content: content.pages[min(page, content.pages.count - 1)], focused: false, onFocus: {})
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(20).frame(width: 900, height: 600)
            .task(id: snapshot.identity) {
                content = nil; page = 0
                let loaded = try? await OperationLogContentLoader.shared.load(snapshot)
                guard !Task.isCancelled else { return }
                content = loaded
            }
    }
}

private struct OperationLogDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).frame(width: 12)
                    configuration.label
                }.frame(maxWidth: .infinity, minHeight: 24, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(historyRefinementText(configuration.isExpanded ? "Expanded" : "Collapsed"))
            if configuration.isExpanded { configuration.content.padding(.leading, 18) }
        }
    }
}
