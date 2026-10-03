import SwiftUI
import AppKit
import GitCore

struct ExternalToolsPreferencesView: View {
    @AppStorage("externalComparisonExecutable") private var savedExecutable = ""
    @State private var executable = ""
    @AppStorage("externalComparisonArguments") private var savedArguments = "[\"{left}\", \"{right}\"]"
    @State private var arguments = ""
    @State private var validation: String?
    var body: some View {
        Form {
            Section(editorPrefsText("External comparison tool")) {
                TextField(editorPrefsText("Executable or application"), text: $executable)
                HStack {
                    Button(editorPrefsText("Choose tool")) { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false; if panel.runModal() == .OK, let url = panel.url { executable = url.path; validation = nil } }
                    Button(editorPrefsText("Validate")) { _ = validate() }
                    Button(editorPrefsText("Apply")) { if validate() { savedExecutable = executable; savedArguments = arguments } }.buttonStyle(.borderedProminent)
                }
                Text(editorPrefsText("Arguments JSON")).font(.headline)
                TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                Text(editorPrefsText("Arguments help")).font(.caption).foregroundStyle(.secondary)
                HStack { Button(editorPrefsText("Two versions")) { arguments = "[\"{left}\", \"{right}\"]" }; Button(editorPrefsText("Merge result")) { arguments = "[\"{base}\", \"{left}\", \"{right}\", \"{result}\"]" } }
                Text(editorPrefsText("Result help")).font(.caption).foregroundStyle(.secondary)
                if let validation { Text(validation).font(.caption).textSelection(.enabled) }
            }
            Button(editorPrefsText("Reset external tool")) { executable = ""; arguments = "[\"{left}\", \"{right}\"]"; savedExecutable = executable; savedArguments = arguments; validation = nil }
        }.formStyle(.grouped).onAppear { executable = savedExecutable; arguments = savedArguments }
    }
    private func validate() -> Bool {
        do {
            _ = try ExternalDiffArguments.parse(arguments)
            let url = URL(fileURLWithPath: executable)
            guard executable.hasPrefix("/"), FileManager.default.fileExists(atPath: executable), url.pathExtension == "app" ? Bundle(url: url)?.executableURL != nil : FileManager.default.isExecutableFile(atPath: executable) else { throw GitError(editorPrefsText("Invalid executable")) }
            validation = editorPrefsText("Valid configuration")
            return true
        } catch {
            let message = error.localizedDescription
            let unavailable = "External tool template references an unavailable version: "
            if message.hasPrefix(unavailable) {
                validation = editorPrefsText("Unavailable version") + " " + message.dropFirst(unavailable.count)
            } else {
                validation = editorPrefsText(message)
            }
            return false
        }
    }
}
