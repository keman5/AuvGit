import SwiftUI
import GitCore
import RayGitLocalization

struct OperationLogView: View {
    @ObservedObject var store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<UUID>()
    @State private var activeDetail: UUID?
    @State private var fullRecord: GitCommandRecord?
    @State private var exportError: String?
    private func text(_ key: String) -> String { L10n.text(key, table: "OperationLog") }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(text("Operation log")).font(.headline); Spacer(); Button(text("Close")) { dismiss() }.keyboardShortcut(.cancelAction) }
            if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.operationLog.isEmpty { Text(text("No operations recorded")).foregroundStyle(.secondary) }
                    ForEach(store.operationLog) { record in
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(record.id) }, set: { value in
                            if value { expanded.insert(record.id); activeDetail = record.id }
                            else { expanded.remove(record.id) }
                        })) {
                            let details = detailText(record)
                            if record.previewTruncated {
                                Text(text(record.fullOutputAvailable ? "Preview truncated at 32K characters. Full sanitized output is available." : "Preview truncated at 32K characters. Full output cache has expired.")).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Button(text("View full output")) { fullRecord = record }.disabled(!fullOutputAvailable(record))
                                Button(text("Copy full output")) { copy(record) }.disabled(!fullOutputAvailable(record))
                                Button(text("Export output")) { export(record) }.disabled(!fullOutputAvailable(record))
                            }.controlSize(.small)
                            OperationLogTextView(content: details, focused: activeDetail == record.id, onFocus: { activeDetail = record.id })
                                .frame(height: min(240, max(60, CGFloat(details.components(separatedBy: "\n").count) * 15 + 12)))
                                .padding(.top, 8)
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
                        Divider()
                    }
                }
            }
            if let exportError { Text(exportError).foregroundStyle(.red).textSelection(.enabled) }
        }.sheet(item: $fullRecord) { record in
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text(text("Full sanitized output")).font(.headline); Spacer(); Button(text("Close")) { fullRecord = nil } }
                OperationLogTextView(content: detailText(record, full: true), focused: true, onFocus: {})
            }.padding(20).frame(width: 900, height: 600)
        }.buttonBorderShape(.roundedRectangle(radius: 6)).padding(20).frame(width: 760, height: 510)
    }
    private func detailText(_ record: GitCommandRecord, full: Bool = false, snapshot: (output: String, error: String?, complete: Bool)? = nil) -> String {
        var lines = [record.date.formatted(), record.operation, record.directory, record.command]
        if let code = record.exitCode { lines.append(text("Exit status") + ": \(code)") }
        let contents = snapshot ?? (full ? record.fullContents() : (output: record.output, error: record.error, complete: !record.previewTruncated))
        if !contents.output.isEmpty { lines.append(contents.output) }
        if let error = contents.error { lines.append(error) }
        if full && !contents.complete { lines.append(text("Preview truncated at 32K characters. Full output cache has expired.")) }
        if !full && record.previewTruncated { lines.append(text(record.fullOutputAvailable ? "Preview truncated at 32K characters. Full sanitized output is available." : "Preview truncated at 32K characters. Full output cache has expired.")) }
        if record.error?.contains("32 MB display limit") == true { lines.append(text("Process output exceeded 32 MiB. Complete output was not captured.")) }
        for command in store.commands(for: record) {
            lines.append(detailText(command, full: full))
        }
        return lines.joined(separator: "\n")
    }

    private func fullOutputAvailable(_ record: GitCommandRecord) -> Bool {
        record.fullOutputAvailable && store.commands(for: record).allSatisfy { $0.fullOutputAvailable }
    }
    private func unavailable() {
        exportError = OperationFailure.message(GitError(text("Preview truncated at 32K characters. Full output cache has expired.")), repository: store.repositoryURL)
    }
    private func copy(_ record: GitCommandRecord) {
        let contents = record.fullContents()
        guard contents.complete, fullOutputAvailable(record) else { unavailable(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detailText(record, full: true, snapshot: contents), forType: .string)
    }
    private func export(_ record: GitCommandRecord) {
        let contents = record.fullContents()
        guard contents.complete, fullOutputAvailable(record) else { unavailable(); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "RayGit-operation.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try detailText(record, full: true, snapshot: contents).write(to: url, atomically: true, encoding: .utf8); exportError = nil }
        catch { exportError = OperationFailure.message(error, repository: store.repositoryURL) }
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
