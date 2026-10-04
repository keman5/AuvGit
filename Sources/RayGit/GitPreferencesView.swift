import SwiftUI
import AppKit
import GitCore
import RayGitLocalization

func gitPrefsText(_ key: String) -> String { L10n.text(key, table: "GitPreferences") }

private let knownGitPrefsErrors: Set<String> = [
    "Choose an absolute path to an executable Git binary.",
    "Invalid Git preferences.",
    "Invalid proxy mode.",
    "Enter an HTTP(S) proxy URL without credentials, query or fragment.",
    "SSH command must be one line.",
    "The selected executable is not Git.",
    "Configuration values must be one line.",
    "Signing format must be openpgp, x509 or ssh.",
    "Sign commits must be true, false or empty.",
]
private func gitPrefsError(_ error: Error) -> String {
    let message = OperationFailure.message(error)
    return knownGitPrefsErrors.contains(message) ? gitPrefsText(message) : message
}

struct GitPreferencesView: View {
    @State private var path = GitRuntimePreferences.shared.executablePath
    @State private var timeout = GitRuntimePreferences.shared.timeout
    @State private var cleanup = GitRuntimePreferences.shared.commitCleanup
    @State private var status = ""
    @State private var busy = false
    @State private var identity = GlobalGitConfiguration()
    @State private var originalIdentity = GlobalGitConfiguration()
    @State private var identityLoaded = false
    var body: some View {
        Form {
            Section(gitPrefsText("Git executable")) {
                TextField(gitPrefsText("Absolute path"), text: $path)
                Button(gitPrefsText("Choose…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
            Section(gitPrefsText("Global identity and signing")) {
                TextField(gitPrefsText("Full name"), text: $identity.name)
                TextField(gitPrefsText("Email"), text: $identity.email)
                Picker(gitPrefsText("Signing format (openpgp, x509, ssh)"), selection: $identity.signingFormat) { Text(gitPrefsText("Git default")).tag(""); Text("OpenPGP").tag("openpgp"); Text("SSH").tag("ssh"); Text("X.509").tag("x509"); if !["", "openpgp", "ssh", "x509"].contains(identity.signingFormat) { Text(identity.signingFormat).tag(identity.signingFormat) } }
                TextField(gitPrefsText("Signing key identifier"), text: $identity.signingKey)
                Picker(gitPrefsText("Sign commits"), selection: $identity.signCommits) { Text(gitPrefsText("Git default")).tag(""); Text(gitPrefsText("Enabled")).tag("true"); Text(gitPrefsText("Disabled")).tag("false"); if !["", "true", "false"].contains(identity.signCommits) { Text(identity.signCommits).tag(identity.signCommits) } }
                Text(gitPrefsText("These are global Git settings for all repositories. Repository settings may override them. Only changed fields are written; empty fields remove the global key.")).font(.caption).foregroundStyle(.secondary)
                Button(gitPrefsText("Apply Global Configuration")) {
                    let snapshot = identity, original = originalIdentity; busy = true
                    Task { do { try await snapshot.apply(changedFrom: original); let loaded = try await GlobalGitConfiguration.load(); try Task.checkCancellation(); originalIdentity = loaded; identity = loaded; status = gitPrefsText("Saved") } catch { status = gitPrefsError(error) }; busy = false }
                }.disabled(!identityLoaded || busy)
            }.disabled(!identityLoaded || busy)
            Section(gitPrefsText("Commands")) {
                Stepper(value: $timeout, in: 5...3600, step: 5) { Text(gitPrefsText("Timeout (seconds)") + ": \(Int(timeout))") }
                Picker(gitPrefsText("Commit message cleanup"), selection: $cleanup) {
                    Text(gitPrefsText("Git default")).tag("default")
                    Text(gitPrefsText("Trim whitespace")).tag("whitespace")
                    Text(gitPrefsText("Trim whitespace and comments")).tag("strip")
                    Text(gitPrefsText("Preserve message")).tag("verbatim")
                }
            }
            Text(gitPrefsText("Applies to new Git commands in RayGit. Existing commands keep their timeout. Git default preserves existing behavior.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(gitPrefsText("Validate and Apply")) {
                    let chosenPath = path, chosenTimeout = timeout, chosenCleanup = cleanup; busy = true
                    Task { do { let version = try await GitRuntimePreferences.validateExecutable(chosenPath); try GitRuntimePreferences.shared.setGit(path: chosenPath, timeout: chosenTimeout, cleanup: chosenCleanup); status = version } catch { status = gitPrefsError(error) }; busy = false }
                }.disabled(busy)
                Button(gitPrefsText("Restore Defaults")) { GitRuntimePreferences.shared.resetGit(); path = GitRuntimePreferences.shared.executablePath; timeout = GitRuntimePreferences.shared.timeout; cleanup = GitRuntimePreferences.shared.commitCleanup; status = gitPrefsText("Defaults restored") }
                if busy { ProgressView().controlSize(.small) }
            }
            if !status.isEmpty { Text(status).textSelection(.enabled) }
        }.formStyle(.grouped).disabled(busy).task {
            do { let loaded = try await GlobalGitConfiguration.load(); try Task.checkCancellation(); originalIdentity = loaded; identity = loaded; identityLoaded = true } catch { status = gitPrefsError(error) }
        }
    }
}

struct NetworkPreferencesView: View {
    @State private var mode = GitRuntimePreferences.shared.proxyMode
    @State private var proxy = GitRuntimePreferences.shared.proxyURL
    @State private var ssh = GitRuntimePreferences.shared.sshCommand
    @State private var prune = GitRuntimePreferences.shared.fetchPrune
    @State private var status = ""
    var body: some View {
        Form {
            Section(gitPrefsText("Proxy")) {
                Picker(gitPrefsText("Proxy mode"), selection: $mode) {
                    Text(gitPrefsText("Inherit environment and Git configuration")).tag("inherit")
                    Text(gitPrefsText("Disable default proxy")).tag("off")
                    Text(gitPrefsText("Manual HTTP(S) proxy")).tag("manual")
                }
                if mode == "manual" { TextField("https://proxy.example:8080", text: $proxy) }
                Text(gitPrefsText("Only RayGit Git processes are affected. This does not use macOS automatic proxy settings. Proxy URLs cannot contain passwords. Repository URL-specific or remote proxy settings may override this default; SSH proxy uses SSH config.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(gitPrefsText("SSH and Fetch")) {
                TextField(gitPrefsText("SSH command (optional)"), text: $ssh)
                Text(gitPrefsText("An existing GIT_SSH_COMMAND environment variable takes priority. Git interprets this command; do not enter secrets. Default SSH uses BatchMode.")).font(.caption).foregroundStyle(.secondary)
                Toggle(gitPrefsText("Prune deleted remote branches when fetching"), isOn: $prune)
            }
            Section(gitPrefsText("Credentials")) {
                Text(gitPrefsText("RayGit uses configured Git credential helpers and your SSH agent. Passwords and tokens are never read by this preferences page. Manage repository helpers in Network Operations.")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(gitPrefsText("Apply")) { do { try GitRuntimePreferences.shared.setNetwork(mode: mode, proxy: proxy, ssh: ssh, prune: prune); status = gitPrefsText("Saved") } catch { status = gitPrefsError(error) } }
                Button(gitPrefsText("Restore Defaults")) { GitRuntimePreferences.shared.resetNetwork(); mode = "inherit"; proxy = ""; ssh = ""; prune = true; status = gitPrefsText("Defaults restored") }
            }
            if !status.isEmpty { Text(status).textSelection(.enabled) }
        }.formStyle(.grouped)
    }
}
