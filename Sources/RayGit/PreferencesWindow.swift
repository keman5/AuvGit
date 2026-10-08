import SwiftUI
import AppKit
import RayGitLocalization

func prefsText(_ key: String) -> String { L10n.text(key, table: "Preferences") }

enum RayGitPreferences {
    static var restoreRepositories: Bool { UserDefaults.standard.object(forKey: "preferences.restoreRepositories") as? Bool ?? true }
    static var defaultMode: String { UserDefaults.standard.string(forKey: "preferences.defaultMode") == "history" ? "history" : "workspace" }
    static var doubleClick: String { UserDefaults.standard.string(forKey: "preferences.doubleClick") ?? "compare" }
    static var historyPageSize: Int { min(1000, max(25, UserDefaults.standard.object(forKey: "preferences.historyPageSize") as? Int ?? 200)) }
    static var backgroundRefresh: Bool { UserDefaults.standard.object(forKey: "preferences.backgroundRefresh") as? Bool ?? true }
    static var pollInterval: Double { min(300, max(3, UserDefaults.standard.object(forKey: "preferences.pollInterval") as? Double ?? 3)) }
    static func matches(_ path: String, query: String, caseMode: String? = nil) -> Bool {
        let mode = caseMode ?? UserDefaults.standard.string(forKey: "preferences.filterCase") ?? "insensitive"
        let exact = mode == "exact" || (mode == "smart" && query != query.lowercased())
        return path.range(of: query, options: exact ? [] : [.caseInsensitive, .diacriticInsensitive]) != nil
    }
    @MainActor static func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "preferences.theme") ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
func preferencesDate(_ date: Date, style: String? = nil) -> String {
    switch style ?? UserDefaults.standard.string(forKey: "preferences.dateStyle") ?? "datetime" {
    case "relative":
        let formatter = RelativeDateTimeFormatter(); formatter.locale = L10n.locale; return formatter.localizedString(for: date, relativeTo: Date())
    case "date": return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(L10n.locale))
    default: return date.formatted(Date.FormatStyle(date: .numeric, time: .standard).locale(L10n.locale))
    }
}

