import SwiftUI
import GitCore

struct PartialStagingPane: View {
    @ObservedObject var session: FileCompareSession
    @State private var selected: Set<Int> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(compareText("Changes"), selection: $session.unstagePartial) {
                    Text(compareText("Unstaged")).tag(false)
                    Text(compareText("Staged")).tag(true)
                }.pickerStyle(.segmented).frame(width: 220)
                Button(compareText(session.unstagePartial ? "Unstage Selected Lines" : "Stage Selected Lines")) { Task { await session.applySelection(selected); selected = [] } }
                    .disabled(selected.isEmpty || session.isBusy || session.isDirty || session.partial?.unavailableReason != nil)
                Button(compareText(session.unstagePartial ? "Unstage File" : "Stage File")) { Task { if session.unstagePartial { await session.unstageFile() } else { await session.stage(resolve: false) } } }.disabled(session.isBusy || session.isDirty)
                Spacer()
                if session.isDirty { Text(compareText("Save drafts before partial staging")).foregroundStyle(.orange) }
            }.padding(8)
            if let reason = session.partial?.unavailableReason { Text(compareText(reason)).foregroundStyle(.orange).padding(8) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.partial?.hunks ?? []) { hunk in
                        HStack {
                            Text(hunk.header).font(.system(.caption, design: .monospaced))
                            Spacer()
                            Button(compareText(session.unstagePartial ? "Unstage Hunk" : "Stage Hunk")) { Task { await session.applySelection(Set(hunk.lines.filter(\.isChange).map(\.id))); selected = [] } }
                                .disabled(session.isBusy || session.isDirty || session.partial?.unavailableReason != nil)
                        }.padding(8).background(Color.accentColor.opacity(0.1))
                        ForEach(hunk.lines) { line in
                            HStack(spacing: 6) {
                                if line.isChange { Toggle("", isOn: Binding(get: { selected.contains(line.id) }, set: { if $0 { selected.insert(line.id) } else { selected.remove(line.id) } })).labelsHidden().toggleStyle(.checkbox) }
                                else { Color.clear.frame(width: 16) }
                                Text(line.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }.padding(.horizontal, 8).background(line.text.hasPrefix("+") ? Color.green.opacity(0.1) : line.text.hasPrefix("-") ? Color.red.opacity(0.1) : Color.clear)
                        }
                    }
                }
            }
        }.onChange(of: session.unstagePartial) { _, _ in selected = []; Task { await session.reloadPatch() } }
    }
}
