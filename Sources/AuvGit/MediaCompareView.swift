import SwiftUI
import AppKit
import ImageIO
import GitCore
import AuvGitLocalization

private func advancedText(_ key: String) -> String { L10n.text(key, table: "AdvancedDiff") }

enum StaticImagePreview {
    static let maximumPixels = 64_000_000
    private static let images: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.countLimit = 12; cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    static func dimensions(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return (width.intValue, height.intValue)
    }
    static func image(_ data: Data) -> NSImage? {
        guard data.count <= FileComparisonLimits.previewBytes else { return nil }
        let key = data as NSData
        if let image = images.object(forKey: key) { return image }
        guard let image = decode(data) else { return nil }
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        images.setObject(image, forKey: key, cost: data.count + pixels * 4)
        return image
    }
    private static func decode(_ data: Data) -> NSImage? {
        if let document = SafeStaticDocument.image(data) { return document }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "com.compuserve.gif", "public.tiff", "com.microsoft.bmp", "org.webmproject.webp", "public.heic", "public.heif", "com.apple.icns"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= Double(maximumPixels),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct FileContentSummary: View {
    let content: FileRevisionContent
    private func text(_ key: String) -> String { L10n.text(key, table: "StaticPreview") }
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: content.exists ? "doc.zipper" : "doc").font(.system(size: 30)).foregroundStyle(.secondary)
            Text(text(!content.exists ? "Revision has no file" : content.exceedsPreviewLimit ? "File exceeds preview limit" : "No supported static preview"))
            if let size = content.byteCount ?? content.data?.count { Text("\(size.formatted()) " + text("bytes")).monospacedDigit() }
            if let count = content.characterCount { Text("\(count.formatted()) " + text("characters")).monospacedDigit() }
            else if content.exists { Text(text("Character count unavailable for binary or unread content")).font(.caption).foregroundStyle(.secondary) }
            if content.exceedsPreviewLimit { Text(text("Comparison skipped above 32 MiB; file content was not loaded")).font(.caption).foregroundStyle(.secondary) }
            else if content.exists { Text(text("Supported: PNG, JPEG, GIF, TIFF, BMP, WebP, HEIC, PDF first page and safe SVG")).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).textSelection(.enabled)
    }
}