struct PreferencesWindow: View {
    @ObservedObject var store: RepositoryStore
    @State private var selected = "General"
    @State private var query = ""
    @State private var clearAction: String?
    @AppStorage(L10n.preferenceKey) private var language = "system"
    @AppStorage("preferences.restoreRepositories") private var restore = true
    @AppStorage("preferences.defaultMode") private var defaultMode = "workspace"
    @AppStorage("preferences.theme") private var theme = "system"
    @AppStorage("preferences.doubleClick") private var doubleClick = "compare"
    @AppStorage("preferences.filterCase") private var filterCase = "insensitive"
    @AppStorage("preferences.historyPageSize") private var pageSize = 200
    @AppStorage("preferences.dateStyle") private var dateStyle = "datetime"
    @AppStorage("preferences.backgroundRefresh") private var background = true
    @AppStorage("preferences.pollInterval") private var interval = 3.0
    private let categories = ["General", "Appearance", "Editor", "History", "Commands and Git", "Network and Authentication", "External Tools", "Keyboard Shortcuts", "Git Flow and Hosting", "Updates", "Privacy", "Advanced"]
    private var searchTerms: [String: [String]] {
        ["General": ["Startup", "Reopen last repositories", "Default view for new repositories", "Double-click changed file", "Path filter case", "Smart case"],
         "Appearance": ["Theme", "Language", "Light", "Dark"], "History": ["Commits per page", "Commit dates", "Relative"],
         "Editor": ["Editor", "Font", "Font size", "Wrap lines", "Difference colors", "Syntax colors", "Character differences", "Highlight current line", "Synchronized scrolling", "Comparison layout", "Whitespace", "Tab", "Line numbers"], "Commands and Git": ["Git", "Commit", "Trim", "Executable", "Timeout", "Signing", "Email", "Identity", "Commit message cleanup"],
         "Network and Authentication": ["Proxy", "Authentication", "SSH", "Credentials", "Fetch", "Prune"], "External Tools": ["Compare", "Merge", "Tools", "Executable", "Arguments"],
         "Keyboard Shortcuts": ShortcutCommand.allCases.map(\.title), "Git Flow and Hosting": ["Feature", "Release", "Hotfix", "Review"],
         "Updates": ["Manifest", "Download"], "Privacy": ["Clear recent repositories…", "Clear session drafts…", "Telemetry"],
         "Advanced": ["Background refresh", "Polling interval (seconds)"]]
    }
    private var filtered: [String] { categories.filter { category in
        query.isEmpty || ([category] + (searchTerms[category] ?? [])).contains { prefsText($0).localizedCaseInsensitiveContains(query) || (category == "Keyboard Shortcuts" && shortcutText($0).localizedCaseInsensitiveContains(query)) || $0.localizedCaseInsensitiveContains(query) }
    } }
    private func categoryIcon(_ category: String) -> String {
        switch category {
        case "General": return "slider.horizontal.3"
        case "Appearance": return "paintpalette"
        case "Editor": return "text.alignleft"
        case "History": return "clock.arrow.circlepath"
        case "Commands and Git": return "terminal"
        case "Network and Authentication": return "network"
        case "External Tools": return "wrench.and.screwdriver"
        case "Keyboard Shortcuts": return "keyboard"
        case "Git Flow and Hosting": return "arrow.triangle.branch"
        case "Updates": return "arrow.down.circle"
        case "Privacy": return "hand.raised"
        default: return "gearshape.2"
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    StableTextField(prefsText("Search preferences"), text: $query, rounded: false)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(prefsText("Clear search"))
                    }
                }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 7)
                    .rayGitInputSurface().padding(.horizontal, 12).padding(.top, 14)
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(filtered, id: \.self) { category in
                            Button { selected = category } label: {
                                Label { Text(prefsText(category)).lineLimit(1) } icon: {
                                    Image(systemName: categoryIcon(category)).font(.system(size: 14)).frame(width: 21)
                                }.font(.system(size: 13, weight: selected == category ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                                    .contentShape(Rectangle())
                                    .foregroundStyle(selected == category ? Color.white : Color.primary)
                                    .background(selected == category ? Color.blue : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 6)
                }
            }.frame(width: 240).background(RayGitStyle.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                DesignPageHeading(title: prefsText(filtered.isEmpty ? "Search preferences" : selected), subtitle: selected == "Keyboard Shortcuts" ? shortcutText("Shortcuts apply to the current view; the same key can serve different views.") + "\n" + shortcutText("Letter shortcuts require Command or Control. Native text editing remains available in text fields.") : designText(selected == "Editor" ? "Configure code and difference display" : "Customize your RayGit workspace"))
                    .padding(.horizontal, 24).padding(.vertical, 14).rayGitChrome()
                Divider()
                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
                        Text(prefsText("No matching preferences")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Button(prefsText("Clear search")) { query = "" }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    page.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.background(RayGitStyle.canvas).buttonBorderShape(.roundedRectangle(radius: 6)).frame(minWidth: 760, idealWidth: 1040, minHeight: 620, idealHeight: 780)
            .onChange(of: query) { _, _ in if !filtered.contains(selected), let first = filtered.first { selected = first } }
            .onChange(of: theme) { _, _ in RayGitPreferences.applyAppearance() }
            .rayGitAlert(prefsText("Clear local records?"), isPresented: Binding(get: { clearAction != nil }, set: { if !$0 { clearAction = nil } })) {
                RayGitAlertButton(prefsText("Cancel"), role: .cancel) { clearAction = nil }
                RayGitAlertButton(prefsText("Clear"), role: .destructive) { if clearAction == "recent" { store.clearRecentRepositories() } else { store.clearSessionDrafts() }; clearAction = nil }
            } message: { Text(prefsText(clearAction == "recent" ? "Only the recent repository list is cleared. Repository files remain on disk." : "Saved view state and commit drafts are cleared, including the current draft. Repository files and commits remain on disk.")) }
    }
    @ViewBuilder private var page: some View {
        switch selected {
        case "Editor": EditorPreferencesView()
        case "External Tools": ExternalToolsPreferencesView()
        case "Commands and Git": GitPreferencesView()
        case "Network and Authentication": NetworkPreferencesView()
        case "Keyboard Shortcuts": ExtensionsSettings(page: .shortcuts, store: store)
        case "Git Flow and Hosting": ExtensionsSettings(page: .workflow, store: store)
        case "Updates": ExtensionsSettings(page: .updates, store: store)
        default:
            Form {
                switch selected {
                case "General":
                    Section(prefsText("Startup")) {
                        Toggle(prefsText("Reopen last repositories"), isOn: $restore)
                        Text(prefsText("Disabling reopening preserves saved sessions and drafts.")).font(.caption).foregroundStyle(.secondary)
                        choices("Default view for new repositories", $defaultMode, [("workspace", "Working Tree"), ("history", "History")])
                    }
                    Section(prefsText("Files")) {
                        choices("Double-click changed file", $doubleClick, [("compare", "Compare"), ("stage", "Stage or unstage")])
                        Text(prefsText("Conflicted files always open comparison.")).font(.caption).foregroundStyle(.secondary)
                        choices("Path filter case", $filterCase, [("insensitive", "Ignore case"), ("exact", "Exact case"), ("smart", "Smart case")])
                        Text(prefsText("Smart case matches uppercase queries exactly; lowercase queries ignore case.")).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(prefsText("Restore category defaults")) { restore = true; defaultMode = "workspace"; doubleClick = "compare"; filterCase = "insensitive" }
                case "Appearance":
                    choices("Theme", $theme, [("system", "Follow System"), ("light", "Light"), ("dark", "Dark")])
                    Picker(prefsText("Language"), selection: $language) { ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0.rawValue) } }
                    Button(prefsText("Restore category defaults")) { theme = "system"; language = "system" }
                case "History":
                    Stepper(prefsText("Commits per page") + ": \(pageSize)", value: $pageSize, in: 25...1000, step: 25)
                    choices("Commit dates", $dateStyle, [("datetime", "Date and time"), ("date", "Date"), ("relative", "Relative")])
                    Text(prefsText("Page size applies to the next history load.")).font(.caption).foregroundStyle(.secondary)
                    Button(prefsText("Restore category defaults")) { pageSize = 200; dateStyle = "datetime" }
                case "Privacy":
                    Text(prefsText("Preferences, recent paths, security-scoped bookmarks and session drafts are stored locally. RayGit does not send telemetry. Network actions and update checks run when requested."))
                    Button(prefsText("Clear recent repositories…")) { clearAction = "recent" }
                    Button(prefsText("Clear session drafts…")) { clearAction = "session" }
                default:
                    Section(prefsText("Background refresh")) {
                        Toggle(prefsText("Refresh on filesystem changes and in background"), isOn: $background)
                        Stepper(prefsText("Polling interval (seconds)") + ": \(Int(interval))", value: $interval, in: 3...300, step: 3).disabled(!background)
                        Text(prefsText("Filesystem notifications are debounced. Manual refresh remains available.")).font(.caption).foregroundStyle(.secondary)
                        Button(prefsText("Restore refresh defaults")) { background = true; interval = 3 }
                    }
                }
            }.formStyle(.grouped).controlSize(.small)
        }
    }
    private func choices(_ title: String, _ value: Binding<String>, _ options: [(String, String)]) -> some View {
        Picker(prefsText(title), selection: value) { ForEach(options, id: \.0) { Text(prefsText($0.1)).tag($0.0) } }
    }
}
