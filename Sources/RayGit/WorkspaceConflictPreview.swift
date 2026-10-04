import SwiftUI
import GitCore
import RayGitLocalization

/// Uses the same stage-aware surface as the resolver, with no editing callbacks.
struct WorkspaceConflictPreview: View {
    let snapshot: FileComparisonSnapshot
    @AppStorage("editor.wrapLines") private var wraps = false
    @AppStorage("editor.showLineNumbers") private var numbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronized = true
    @State private var showBase = false
    @StateObject private var resolver = ComparisonResolverState()

    private var blocks: [ConflictDraft.Block] { ConflictDraft.blocks(in: snapshot.worktree.text ?? "") }
    private func column(_ id: String, _ title: String, _ content: FileRevisionContent?) -> ComparisonEditorColumn {
        ComparisonEditorColumn(id: id, title: compareText(title), text: content?.text ?? "", isEditable: false,
            message: content?.text != nil ? nil : content?.unavailableReason.map { compareText($0) } ?? compareText("File does not exist in this version"), detail: content?.objectID.map { String($0.prefix(8)) } ?? designCompareText("Read-only"))
    }
    private func selectConflict(_ index: Int) {
        guard !blocks.isEmpty else { return }
        resolver.select?(min(max(0, index), blocks.count - 1))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(snapshot.path).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(resolverText("Conflict %d of %d", blocks.isEmpty ? 0 : min(resolver.selectedBlock + 1, blocks.count), blocks.count)).font(.caption).foregroundStyle(.secondary)
                Button { selectConflict(resolver.selectedBlock - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(blocks.isEmpty || resolver.selectedBlock <= 0)
                    .help(resolverText("Previous conflict")).accessibilityLabel(resolverText("Previous conflict"))
                Button { selectConflict(resolver.selectedBlock + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(blocks.isEmpty || resolver.selectedBlock >= blocks.count - 1)
                    .help(resolverText("Next conflict")).accessibilityLabel(resolverText("Next conflict"))
                Menu {
                    Toggle(L10n.text("wrap", table: "DiffControls"), isOn: $wraps)
                    Toggle(L10n.text("lineNumbers", table: "DiffControls"), isOn: $numbers)
                    Toggle(L10n.text("syncScroll", table: "DiffControls"), isOn: $synchronized)
                } label: { Image(systemName: "slider.horizontal.3") }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6).rayGitChrome()
            Divider()
            ComparisonEditor(columns: [column("ours", "Ours (Stage 2)", snapshot.ours), column("worktree", "Merge Result (Read-only)", snapshot.worktree), column("theirs", "Theirs (Stage 3)", snapshot.theirs)], wrapLines: wraps, showLineNumbers: numbers, synchronizeScroll: synchronized, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: snapshot.path, resolver: resolver)
            if let base = snapshot.base {
                Divider()
                CompareBasePanel(column: column("base", "Base (Stage 1)", base), wraps: wraps, numbers: numbers, expanded: $showBase)
            }
        }.onChange(of: snapshot.path) { _, _ in resolver.selectedBlock = 0 }
    }
}
