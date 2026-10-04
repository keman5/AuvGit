import AppKit
import SwiftUI
import RayGitLocalization

private func shellToolbarText(_ key: String) -> String { L10n.text(key, table: "ShellToolbar") }

struct ShellToolbarCommand: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let enabled: Bool
    let action: () -> Void
}

/// NSToolbar owns configuration only; the shell owns every visible control.
@MainActor
final class BorderlessToolbarModel: NSObject, ObservableObject, NSToolbarDelegate {
    static let defaults = ["pull", "push", "flexibleSpace", "stage", "unstage", "discard", "stash", "applyStash", "flexibleSpace", "refresh", "create", "tools"]
    static let commandIDs = ["pull", "push", "stage", "unstage", "discard", "stash", "applyStash", "refresh", "create", "tools", "open", "fetch", "commit", "newBranch", "network", "tags", "search", "language"]
    @Published private(set) var identifiers: [String] = []
    @Published var showsText = false { didSet { toolbar.displayMode = showsText ? .iconAndLabel : .iconOnly; persist() } }
    @Published var commands: [ShellToolbarCommand] = []
    let toolbar = NSToolbar(identifier: "RayGit.borderlessToolbar.v1")
    private let preference = "window.borderlessToolbar.v1"
    init(original: NSToolbar?) {
        super.init()
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        let saved = UserDefaults.standard.dictionary(forKey: preference)
        let seed = original?.items.compactMap { item -> String? in
            if item.itemIdentifier == .space { return "space" }
            if item.itemIdentifier == .flexibleSpace { return "flexibleSpace" }
            let raw = item.itemIdentifier.rawValue
            return Self.commandIDs.first { raw == $0 || raw.hasSuffix("." + $0) || raw.hasSuffix("-" + $0) || raw.hasSuffix("/" + $0) }
        } ?? []
        identifiers = saved?["items"] as? [String] ?? (seed.isEmpty ? Self.defaults : seed)
        showsText = saved?["showsText"] as? Bool ?? (original?.displayMode == .iconAndLabel)
        synchronize()
    }
    private func identifier(_ value: String) -> NSToolbarItem.Identifier {
        value == "space" ? .space : value == "flexibleSpace" ? .flexibleSpace : NSToolbarItem.Identifier(value)
    }
    func setCommands(_ values: [ShellToolbarCommand]) { commands = values }
    func insert(_ id: String) { guard id == "space" || id == "flexibleSpace" || !identifiers.contains(id) else { return }; identifiers.append(id); synchronize() }
    func remove(at index: Int) { guard identifiers.indices.contains(index) else { return }; identifiers.remove(at: index); synchronize() }
    func move(_ index: Int, by distance: Int) { let target = index + distance; guard identifiers.indices.contains(index), identifiers.indices.contains(target) else { return }; identifiers.swapAt(index, target); synchronize() }
    func reset() { identifiers = Self.defaults; showsText = false; synchronize() }
    private func synchronize() {
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in identifiers.enumerated() { toolbar.insertItem(withItemIdentifier: identifier(id), at: index) }
        toolbar.displayMode = showsText ? .iconAndLabel : .iconOnly
        persist()
    }
    private func persist() { UserDefaults.standard.set(["items": identifiers, "showsText": showsText], forKey: preference) }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.commandIDs.map(identifier) + [.space, .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.defaults.map(identifier) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = commands.first { $0.id == id.rawValue }?.title ?? id.rawValue
        return item
    }
}

struct BorderlessToolbarView<CommandContent: View>: View {
    @ObservedObject var model: BorderlessToolbarModel
    let commands: [ShellToolbarCommand]
    @ViewBuilder let commandContent: (ShellToolbarCommand, Bool) -> CommandContent
    @State private var customizing = false
    var body: some View {
        HStack(spacing: 5) {
            GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
            ForEach(Array(model.identifiers.enumerated()), id: \.offset) { _, id in
                if id == "flexibleSpace" { Spacer(minLength: 12) }
                else if id == "space" { Color.clear.frame(width: 18, height: 24) }
                else if let command = commands.first(where: { $0.id == id }) { commandContent(command, model.showsText).help(command.title).accessibilityLabel(command.title).disabled(!command.enabled) }
            }
            }.frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            }
            Button { customizing = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 26) }.buttonStyle(.plain).help(shellToolbarText("customize"))
        }.padding(.horizontal, 10).frame(minHeight: model.showsText ? 44 : 36).background(.bar)
            .frame(height: model.showsText ? 44 : 36)
            .contextMenu { Button(shellToolbarText("customize")) { customizing = true }; Toggle(shellToolbarText("iconAndText"), isOn: $model.showsText) }
            .sheet(isPresented: $customizing) { palette }
            .onAppear { model.setCommands(commands) }
    }
    private var palette: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shellToolbarText("customize")).font(.headline)
            Toggle(shellToolbarText("iconAndText"), isOn: $model.showsText)
            List {
                ForEach(Array(model.identifiers.enumerated()), id: \.offset) { index, id in
                    HStack {
                        Text(commands.first(where: { $0.id == id })?.title ?? shellToolbarText(id))
                        Spacer()
                        Button { model.move(index, by: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                        Button { model.move(index, by: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == model.identifiers.count - 1)
                        Button { model.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    }
                }
            }.frame(height: 280)
            Menu(shellToolbarText("addItem")) {
                ForEach(commands) { command in Button(command.title) { model.insert(command.id) }.disabled(model.identifiers.contains(command.id)) }
                Divider()
                Button(shellToolbarText("space")) { model.insert("space") }
                Button(shellToolbarText("flexibleSpace")) { model.insert("flexibleSpace") }
            }
            HStack { Button(shellToolbarText("restoreDefaults")) { model.reset() }; Spacer(); Button(shellToolbarText("done")) { customizing = false }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 460)
    }
}
