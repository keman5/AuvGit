import SwiftUI
import GitCore
import RayGitLocalization

func resolverText(_ key: String, _ arguments: CVarArg...) -> String {
    L10n.text(key, table: "Resolver", arguments: arguments)
}

final class ComparisonResolverState: ObservableObject {
    @Published var selectedBlock = 0
    var select: ((Int) -> Void)?
    var accept: ((ConflictDraft.Side, Int) -> Void)?
}

struct ConflictResolverToolbar: View {
    @ObservedObject var state: ComparisonResolverState
    let blocks: [ConflictDraft.Block]
    let enabled: Bool
    let malformed: Bool
    private var current: Int { min(max(0, state.selectedBlock), max(0, blocks.count - 1)) }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: blocks.isEmpty && !malformed ? "checkmark.circle.fill" : "arrow.triangle.merge")
                .foregroundStyle(blocks.isEmpty && !malformed ? Color.green : Color.orange)
            Text(malformed ? resolverText("Incomplete conflict markers — repair the result manually") : (blocks.isEmpty ? resolverText("No unresolved conflicts") : resolverText("Conflict %d of %d", current + 1, blocks.count)))
                .fontWeight(.semibold).lineLimit(1).frame(maxWidth: 190, alignment: .leading)
            HStack(spacing: 2) {
                Button { state.select?((current + blocks.count - 1) % blocks.count) } label: { ComparisonToolbarIcon(name: "chevron.up") }.buttonStyle(ComparisonToolbarButtonStyle()).help(resolverText("Previous conflict")).accessibilityLabel(resolverText("Previous conflict")).disabled(blocks.isEmpty || !enabled)
                Button { state.select?((current + 1) % blocks.count) } label: { ComparisonToolbarIcon(name: "chevron.down") }.buttonStyle(ComparisonToolbarButtonStyle()).help(resolverText("Next conflict")).accessibilityLabel(resolverText("Next conflict")).disabled(blocks.isEmpty || !enabled)
            }.buttonStyle(ToolbarRowButtonStyle(minimumWidth: 22))
            Divider().frame(height: 16)
            choice("Use Ours", .ours)
            choice("Use Theirs", .theirs)
            Menu {
                Button(resolverText("Ours → Theirs")) { state.accept?(.oursThenTheirs, current) }
                Button(resolverText("Theirs → Ours")) { state.accept?(.theirsThenOurs, current) }
                if blocks.indices.contains(current), blocks[current].base != nil {
                    Divider()
                    Button(resolverText("Use Base")) { state.accept?(.base, current) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24).contentShape(Rectangle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 24)
                .help(resolverText("Apply to the current conflict only")).accessibilityLabel(resolverText("Apply to the current conflict only")).disabled(blocks.isEmpty || !enabled)
            Spacer(minLength: 0)
            if blocks.indices.contains(current) { Text(resolverText("Lines %d–%d", blocks[current].startLine, blocks[current].endLine)).foregroundStyle(.secondary) }
        }.buttonStyle(ToolbarRowButtonStyle()).font(.system(size: 11)).controlSize(.small)
    }
    private func choice(_ key: String, _ side: ConflictDraft.Side) -> some View {
        Button { state.accept?(side, current) } label: {
            HStack(spacing: 4) {
                if side == .ours { Image(systemName: "arrow.right").foregroundStyle(Color.blue) }
                if side == .theirs { Image(systemName: "arrow.left").foregroundStyle(Color.green) }
                if side == .oursThenTheirs { Image(systemName: "chevron.forward.2") }
                if side == .theirsThenOurs { Image(systemName: "chevron.backward.2") }
                Text(resolverText(key))
            }
        }.buttonStyle(ToolbarRowButtonStyle()).foregroundStyle(side == .theirs ? Color.green : Color.blue)
            .help(resolverText("Apply to the current conflict only")).disabled(blocks.isEmpty || !enabled)
    }
}
