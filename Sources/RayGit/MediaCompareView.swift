import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

private func advancedText(_ key: String) -> String { L10n.text(key, table: "AdvancedDiff") }

struct MediaCompareView: View {
    let snapshot: FileComparisonSnapshot
    @State private var overlay = false
    @State private var opacity = 0.5
    static func supports(_ snapshot: FileComparisonSnapshot) -> Bool {
        [snapshot.head, snapshot.index, snapshot.worktree].contains { content in content.data.flatMap(NSImage.init(data:)) != nil }
    }
    private var revisions: [(String, FileRevisionContent)] { [("HEAD", snapshot.head), (advancedText("index"), snapshot.index), (advancedText("worktree"), snapshot.worktree)] }
    var body: some View {
        VStack {
            HStack {
                Toggle(advancedText("overlay"), isOn: $overlay).toggleStyle(.switch)
                if overlay { Slider(value: $opacity, in: 0...1).frame(width: 160) }
                Spacer()
                ExternalComparisonButton(snapshot: snapshot)
            }.padding(10)
            if overlay {
                ZStack {
                    if let data = snapshot.head.data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
                    if let data = snapshot.worktree.data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().opacity(opacity) }
                }.padding()
            } else {
                HStack(alignment: .top) {
                    ForEach(Array(revisions.enumerated()), id: \.offset) { _, revision in
                        VStack {
                            Text(revision.0).font(.headline)
                            if let data = revision.1.data, let image = NSImage(data: data) {
                                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(data.count) B").font(.caption).foregroundStyle(.secondary)
                                Image(nsImage: image).resizable().scaledToFit()
                            } else { ContentUnavailableView(advancedText("noImage"), systemImage: "photo") }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding()
            }
        }
    }
}

struct PagedComparisonView: View {
    let snapshot: FileComparisonSnapshot
    @State private var page = 0
    private var revisions: [(String, String, FileRevisionContent)] {
        if snapshot.isConflict {
            return [("base", advancedText("base"), snapshot.base), ("ours", advancedText("ours"), snapshot.ours), ("theirs", advancedText("theirs"), snapshot.theirs), ("worktree", advancedText("worktree"), snapshot.worktree)].compactMap { id, title, content in content.map { (id, title, $0) } }
        }
        return [("head", "HEAD", snapshot.head), ("index", advancedText("index"), snapshot.index), ("worktree", advancedText("worktree"), snapshot.worktree)]
    }
    private var columns: [ComparisonEditorColumn] {
        revisions.map { id, title, revision in
            ComparisonEditorColumn(id: id, title: title, text: revision.text.map { TextPager.page($0, index: page).text } ?? "", isEditable: false, message: revision.text == nil ? revision.unavailableReason : nil)
        }
    }
    private var hasNext: Bool { revisions.contains { $0.2.text.map { TextPager.page($0, index: page).hasNext } ?? false } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(advancedText("pagedReadOnly")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(advancedText("previousPage")) { page = max(0, page - 1) }.disabled(page == 0)
                Text(L10n.text("page", table: "AdvancedDiff", arguments: [page + 1, TextPager.page(snapshot.worktree.text ?? snapshot.head.text ?? "", index: page).firstLine]))
                Button(advancedText("nextPage")) { page += 1 }.disabled(!hasNext)
                ExternalComparisonButton(snapshot: snapshot)
            }.padding(10)
            ComparisonEditor(columns: columns, wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: snapshot.path)
        }
    }
}

struct ExternalComparisonButton: View {
    let snapshot: FileComparisonSnapshot
    @State private var error: String?
    @State private var left = "head"
    @State private var right = "worktree"
    @AppStorage("externalComparisonExecutable") private var executablePath = ""
    private var revisions: [(String, String, FileRevisionContent)] {
        var result = [("head", "HEAD", snapshot.head), ("index", advancedText("index"), snapshot.index), ("worktree", advancedText("worktree"), snapshot.worktree)]
        if let value = snapshot.base { result.append(("base", advancedText("base"), value)) }
        if let value = snapshot.ours { result.append(("ours", advancedText("ours"), value)) }
        if let value = snapshot.theirs { result.append(("theirs", advancedText("theirs"), value)) }
        return result
    }
    var body: some View {
        Menu {
            Picker(advancedText("leftRevision"), selection: $left) { ForEach(revisions, id: \.0) { revision in Text(revision.1).tag(revision.0) } }
            Picker(advancedText("rightRevision"), selection: $right) { ForEach(revisions, id: \.0) { revision in Text(revision.1).tag(revision.0) } }
            if !executablePath.isEmpty { Button(advancedText("launchExternal")) { launch(URL(fileURLWithPath: executablePath)) } }
            Button(advancedText("chooseExternal")) {
                let panel = NSOpenPanel()
                panel.title = advancedText("chooseExternal"); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                if !executablePath.isEmpty { panel.directoryURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent() }
                guard panel.runModal() == .OK, let executable = panel.url else { return }
                executablePath = executable.path
                launch(executable)
            }
        } label: { Text(advancedText("external")) }
        .alert(advancedText("external"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func launch(_ executable: URL) {
        guard let a = revisions.first(where: { $0.0 == left }), let b = revisions.first(where: { $0.0 == right }) else { return }
        do { try ExternalComparison.launch(executable: executable, path: snapshot.path, revisions: [(a.1, a.2), (b.1, b.2)]) } catch { self.error = error.localizedDescription }
    }
}

private enum ExternalComparison {
    static func launch(executable: URL, path: String, revisions: [(String, FileRevisionContent)]) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        do {
            for (index, revision) in revisions.enumerated() {
                let name = revision.0
                let content = revision.1
                guard !content.exists || content.data != nil else { throw GitError(content.unavailableReason ?? "Revision content is unavailable.") }
                let path = directory.appendingPathComponent("\(index)-" + name + "-" + URL(fileURLWithPath: path).lastPathComponent)
                try (content.data ?? Data()).write(to: path)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path.path)
                paths.append(path.path)
            }
            let process = Process()
            if executable.pathExtension == "app" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-W", "-a", executable.path, "--args"] + paths
            } else { process.executableURL = executable; process.arguments = paths }
            process.terminationHandler = { _ in try? FileManager.default.removeItem(at: directory) }
            try process.run()
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
