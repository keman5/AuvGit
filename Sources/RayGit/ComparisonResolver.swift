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
        HStack(spacing: 8) {
            Image(systemName: blocks.isEmpty && !malformed ? "checkmark.circle.fill" : "arrow.triangle.merge")
                .foregroundStyle(blocks.isEmpty && !malformed ? Color.green : Color.orange)
            Text(malformed ? resolverText("Incomplete conflict markers — repair the result manually") : (blocks.isEmpty ? resolverText("No unresolved conflicts") : resolverText("Conflict %d of %d", current + 1, blocks.count))).fontWeight(.semibold)
            Button { state.select?((current + blocks.count - 1) % blocks.count) } label: { Image(systemName: "chevron.up") }.help(resolverText("Previous conflict"))
            Button { state.select?((current + 1) % blocks.count) } label: { Image(systemName: "chevron.down") }.help(resolverText("Next conflict"))
            Divider().frame(height: 16)
            choice("Use Ours", .ours)
            choice("Use Theirs", .theirs)
            choice("Ours → Theirs", .oursThenTheirs)
            choice("Theirs → Ours", .theirsThenOurs)
            if blocks.indices.contains(current), blocks[current].base != nil { choice("Use Base", .base) }
            Spacer(minLength: 0)
            if blocks.indices.contains(current) { Text(resolverText("Lines %d–%d", blocks[current].startLine, blocks[current].endLine)).foregroundStyle(.secondary) }
        }.disabled(blocks.isEmpty || !enabled).controlSize(.small)
    }
    private func choice(_ key: String, _ side: ConflictDraft.Side) -> some View {
        Button { state.accept?(side, current) } label: {
            HStack(spacing: 4) {
                if side == .ours { Image(systemName: "arrow.right.square.fill").foregroundStyle(Color.blue) }
                if side == .theirs { Image(systemName: "arrow.left.square.fill").foregroundStyle(Color.purple) }
                Text(resolverText(key))
            }
        }.help(resolverText("Apply to the current conflict only"))
    }
}
