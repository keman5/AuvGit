import SwiftUI
import AppKit
import RayGitLocalization

func editorPrefsText(_ key: String) -> String { L10n.text(key, table: "EditorPreferences") }

enum EditorPreferences {
    static let defaults: [String: Any] = ["additionColor": "", "deletionColor": "", "modificationColor": "", "fontName": "", "fontSize": 12.0, "fixedWidthOnly": true, "showLineNumbers": true, "wrapLines": false, "tabWidth": 4, "synchronizeScroll": true, "syntaxHighlight": true, "characterDiff": true, "showWhitespace": false, "highlightCurrentLine": true, "comparisonLayoutMode": "automatic", "defaultDiffSideBySide": true]
    static func color(_ value: String, fallback: NSColor) -> NSColor {
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return fallback }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func reset() { for (key, value) in defaults { UserDefaults.standard.set(value, forKey: "editor." + key) } }
    static func font(name: String, size: Double) -> NSFont { NSFont(name: name, size: CGFloat(min(32, max(9, size)))) ?? .monospacedSystemFont(ofSize: CGFloat(min(32, max(9, size))), weight: .regular) }
}

struct EditorPreferencesView: View {
    @AppStorage("editor.additionColor") private var additionColor = ""
    @AppStorage("editor.deletionColor") private var deletionColor = ""
    @AppStorage("editor.modificationColor") private var modificationColor = ""
    @AppStorage("editor.fontName") private var fontName = ""
    @AppStorage("editor.fontSize") private var fontSize = 12.0
    @AppStorage("editor.fixedWidthOnly") private var fixedWidthOnly = true
    @AppStorage("editor.showLineNumbers") private var numbers = true
    @AppStorage("editor.wrapLines") private var wraps = false
    @AppStorage("editor.tabWidth") private var tabWidth = 4
    @AppStorage("editor.synchronizeScroll") private var synchronized = true
    @AppStorage("editor.syntaxHighlight") private var syntax = true
    @AppStorage("editor.characterDiff") private var characters = true
    @AppStorage("editor.showWhitespace") private var whitespace = false
    @AppStorage("editor.highlightCurrentLine") private var currentLine = true
    @AppStorage("editor.comparisonLayoutMode") private var layout = "automatic"
    @AppStorage("editor.defaultDiffSideBySide") private var sideBySide = true
    private var fonts: [String] { NSFontManager.shared.availableFonts.filter { !fixedWidthOnly || NSFont(name: $0, size: 12)?.isFixedPitch == true }.sorted() }
    private func colorBinding(_ value: Binding<String>, fallback: NSColor) -> Binding<Color> {
        Binding(get: { Color(nsColor: EditorPreferences.color(value.wrappedValue, fallback: fallback)) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            value.wrappedValue = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(designText("Font and layout")) {
                        DesignSettingRow(editorPrefsText("Font family"), detail: designText("Choose the editor font")) {
                            Picker(editorPrefsText("Font family"), selection: $fontName) {
                                Text(editorPrefsText("System monospace")).tag("")
                                if !fontName.isEmpty && !fonts.contains(fontName) { Text(fontName).tag(fontName) }
                                ForEach(fonts, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 220)
                        }
                        Divider()
                        DesignSettingRow(editorPrefsText("Font size"), detail: designText("Size of the editor text")) {
                            Stepper("\(Int(fontSize))", value: $fontSize, in: 9...32).frame(width: 94)
                        }
                        Divider()
                        DesignSettingRow(editorPrefsText("Tab width"), detail: designText("Spaces represented by one tab")) {
                            Stepper("\(tabWidth)", value: $tabWidth, in: 1...16).frame(width: 94)
                        }
                        Divider()
                        settingToggle("Fixed width fonts only", $fixedWidthOnly)
                    }
                    section(designText("Editing behavior")) {
                        settingToggle("Line numbers", $numbers, "Show original source line numbers")
                        Divider()
                        settingToggle("Wrap lines", $wraps, "Wrap text to the available pane width")
                        Divider()
                        settingToggle("Synchronized scrolling", $synchronized, "Keep corresponding changes together")
                    }
                    section(editorPrefsText("Comparison layout")) {
                        DesignSettingRow(editorPrefsText("File comparison")) {
                            Picker(editorPrefsText("File comparison"), selection: $layout) {
                                Text(editorPrefsText("Automatic")).tag("automatic")
                                Text(editorPrefsText("Three columns")).tag("three")
                                Text(editorPrefsText("Two columns")).tag("two")
                                Text(editorPrefsText("Patch")).tag("patch")
                            }.labelsHidden().frame(width: 220)
                        }
                        Divider()
                        settingToggle("Side by side diff", $sideBySide)
                        Divider()
                        settingToggle("Highlight current line", $currentLine)
                        Divider()
                        settingToggle("Show whitespace", $whitespace)
                        Divider()
                        settingToggle("Character differences", $characters)
                        Divider()
                        settingToggle("Syntax colors", $syntax)
                    }
                    section(editorPrefsText("Difference colors")) {
                        ColorPicker(editorPrefsText("Added"), selection: colorBinding($additionColor, fallback: .systemGreen), supportsOpacity: false)
                        Divider()
                        ColorPicker(editorPrefsText("Deleted"), selection: colorBinding($deletionColor, fallback: .systemRed), supportsOpacity: false)
                        Divider()
                        ColorPicker(editorPrefsText("Modified"), selection: colorBinding($modificationColor, fallback: .systemOrange), supportsOpacity: false)
                        Button(editorPrefsText("Reset colors")) { additionColor = ""; deletionColor = ""; modificationColor = "" }.padding(.top, 8)
                    }
                    DesignCard(designText("Font preview")) {
                        Text("func compare(left: String, right: String) {\n    // RayGit\n    return left == right\n}")
                            .font(Font(EditorPreferences.font(name: fontName, size: fontSize))).textSelection(.enabled)
                    }
                }.padding(24)
            }
            Divider()
            HStack(spacing: 12) {
                Button { EditorPreferences.reset() } label: { Label(editorPrefsText("Reset editor defaults"), systemImage: "arrow.counterclockwise") }
                Text(designText("Changes are applied immediately")).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }.tint(.blue)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold))
            DesignCard { VStack(spacing: 0, content: content) }
        }
    }
    private func settingToggle(_ key: String, _ binding: Binding<Bool>, _ detail: String = "") -> some View {
        DesignSettingRow(editorPrefsText(key), detail: detail.isEmpty ? "" : designText(detail)) {
            Toggle(editorPrefsText(key), isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}
