import SwiftUI
import GitCore
import AuvGitLocalization

/// Uses the same stage-aware surface as the resolver, with no editing callbacks.
struct WorkspaceConflictPreview: View {
    let snapshot: FileComparisonSnapshot
    var repositoryPath: String = ""
    var onOpenEditorSearch: ((ComparisonSearchOptions, String) -> Void)? = nil
    var onOpenEditorLine: ((String, Int) -> Void)? = nil
    @StateObject private var blockCache = WorkspaceConflictBlockCache()
    @StateObject private var navigationCommands = ComparisonEditingCommands()
    @State private var compact = false
    @State private var searchOptions = ComparisonSearchOptions()
    @State private var replacement = ""
    @State private var showSearch = false
    @State private var navigation = 0
    @State private var changeNavigation = 0
    @AppStorage("editor.wrapLines") private var wraps = false
    @AppStorage("editor.showLineNumbers") private var numbers = true
    @AppStorage("editor.synchronizeScroll") private var synchronized = true
    @State private var showBase = false
    @StateObject private var resolver = ComparisonResolverState()

    private var blocks: [ConflictDraft.Block] { blockCache.blocks(in: snapshot.worktree.text ?? "") }
    private func column(_ id: String, _ title: String, _ content: FileRevisionContent?) -> ComparisonEditorColumn {
        ComparisonEditorColumn(id: id, title: URL(fileURLWithPath: snapshot.path).lastPathComponent + " — " + compareText(title), text: content?.text ?? "", isEditable: false,
            message: content?.text != nil ? nil : content?.unavailableReason.map { compareText($0) } ?? compareText("File does not exist in this version"), detail: content?.objectID.map { String($0.prefix(8)) } ?? designCompareText("Read-only"))
    }
    private var columns: [ComparisonEditorColumn] {
        [column("ours", "Ours (Stage 2)", snapshot.ours), column("worktree", "Merge Result (Read-only)", snapshot.worktree), column("theirs", "Theirs (Stage 3)", snapshot.theirs)]
    }
    private var searchError: String? {
        if case .failure(let error) = ComparisonSearch.matches(in: "", options: searchOptions) { return comparisonSearchText("Invalid regular expression") + ": " + error.localizedDescription }
        return nil
    }
    private func selectConflict(_ index: Int) {
        guard !blocks.isEmpty else { return }
        resolver.select?(min(max(0, index), blocks.count - 1))
    }
    private func performShortcut(_ command: ShortcutCommand) -> Bool {
        switch command {
        case .compareFind: showSearch = true
        case .compareFindNext, .compareFindPrevious:
            compact = false; navigation += command == .compareFindNext ? 1 : -1
        case .compareNextChange, .comparePreviousChange:
            guard !compact else { return false }; changeNavigation += command == .compareNextChange ? 1 : -1
        case .compareNextConflict, .comparePreviousConflict:
            guard !compact else { return false }; selectConflict(resolver.selectedBlock + (command == .compareNextConflict ? 1 : -1))
        case .compareCompact: compact.toggle()
        case .compareWrap: wraps.toggle()
        case .compareLines: numbers.toggle()
        case .compareSync: synchronized.toggle()
        default: return false
        }
        return true
    }
    var body: some View {
        let blocks = self.blocks
        VStack(spacing: 0) {
            HStack {
                Text(snapshot.path).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(resolverText("Conflict %d of %d", blocks.isEmpty ? 0 : min(resolver.selectedBlock + 1, blocks.count), blocks.count)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 2) {
                    Button { selectConflict(resolver.selectedBlock - 1) } label: { ComparisonToolbarIcon(name: "chevron.up") }.buttonStyle(ComparisonToolbarButtonStyle())
                        .disabled(blocks.isEmpty || resolver.selectedBlock <= 0)
                        .help(resolverText("Previous conflict")).accessibilityLabel(resolverText("Previous conflict"))
                    Button { selectConflict(resolver.selectedBlock + 1) } label: { ComparisonToolbarIcon(name: "chevron.down") }.buttonStyle(ComparisonToolbarButtonStyle())
                        .disabled(blocks.isEmpty || resolver.selectedBlock >= blocks.count - 1)
                        .help(resolverText("Next conflict")).accessibilityLabel(resolverText("Next conflict"))
                }
                Button { showSearch.toggle() } label: { ComparisonToolbarIcon(name: "magnifyingglass") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(comparisonSearchText("Search and replace")).accessibilityLabel(comparisonSearchText("Search and replace"))
                    .popover(isPresented: $showSearch) {
                        ComparisonSearchPopover(options: $searchOptions, replacement: $replacement, matchCount: navigationCommands.searchTotal, matchIndex: navigationCommands.searchCurrent,
                            onNavigate: { forward in compact = false; navigation += forward ? 1 : -1 },
                            onOpenEditor: onOpenEditorSearch.map { action in { action(searchOptions, replacement) } }, error: searchError, onClose: { showSearch = false; DispatchQueue.main.async { navigationCommands.focusEditor() } })
                    }
                Button { compact.toggle() } label: { ComparisonToolbarIcon(name: "line.3.horizontal.decrease") }.buttonStyle(ComparisonToolbarButtonStyle())
                    .help(comparisonSearchText("Compact differences")).accessibilityLabel(comparisonSearchText("Compact differences"))
                Menu {
                    Toggle(L10n.text("wrap", table: "DiffControls"), isOn: $wraps)
                    Toggle(L10n.text("lineNumbers", table: "DiffControls"), isOn: $numbers)
                    Toggle(L10n.text("syncScroll", table: "DiffControls"), isOn: $synchronized)
                } label: { ComparisonToolbarIcon(name: "slider.horizontal.3") }.buttonStyle(ComparisonToolbarButtonStyle())
            }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22)).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 4).auvGitChrome()
            Divider()
            ZStack {
                ComparisonEditor(columns: columns, wrapLines: wraps, showLineNumbers: numbers, synchronizeScroll: synchronized, search: searchOptions.query, navigation: navigation, changeNavigation: changeNavigation, onEdit: { _, _ in }, languagePath: snapshot.path, resolver: resolver, editingCommands: navigationCommands, scrollsToFirstChangeOnOpen: true, searchOptions: searchOptions, readOnlyDocumentIdentity: repositoryPath + "/" + snapshot.path)
                    .opacity(compact ? 0 : 1).allowsHitTesting(!compact).accessibilityHidden(compact)
                if compact { CompactComparisonView(columns: columns, conflict: true, wraps: wraps, numbers: numbers, onReturnToEditor: { compact = false }, onRevealLine: { id, line in
                    if let onOpenEditorLine { onOpenEditorLine(id, line) }
                    else { compact = false; DispatchQueue.main.async { navigationCommands.revealLine(paneID: id, number: line) } }
                }) }
            }
            if let base = snapshot.base {
                Divider()
                CompareBasePanel(column: column("base", "Base (Stage 1)", base), wraps: wraps, numbers: numbers, expanded: $showBase)
            }
        }.background(ComparisonKeyboardRegion(action: performShortcut)).onChange(of: snapshot.path) { _, _ in resolver.selectedBlock = 0 }
    }
}

private final class WorkspaceConflictBlockCache: ObservableObject {
    private var text: String?
    private var cached: [ConflictDraft.Block] = []
    func blocks(in value: String) -> [ConflictDraft.Block] {
        if text != value { text = value; cached = ConflictDraft.blocks(in: value) }
        return cached
    }
}
