import SwiftUI
import AppKit
import GitCore

struct ExternalToolsPreferencesView: View {
    @AppStorage("externalComparisonExecutable") private var savedExecutable = ExternalComparisonConfiguration.defaultExecutable
    @State private var executable = ""
    @AppStorage("externalComparisonArguments") private var savedArguments = ExternalComparisonConfiguration.compareArguments
    @AppStorage("externalMergeArguments") private var savedMergeArguments = ExternalComparisonConfiguration.mergeArguments
    @State private var mergeArguments = ""
    @State private var arguments = ""
    @State private var validation: String?
    var body: some View {
        Form {
            Section(editorPrefsText("External comparison tool")) {
                HStack {
                    Text("Beyond Compare").font(.headline)
                    Spacer()
                    Button(editorPrefsText("Use defaults")) {
                        executable = ExternalComparisonConfiguration.beyondCompare
                        arguments = ExternalComparisonConfiguration.compareArguments
                        mergeArguments = ExternalComparisonConfiguration.mergeArguments
                        validation = nil
                    }
                }
                StableTextField(editorPrefsText("Executable or application"), text: $executable)
                HStack {
                    Button(editorPrefsText("Choose tool")) { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false; if panel.runModal() == .OK, let url = panel.url { executable = url.path; validation = nil } }
                    Button(editorPrefsText("Validate")) { _ = validate() }
                    Button(editorPrefsText("Apply")) { if validate() { savedExecutable = executable; savedArguments = arguments; savedMergeArguments = mergeArguments } }.buttonStyle(.borderedProminent)
                }
                Text(editorPrefsText("Arguments JSON")).font(.headline)
                TextEditor(text: $arguments).font(.system(size: 12, design: .monospaced)).frame(height: 90)
                Text(editorPrefsText("Arguments help")).font(.caption).foregroundStyle(.secondary)
                Text(editorPrefsText("Merge arguments JSON")).font(.headline)
                TextEditor(text: $mergeArguments).font(.system(size: 12, design: .monospaced)).frame(height: 70)
                Text(editorPrefsText("Beyond Compare help")).font(.caption).foregroundStyle(.secondary)
                Text(editorPrefsText("Result help")).font(.caption).foregroundStyle(.secondary)
                if let validation { Text(validation).font(.caption).textSelection(.enabled) }
            }
            Button(editorPrefsText("Reset external tool")) { executable = ExternalComparisonConfiguration.defaultExecutable; arguments = ExternalComparisonConfiguration.compareArguments; mergeArguments = ExternalComparisonConfiguration.mergeArguments; savedExecutable = executable; savedArguments = arguments; savedMergeArguments = mergeArguments; validation = nil }
        }.formStyle(.grouped).onAppear { executable = savedExecutable.isEmpty ? ExternalComparisonConfiguration.defaultExecutable : savedExecutable; arguments = savedArguments; mergeArguments = savedMergeArguments }
    }
    private func validate() -> Bool {
        do {
            _ = try ExternalDiffArguments.parse(arguments)
            _ = try ExternalDiffArguments.parse(mergeArguments)
            let url = URL(fileURLWithPath: executable)
            guard executable.hasPrefix("/"), FileManager.default.fileExists(atPath: executable), url.pathExtension == "app" ? Bundle(url: url)?.executableURL != nil : FileManager.default.isExecutableFile(atPath: executable) else { throw GitError(editorPrefsText("Invalid executable")) }
            validation = editorPrefsText("Valid configuration")
            return true
        } catch {
            let message = OperationFailure.message(error)
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
