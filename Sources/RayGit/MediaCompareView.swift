import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

private func advancedText(_ key: String) -> String { L10n.text(key, table: "AdvancedDiff") }

struct MediaCompareView: View {
    let snapshot: FileComparisonSnapshot
    @State private var overlay = false
    @State private var opacity = 0.5
    @State private var left = "head"
    @State private var right = "worktree"
    static func supports(_ snapshot: FileComparisonSnapshot) -> Bool {
        [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap { $0 }.contains { content in content.data.flatMap(NSImage.init(data:)) != nil }
    }
    private var revisions: [(String, String, FileRevisionContent)] {
        var values = [("head", "HEAD", snapshot.head), ("index", advancedText("index"), snapshot.index), ("worktree", advancedText("worktree"), snapshot.worktree)]
        for (id, content) in [("base", snapshot.base), ("ours", snapshot.ours), ("theirs", snapshot.theirs)] { if let content { values.append((id, advancedText(id), content)) } }
        return values.filter { $0.2.data.flatMap(NSImage.init(data:)) != nil }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle(compareExtra("imageOverlay"), isOn: $overlay).toggleStyle(.checkbox)
                Picker(advancedText("leftRevision"), selection: $left) { ForEach(revisions, id: \.0) { Text($0.1).tag($0.0) } }.frame(width: 160)
                Picker(advancedText("rightRevision"), selection: $right) { ForEach(revisions, id: \.0) { Text($0.1).tag($0.0) } }.frame(width: 160)
                if overlay { Slider(value: $opacity, in: 0...1).frame(width: 160) }
                Spacer()
                ExternalComparisonButton(snapshot: snapshot)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            if overlay {
                ZStack {
                    if let data = revisions.first(where: { $0.0 == left })?.2.data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit() }
                    if let data = revisions.first(where: { $0.0 == right })?.2.data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().opacity(opacity) }
                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(revisions.filter { $0.0 == left || $0.0 == right }, id: \.0) { revision in
                        VStack(spacing: 8) {
                            Text(revision.1).font(.system(size: 12, weight: .semibold))
                            if let data = revision.2.data, let image = NSImage(data: data) {
                                Text("\(Int(image.size.width)) × \(Int(image.size.height)) · \(data.count) B").font(.caption).foregroundStyle(.secondary)
                                Image(nsImage: image).resizable().scaledToFit()
                            } else { ContentUnavailableView(advancedText("noImage"), systemImage: "photo") }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(12)
            }
        }.onAppear {
            if !revisions.contains(where: { $0.0 == left }) { left = revisions.first?.0 ?? "head" }
            if !revisions.contains(where: { $0.0 == right }) { right = revisions.last?.0 ?? left }
        }
    }
}

struct PagedComparisonView: View {
    let snapshot: FileComparisonSnapshot
    var layout = "automatic"
    var baseline = "index"
    var showBase = false
    @State private var page = 0
    private var revisions: [(String, String, FileRevisionContent)] {
        let three = layout == "three" || (layout == "automatic" && snapshot.presentation.layout == .three)
        if snapshot.isConflict {
            let left = showBase ? ("base", advancedText("base"), snapshot.base) : ("ours", compareText("Ours (HEAD)"), snapshot.ours)
            let result = ("worktree", advancedText("worktree"), Optional(snapshot.worktree))
            let versions = three ? [left, result, ("theirs", advancedText("theirs"), snapshot.theirs)] : [left, result]
            return versions.compactMap { id, title, content in content.map { (id, title, $0) } }
        }
        let working = ("worktree", advancedText("worktree"), snapshot.worktree)
        if three { return [("head", "HEAD", snapshot.head), working, ("index", advancedText("index"), snapshot.index)] }
        let head = layout == "automatic" ? snapshot.presentation.leftRevision == .head : baseline == "head"
        return [head ? ("head", "HEAD", snapshot.head) : ("index", advancedText("index"), snapshot.index), working]
    }
    private var columns: [ComparisonEditorColumn] {
        revisions.map { id, title, revision in
            let content = revision.text.map { TextPager.page($0, index: page) }
            return ComparisonEditorColumn(id: id, title: title, text: content?.text ?? "", isEditable: false, message: revision.text == nil ? revision.unavailableReason : nil, firstLine: content?.firstLine ?? 1)
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
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            ComparisonEditor(columns: columns, wrapLines: false, showLineNumbers: true, synchronizeScroll: true, search: "", navigation: 0, changeNavigation: 0, onEdit: { _, _ in }, languagePath: snapshot.path)
        }
    }
}

struct ExternalComparisonButton: View {
    let snapshot: FileComparisonSnapshot
    var resultText: String? = nil
    var resultEncoding: ComparisonEncoding? = nil
    var onResult: ((String) -> Void)? = nil
    @State private var error: String?
    @State private var left = "head"
    @State private var right = "worktree"
    @State private var base = "base"
    @State private var settings = false
    @AppStorage("externalComparisonArguments") private var argumentsJSON = "[\"{left}\", \"{right}\"]"
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
            Picker(compareExtra("baseVersion"), selection: $base) { ForEach(revisions, id: \.0) { Text($0.1).tag($0.0) } }
            Button(compareExtra("toolArguments")) { settings = true }
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
        .menuStyle(.borderlessButton).fixedSize()
        .onAppear { if !revisions.contains(where: { $0.0 == base }) { base = revisions.first?.0 ?? "head" } }
        .sheet(isPresented: $settings) {
            VStack {
                ExternalToolsPreferencesView()
                HStack { Spacer(); Button(compareExtra("done")) { settings = false }.keyboardShortcut(.defaultAction) }.padding()
            }.frame(width: 600, height: 440)
        }
        .alert(advancedText("external"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func launch(_ executable: URL) {
        guard let a = revisions.first(where: { $0.0 == left }), let b = revisions.first(where: { $0.0 == right }) else { return }
        do {
            let template = try ExternalDiffArguments.parse(argumentsJSON)
            var contents = ["left": a.2, "right": b.2]
            if let common = revisions.first(where: { $0.0 == base }) { contents["base"] = common.2 }
            contents["result"] = snapshot.worktree
            try ExternalComparison.launch(executable: executable, path: snapshot.path, contents: contents, template: template, resultText: resultText, resultEncoding: resultEncoding, onResult: onResult)
        } catch { self.error = compareExtra(error.localizedDescription) }
    }
}

private enum ExternalComparison {
    static func launch(executable: URL, path: String, contents: [String: FileRevisionContent], template: [String], resultText: String?, resultEncoding: ComparisonEncoding?, onResult: ((String) -> Void)?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raygit-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files: [String: String] = [:]
        do {
            let used = Set(["left", "right", "base", "result"].filter { key in template.contains(where: { $0.contains("{" + key + "}") }) })
            for key in used {
                guard let content = contents[key], !content.exists || content.data != nil else { throw GitError("Revision content is unavailable.") }
                let file = directory.appendingPathComponent(key + "-" + URL(fileURLWithPath: path).lastPathComponent)
                let data = key == "result" && resultText != nil ? try ComparisonTextDecoder.encode(resultText!, format: ComparisonTextDecoder.format(of: content.data ?? Data(), encoding: resultEncoding)) : content.data ?? Data()
                try data.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: key == "result" ? 0o600 : 0o444], ofItemAtPath: file.path)
                files[key] = file.path
            }
            let paths = try ExternalDiffArguments.expand(template, files: files)
            let process = Process()
            if executable.pathExtension == "app" {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-W", "-a", executable.path, "--args"] + paths
            } else { process.executableURL = executable; process.arguments = paths }
            let resultPath = files["result"]
            process.terminationHandler = { process in
                defer { try? FileManager.default.removeItem(at: directory) }
                if process.terminationStatus == 0, let resultPath, let attrs = try? FileManager.default.attributesOfItem(atPath: resultPath), (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 2 * 1024 * 1024, let data = try? Data(contentsOf: URL(fileURLWithPath: resultPath)), let text = ComparisonTextDecoder.decode(data).text ?? resultEncoding.flatMap({ ComparisonTextDecoder.decode(data, as: $0) }) {
                    DispatchQueue.main.async { onResult?(text.replacingOccurrences(of: "\r\n", with: "\n")) }
                }
            }
            try process.run()
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
