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
    private var columns: [ComparisonEditorColumn] {
        [("head", "HEAD", snapshot.head), ("index", advancedText("index"), snapshot.index), ("worktree", advancedText("worktree"), snapshot.worktree)].map { id, title, revision in
            ComparisonEditorColumn(id: id, title: title, text: revision.text.map { TextPager.page($0, index: page).text } ?? "", isEditable: false, message: revision.text == nil ? revision.unavailableReason : nil)
        }
    }
    private var hasNext: Bool { [snapshot.head, snapshot.index, snapshot.worktree].contains { $0.text.map { TextPager.page($0, index: page).hasNext } ?? false } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(advancedText("pagedReadOnly")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(advancedText("previousPage")) { page = max(0, page - 1) }.disabled(page == 0)
                Text(L10n.text("page", table: "AdvancedDiff", arguments: [page + 1, page * 500 + 1]))
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
    var body: some View {
        Button(advancedText("external")) {
            let panel = NSOpenPanel()
            panel.title = advancedText("chooseExternal"); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
            if let previous = UserDefaults.standard.string(forKey: "externalComparisonExecutable") { panel.directoryURL = URL(fileURLWithPath: previous).deletingLastPathComponent() }
            guard panel.runModal() == .OK, let executable = panel.url else { return }
            UserDefaults.standard.set(executable.path, forKey: "externalComparisonExecutable")
            do { try ExternalComparison.launch(executable: executable, snapshot: snapshot) } catch { self.error = error.localizedDescription }
        }.alert(advancedText("external"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

private enum ExternalComparison {
    static func launch(executable: URL, snapshot: FileComparisonSnapshot) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        do {
            for (name, revision) in [("HEAD", snapshot.head), ("Worktree", snapshot.worktree)] {
                let path = directory.appendingPathComponent(name + "-" + URL(fileURLWithPath: snapshot.path).lastPathComponent)
                try (revision.data ?? Data()).write(to: path)
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