struct StaticComparisonView: View {
    let snapshot: FileComparisonSnapshot
    var showsControls = true
    private var summaries: [(String, FileRevisionContent)] {
        if snapshot.isConflict {
            return [(compareText("Ours (HEAD)"), snapshot.ours ?? snapshot.head), (advancedText("worktree"), snapshot.worktree), (advancedText("theirs"), snapshot.theirs ?? snapshot.index)]
        }
        let labels = MediaCompareView.previewLabels(snapshot)
        return [(labels.0, snapshot.previewTarget != nil || snapshot.presentation.leftRevision == .head ? snapshot.head : snapshot.index), (labels.1, snapshot.worktree)]
    }
    var body: some View {
        if MediaCompareView.supports(snapshot) { MediaCompareView(snapshot: snapshot, showsControls: showsControls) }
        else {
            HStack(spacing: 1) {
                ForEach(Array(summaries.enumerated()), id: \.offset) { _, revision in
                    VStack { Text(revision.0).font(.caption); FileContentSummary(content: revision.1) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct MediaCompareView: View {
    let snapshot: FileComparisonSnapshot
    var showsControls = true
    @State private var overlay = false
    @State private var opacity = 0.5
    @State private var left = "head"
    @State private var right = "worktree"
    static func supports(_ snapshot: FileComparisonSnapshot) -> Bool {
        [snapshot.head, snapshot.index, snapshot.worktree, snapshot.base, snapshot.ours, snapshot.theirs].compactMap { $0 }.contains { content in content.data.flatMap(StaticImagePreview.image) != nil }
    }
    static func previewLabels(_ snapshot: FileComparisonSnapshot) -> (String, String) {
        switch snapshot.previewTarget {
        case .worktree: return (advancedText("index"), advancedText("worktree"))
        case .staged: return ("HEAD", advancedText("index"))
        case .commit: return (L10n.text("Parent revision", table: "StaticPreview"), L10n.text("Commit revision", table: "StaticPreview"))
        case nil: return (L10n.text("Original", table: "StaticPreview"), L10n.text("Modified", table: "StaticPreview"))
        }
    }
    private var revisions: [(String, String, FileRevisionContent)] {
        if snapshot.previewTarget != nil {
            let labels = Self.previewLabels(snapshot)
            return [("head", labels.0, snapshot.head), ("worktree", labels.1, snapshot.worktree)]
        }
        var values = [("head", "HEAD", snapshot.head), ("index", advancedText("index"), snapshot.index), ("worktree", advancedText("worktree"), snapshot.worktree)]
        for (id, content) in [("base", snapshot.base), ("ours", snapshot.ours), ("theirs", snapshot.theirs)] { if let content { values.append((id, advancedText(id), content)) } }
        return values.filter { $0.2.exists || $0.0 == "head" || $0.0 == "worktree" }
    }
    var body: some View {
        VStack(spacing: 0) {
            if showsControls {
            HStack(spacing: 8) {
                Toggle(compareExtra("imageOverlay"), isOn: $overlay).toggleStyle(.checkbox)
                Picker(advancedText("leftRevision"), selection: $left) { ForEach(revisions, id: \.0) { Text($0.1).tag($0.0) } }.frame(width: 160)
                Picker(advancedText("rightRevision"), selection: $right) { ForEach(revisions, id: \.0) { Text($0.1).tag($0.0) } }.frame(width: 160)
                if overlay { Slider(value: $opacity, in: 0...1).frame(width: 160) }
                Spacer()
                ExternalComparisonButton(snapshot: snapshot)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            Divider()
            }
            if overlay {
                ZStack {
                    if let data = revisions.first(where: { $0.0 == left })?.2.data, let image = StaticImagePreview.image(data) { Image(nsImage: image).resizable().scaledToFit() }
                    if let data = revisions.first(where: { $0.0 == right })?.2.data, let image = StaticImagePreview.image(data) { Image(nsImage: image).resizable().scaledToFit().opacity(opacity) }
                }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(revisions.filter { $0.0 == left || $0.0 == right }, id: \.0) { revision in
                        VStack(spacing: 8) {
                            Text(revision.1).font(.system(size: 12, weight: .semibold))
                            if let data = revision.2.data, let image = StaticImagePreview.image(data) {
                                let dimensions = StaticImagePreview.dimensions(data)
                                Text("\(dimensions?.0 ?? Int(image.size.width)) × \(dimensions?.1 ?? Int(image.size.height)) · \(data.count) B").font(.caption).foregroundStyle(.secondary)
                                if let pages = SafeStaticDocument.pdfPageCount(data) { Text(L10n.text("PDF page 1 of %@", table: "StaticPreview", arguments: [String(pages)])).font(.caption).foregroundStyle(.secondary) }
                                Image(nsImage: image).resizable().scaledToFit()
                            } else { FileContentSummary(content: revision.2) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.padding(12)
            }
        }.onAppear {
            if snapshot.isConflict { left = "ours"; right = "worktree" }
            if !revisions.contains(where: { $0.0 == left }) { left = revisions.first?.0 ?? "head" }
            if !revisions.contains(where: { $0.0 == right }) { right = revisions.last?.0 ?? left }
        }
    }
}


struct ExternalComparisonButton: View {
    let snapshot: FileComparisonSnapshot
    var iconOnly = false
    var resultText: String? = nil
    var resultEncoding: ComparisonEncoding? = nil
    var onResult: ((String) -> Void)? = nil
    @State private var error: String?
    @State private var left = "head"
    @State private var right = "worktree"
    @State private var base = "base"
    @State private var settings = false
    @AppStorage("externalComparisonArguments") private var argumentsJSON = ExternalComparisonConfiguration.compareArguments
    @AppStorage("externalMergeArguments") private var mergeArgumentsJSON = ExternalComparisonConfiguration.mergeArguments
    @AppStorage("externalComparisonExecutable") private var executablePath = ExternalComparisonConfiguration.defaultExecutable
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
            if !executablePath.isEmpty {
                Button(advancedText("launchExternal")) { launch(URL(fileURLWithPath: executablePath)) }
                if onResult != nil, snapshot.base != nil {
                    Button(editorPrefsText("Merge result")) { launch(URL(fileURLWithPath: executablePath), merging: true) }
                }
            }
            Button(advancedText("chooseExternal")) {
                let panel = NSOpenPanel()
                panel.title = advancedText("chooseExternal"); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
                if !executablePath.isEmpty { panel.directoryURL = URL(fileURLWithPath: executablePath).deletingLastPathComponent() }
                guard panel.runModal() == .OK, let executable = panel.url else { return }
                executablePath = executable.path
                launch(executable)
            }
        } label: {
            if iconOnly { ComparisonToolbarIcon(name: "arrow.up.forward.square") }
            else { Text(advancedText("external")) }
        }
        .menuStyle(.borderlessButton).menuIndicator(iconOnly ? .hidden : .visible).fixedSize()
        .help(advancedText("external")).accessibilityLabel(advancedText("external"))
        .onAppear { if executablePath.isEmpty { executablePath = ExternalComparisonConfiguration.defaultExecutable }; if snapshot.isConflict { left = "ours"; right = "theirs" }; if !revisions.contains(where: { $0.0 == base }) { base = revisions.first?.0 ?? "head" } }
        .auvGitSheet(isPresented: $settings) {
            VStack {
                ExternalToolsPreferencesView()
                HStack { DialogButton(compareExtra("done"), prominent: true, role: .cancel) { settings = false } }.buttonStyle(AuvGitDialogButtonStyle()).frame(maxWidth: .infinity).padding()
            }.frame(width: 600, height: 560)
        }
        .auvGitAlert(advancedText("external"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { AuvGitAlertButton("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func launch(_ executable: URL, merging: Bool = false) {
        guard let a = revisions.first(where: { $0.0 == left }), let b = revisions.first(where: { $0.0 == right }) else { return }
        do {
            let template = try ExternalDiffArguments.parse(merging ? mergeArgumentsJSON : argumentsJSON)
            var contents = ["left": a.2, "right": b.2]
            if let common = revisions.first(where: { $0.0 == base }) { contents["base"] = common.2 }
            contents["result"] = snapshot.worktree
            try ExternalComparison.launch(executable: ExternalComparisonConfiguration.executable(executable.path), path: snapshot.path, contents: contents, template: template, resultText: resultText, resultEncoding: resultEncoding, onResult: onResult)
        } catch { self.error = compareExtra(OperationFailure.message(error)) }
    }
}

private enum ExternalComparison {
    static func launch(executable: URL, path: String, contents: [String: FileRevisionContent], template: [String], resultText: String?, resultEncoding: ComparisonEncoding?, onResult: ((String) -> Void)?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("auvgit-compare-\(UUID().uuidString)", isDirectory: true)
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
