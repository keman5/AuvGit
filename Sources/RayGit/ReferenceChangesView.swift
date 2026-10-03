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
    var body: some View {
        VStack(spacing: 0) {
            if !error.isEmpty { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                List(selection: $selection) { ForEach(files) { file in HStack { Text(file.status).foregroundStyle(.secondary); Text(file.path).lineLimit(2) }.tag(file.path) } }.frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                DiffPane(text: diff, title: left + " → " + right, isLoading: loading)
            }
        }.task(id: left + "\0" + right) { await load() }
        .onChange(of: selection) { _, _ in Task { await loadDiff() } }
    }
    private func load() async {
        loading = true
        do { files = try await repository.referenceFiles(left: left, right: right); selection = files.first?.path; if files.isEmpty { diff = "" }; error = "" } catch { error = error.localizedDescription }
        loading = false
    }
    private func loadDiff() async {
        let token = UUID(); request = token
        guard let file = files.first(where: { $0.path == selection }) else { return }
        loading = true
        do { let result = try await repository.referenceFileDiff(left: left, right: right, file: file); if request == token { diff = result; error = "" } } catch { if request == token { error = error.localizedDescription } }
        if request == token { loading = false }
    }
}
