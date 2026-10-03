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
        Form {
            Section(editorPrefsText("Font")) {
                Toggle(editorPrefsText("Fixed width fonts only"), isOn: $fixedWidthOnly)
                Picker(editorPrefsText("Font family"), selection: $fontName) {
                    Text(editorPrefsText("System monospace")).tag("")
                    if !fontName.isEmpty && !fonts.contains(fontName) { Text(fontName).tag(fontName) }
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                Stepper(editorPrefsText("Font size") + ": \(Int(fontSize))", value: $fontSize, in: 9...32)
                Text("func compare(left: String, right: String) {\n    // RayGit\n    return left == right\n}").font(Font(EditorPreferences.font(name: fontName, size: fontSize))).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.background)
            }
            Section(editorPrefsText("Display")) {
                Toggle(editorPrefsText("Line numbers"), isOn: $numbers)
                Toggle(editorPrefsText("Wrap lines"), isOn: $wraps)
                Toggle(editorPrefsText("Synchronized scrolling"), isOn: $synchronized)
                Stepper(editorPrefsText("Tab width") + ": \(tabWidth)", value: $tabWidth, in: 1...16)
                Toggle(editorPrefsText("Syntax colors"), isOn: $syntax)
                Toggle(editorPrefsText("Character differences"), isOn: $characters)
                Toggle(editorPrefsText("Show whitespace"), isOn: $whitespace)
                Toggle(editorPrefsText("Highlight current line"), isOn: $currentLine)
            }
            Section(editorPrefsText("Difference colors")) {
                ColorPicker(editorPrefsText("Added"), selection: colorBinding($additionColor, fallback: .systemGreen), supportsOpacity: false)
                ColorPicker(editorPrefsText("Deleted"), selection: colorBinding($deletionColor, fallback: .systemRed), supportsOpacity: false)
                ColorPicker(editorPrefsText("Modified"), selection: colorBinding($modificationColor, fallback: .systemOrange), supportsOpacity: false)
                Button(editorPrefsText("Reset colors")) { additionColor = ""; deletionColor = ""; modificationColor = "" }
            }
            Section(editorPrefsText("Comparison layout")) {
                Picker(editorPrefsText("File comparison"), selection: $layout) { Text(editorPrefsText("Automatic")).tag("automatic"); Text(editorPrefsText("Three columns")).tag("three"); Text(editorPrefsText("Two columns")).tag("two"); Text(editorPrefsText("Patch")).tag("patch") }
                Toggle(editorPrefsText("Side by side diff"), isOn: $sideBySide)
            }
            Button(editorPrefsText("Reset editor defaults")) { EditorPreferences.reset() }
        }.formStyle(.grouped)
    }
}
