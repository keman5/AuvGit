import SwiftUI
import GitCore

struct PartialStagingPane: View {
    @ObservedObject var session: FileCompareSession
    @State private var selected: Set<Int> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(compareText("Changes"), selection: $session.unstagePartial) {
                    Text(compareText("Unstaged")).tag(false)
                    Text(compareText("Staged")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer(minLength: 8)
                Button(compareText(session.unstagePartial ? "Unstage Selected Lines" : "Stage Selected Lines")) { Task { await session.applySelection(selected); selected = [] } }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || session.isBusy || session.isDirty || session.partial?.unavailableReason != nil)
                Button(compareText(session.unstagePartial ? "Unstage File" : session.snapshot?.isConflict == true ? "Save & Mark Resolved" : "Stage File")) { Task { if session.unstagePartial { await session.unstageFile() } else { await session.stage(resolve: false) } } }.disabled(session.isBusy || session.isDirty)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            if session.isDirty { Text(compareText("Save drafts before partial staging")).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8) }
            if let reason = session.partial?.unavailableReason { Text(compareText(reason)).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.partial?.hunks ?? []) { hunk in
                        HStack(spacing: 8) {
                            Text(hunk.header).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button(compareText(session.unstagePartial ? "Unstage Hunk" : "Stage Hunk")) { Task { await session.applySelection(Set(hunk.lines.filter(\.isChange).map(\.id))); selected = [] } }
                                .disabled(session.isBusy || session.isDirty || session.partial?.unavailableReason != nil)
                        }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(Color.accentColor.opacity(0.1))
                        ForEach(hunk.lines) { line in
                            HStack(spacing: 8) {
                                if line.isChange { Toggle("", isOn: Binding(get: { selected.contains(line.id) }, set: { if $0 { selected.insert(line.id) } else { selected.remove(line.id) } })).labelsHidden().toggleStyle(.checkbox) }
                                else { Color.clear.frame(width: 16) }
                                Text(line.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 12).padding(.vertical, 2).background(line.text.hasPrefix("+") ? Color.green.opacity(0.1) : line.text.hasPrefix("-") ? Color.red.opacity(0.1) : Color.clear)
                        }
                    }
                }
            }
        }.onChange(of: session.partial?.file.index.data) { _, _ in selected = [] }.onChange(of: session.partial?.file.worktree.data) { _, _ in selected = [] }.onChange(of: session.unstagePartial) { _, _ in selected = []; Task { await session.reloadPatch() } }
    }
}
