import SwiftUI
import GitCore

struct ReferenceChangesView: View {
    let repository: GitRepository
    let left: String
    let right: String
    @State private var files: [GitCommitFile] = []
    @State private var selection: String?
    @State private var diff = ""
    @State private var loading = false
    @State private var error = ""
    @State private var request = UUID()
    @State private var loadRequest = UUID()
    @State private var snapshot: ComparisonSnapshot?
    private struct ComparisonSnapshot {
        let leftCommit: String
        let rightCommit: String
    }
    var body: some View {
        VStack(spacing: 0) {
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
            HSplitView {
                VStack(spacing: 0) {
                    Text(historyActionText("files")).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
                    Divider()
                    if files.isEmpty {
                        if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else { Text(historyActionText("noFiles")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).padding(12) }
                    } else {
                        List(selection: $selection) {
                            ForEach(files) { file in
                                HStack(spacing: 8) {
                                    Text(file.status).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(file.path).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                                }.tag(file.path).help(file.path)
                            }
                        }.listStyle(.plain)
                    }
                }.frame(minWidth: 180, idealWidth: 210, maxWidth: 260)
                DiffPane(text: diff, title: selection ?? left + " → " + right, isLoading: loading).frame(minWidth: 360)
            }
        }.task(id: left + "\0" + right) { await load() }
        .onChange(of: selection) { _, _ in Task { await loadDiff() } }
    }
    private func load() async {
        let token = UUID(); loadRequest = token; request = UUID()
        snapshot = nil; files = []; selection = nil; diff = ""; error = ""; loading = true
        do {
            async let resolvedLeft = repository.workflowRevision(left)
            async let resolvedRight = repository.workflowRevision(right)
            let commits = try await (resolvedLeft, resolvedRight)
            guard loadRequest == token, !Task.isCancelled else { return }
            let captured = ComparisonSnapshot(leftCommit: commits.0, rightCommit: commits.1)
            let result = try await repository.referenceFiles(left: captured.leftCommit, right: captured.rightCommit)
            guard loadRequest == token, !Task.isCancelled else { return }
            snapshot = captured; files = result; selection = files.first?.path
            if files.isEmpty { loading = false } else { await loadDiff() }
        } catch is CancellationError { if loadRequest == token { loading = false } }
        catch { if loadRequest == token { self.error = OperationFailure.message(error, repository: repository.url); loading = false } }
    }
    private func loadDiff() async {
        let token = UUID(); request = token
        guard let captured = snapshot else { return }
        guard let file = files.first(where: { $0.path == selection }) else { diff = ""; loading = false; return }
        loading = true
        do {
            let result = try await repository.referenceFileDiff(left: captured.leftCommit, right: captured.rightCommit, file: file)
            if request == token, !Task.isCancelled { diff = result; error = "" }
        } catch is CancellationError { }
        catch { if request == token { self.error = OperationFailure.message(error, repository: repository.url) } }
        if request == token { loading = false }
    }
}
