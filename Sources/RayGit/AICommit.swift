import SwiftUI
import Foundation
import Security
import GitCore
import RayGitLocalization

func aiCommitText(_ key: String) -> String { L10n.text(key, table: "AICommit") }

enum AICommitScopeChoice {
    static let key = "aiCommit.rememberedScope"
    static func remembered(defaults: UserDefaults = .standard) -> AICommitScope? {
        defaults.string(forKey: key).flatMap(AICommitScope.init(rawValue:))
    }
    static func save(_ scope: AICommitScope, remember: Bool, defaults: UserDefaults = .standard) {
        if remember { defaults.set(scope.rawValue, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

struct AICommitScopeSheet: View {
    let generate: (AICommitScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scope = AICommitScopeChoice.remembered() ?? .staged
    @State private var remember = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(aiCommitText("Generate commit message")).font(.headline)
            Text(aiCommitText("Choose which changes AI should describe."))
            Picker(aiCommitText("Generation scope"), selection: $scope) {
                Text(aiCommitText("Staged files only")).tag(AICommitScope.staged)
                Text(aiCommitText("All workspace changes")).tag(AICommitScope.workspace)
            }.pickerStyle(.radioGroup).labelsHidden()
            Text(aiCommitText("Workspace scope includes staged, unstaged, and untracked changes. Unchanged and ignored files are excluded. No files are staged or committed."))
                .font(.caption).foregroundStyle(.secondary)
            Toggle(aiCommitText("Remember my choice"), isOn: $remember)
            HStack {
                DialogButton(aiCommitText("Cancel"), role: .cancel) { dismiss() }
                DialogButton(aiCommitText("Generate"), prominent: true) {
                    AICommitScopeChoice.save(scope, remember: remember)
                    generate(scope)
                }
            }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.padding(24).frame(width: 380)
    }
}

struct AICommitConfiguration {
    var provider = UserDefaults.standard.string(forKey: "aiCommit.provider") ?? "codex"
    var endpoint = UserDefaults.standard.string(forKey: "aiCommit.endpoint") ?? "https://api.openai.com/v1/chat/completions"
    var model = UserDefaults.standard.string(forKey: "aiCommit.model") ?? "gpt-6.1-sol"
    var executable = UserDefaults.standard.string(forKey: "aiCommit.executable") ?? Self.defaultExecutable
    var maximumPatchKB = AICommitInputPolicy.loadLimit()
    private static var defaultExecutable: String {
        let paths = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/pnpm/bin/codex").path, "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { resolvedExecutable($0) } ?? "/opt/homebrew/bin/codex"
    }
    static func resolvedExecutable(_ path: String) -> String {
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var javascript = executable
        if let shim = try? String(contentsOf: executable, encoding: .utf8),
           let target = shim.components(separatedBy: "\n").first(where: { $0.hasPrefix("# cmd-shim-target=") }) {
            javascript = URL(fileURLWithPath: String(target.dropFirst("# cmd-shim-target=".count))).resolvingSymlinksInPath()
        }
        guard javascript.lastPathComponent == "codex.js" else { return path }
        let package = javascript.deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let platform = "darwin-arm64", triple = "aarch64-apple-darwin"
        #else
        let platform = "darwin-x64", triple = "x86_64-apple-darwin"
        #endif
        let candidates = [package.appendingPathComponent("vendor/" + triple + "/bin/codex"), package.deletingLastPathComponent().appendingPathComponent("codex-" + platform + "/vendor/" + triple + "/bin/codex")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.resolvingSymlinksInPath().path ?? path
    }
    static var isConfigured: Bool { ["codex", "api"].contains(Self().provider) }
    func save() {
        AICommitInputPolicy.saveLimit(maximumPatchKB)
        UserDefaults.standard.set(provider, forKey: "aiCommit.provider")
        UserDefaults.standard.set(endpoint, forKey: "aiCommit.endpoint")
        UserDefaults.standard.set(model, forKey: "aiCommit.model")
        UserDefaults.standard.set(executable, forKey: "aiCommit.executable")
    }
}

private enum AICommitSecret {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "RayGit.AICommit", kSecAttrAccount as String: "api-key"] }
    static func read() -> String {
        var value = query; value[kSecReturnData as String] = true; value[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(value as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ key: String) throws {
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var value = query; value[kSecValueData as String] = data
            guard SecItemAdd(value as CFDictionary, nil) == errSecSuccess else { throw AICommitFailure("Could not save API key") }; return
        }
        guard status == errSecSuccess else { throw AICommitFailure("Could not save API key") }
    }
}
private struct AICommitFailure: LocalizedError {
    let key: String
    init(_ key: String) { self.key = key }
    var errorDescription: String? { aiCommitText(key) }
}

@MainActor
final class AICommitController: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var canGenerateSummary = false
    private(set) var scope: AICommitScope = .staged
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    func cancel() { requestID = UUID(); task?.cancel(); task = nil; if isLoading { isLoading = false } }
    private let generateMessage: (String, AICommitConfiguration) async throws -> String
    init(generateMessage: @escaping (String, AICommitConfiguration) async throws -> String = { try await AICommitService.generate(prompt: $0, configuration: $1) }) {
        self.generateMessage = generateMessage
    }
    func generate(store: RepositoryStore, scope: AICommitScope = .staged, summaryOnly: Bool = false) {
        guard !isLoading, let repository = store.repository, !store.isBusy else { return }
        let configuration = AICommitConfiguration(), original = store.commitMessage, token = UUID(), root = repository.url
        self.scope = scope
        requestID = token; isLoading = true; error = nil; canGenerateSummary = false
        task = Task { [weak self, weak store] in
            do {
                let draftGuard = AICommitDraftGuard(repository: root, originalDraft: original)
                guard let generateMessage = self?.generateMessage else { return }
                @MainActor func readInput() async throws -> String {
                    do {
                        let input = try await repository.aiCommitInput(scope: scope, summaryOnly: summaryOnly, maximumBytes: summaryOnly ? AICommitInputPolicy.summaryLimit : configuration.maximumPatchKB * 1000)
                        guard !input.isEmpty else { throw AICommitFailure(scope == .staged ? "No staged changes" : "No workspace changes") }
                        return input
                    } catch AICommitInputError.exceedsLimit {
                        if !summaryOnly, let self, self.requestID == token { self.canGenerateSummary = true }
                        throw AICommitFailure(summaryOnly ? "Change summary exceeds the configured limit" : "Changes exceed the configured limit")
                    }
                }
                var input = try await readInput()
                while true {
                    try Task.checkCancellation()
                    guard let self, let store, self.requestID == token else { return }
                    if let rejection = draftGuard.rejection(repository: store.repositoryURL, draft: store.commitMessage, isBusy: store.isBusy) { throw AICommitFailure(rejection) }
                    let prompt = summaryOnly ? AICommitInputPolicy.summaryPrompt(status: input, stat: "", scope: scope) : AICommitInputPolicy.patchPrompt(input, scope: scope)
                    let generated = try await generateMessage(prompt, configuration)
                    try Task.checkCancellation()
                    let latest = try await readInput()
                    guard self.requestID == token else { return }
                    if let rejection = draftGuard.rejection(repository: store.repositoryURL, draft: store.commitMessage, isBusy: store.isBusy) { throw AICommitFailure(rejection) }
                    if latest != input { input = latest; continue }
                    store.commitMessage = generated
                    break
                }
            } catch is CancellationError {} catch {
                if let self, self.requestID == token {
                    if error is AICommitFailure || error is AICommitAPIError { self.error = error.localizedDescription }
                    else { self.error = aiCommitText("Generation failed; check AI settings") }
                }
            }
            if let self, self.requestID == token { self.isLoading = false; self.task = nil }
        }
    }
}

struct AICommitAPIError: LocalizedError {
    let statusCode: Int
    let message: String
    var errorDescription: String? { "API request failed (\(statusCode)): \(message)" }
}

enum AICommitAPI {
    static func endpointURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host,
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw AICommitFailure("Invalid API endpoint")
        }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        if !path.hasSuffix("/chat/completions") {
            components.path = path + "/chat/completions"
        }
        guard let url = components.url else { throw AICommitFailure("Invalid API endpoint") }
        return url
    }

    static func message(from data: Data, response: HTTPURLResponse) throws -> String {
        guard data.count <= 256_000 else { throw AICommitFailure("AI returned an invalid commit message") }
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorResponse: Decodable { struct APIError: Decodable { let message: String }; let error: APIError }
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            throw AICommitAPIError(statusCode: response.statusCode, message: detail)
        }
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }; let choices: [Choice] }
        guard let value = try? JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else {
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? "unknown content type"
            throw AICommitAPIError(statusCode: response.statusCode, message: "Invalid response (\(type))")
        }
        return value
    }
}

private enum AICommitService {
    static func generate(prompt: String, configuration: AICommitConfiguration) async throws -> String {
        let value: String
        if configuration.provider == "codex" {
            value = try await AICommitCLI.generate(prompt: prompt, configuration: configuration)
        } else if configuration.provider == "api" {
            let endpoint = try AICommitAPI.endpointURL(from: configuration.endpoint)
            let key = AICommitSecret.read(); guard !key.isEmpty else { throw AICommitFailure("API key is required") }
            var request = URLRequest(url: endpoint, timeoutInterval: 90)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": configuration.model, "messages": [["role": "user", "content": prompt]]])
            let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AICommitFailure("Generation failed; check AI settings") }
            value = try AICommitAPI.message(from: data, response: response)
        } else { throw AICommitFailure("Choose an AI service first") }
        let message = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.utf8.count <= 16_000 else { throw AICommitFailure("AI returned an invalid commit message") }
        return message
    }
}

/// Runs in a disposable empty directory, never in the repository. Patch goes through stdin.
enum AICommitCLI {
    /// Carry only the selected provider's transport settings. The original user
    /// config, MCP servers, hooks, plugins and project instructions never load.
    static func isolatedProviderConfig(from home: URL) -> String? {
        guard let source = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return nil }
        let lines = source.components(separatedBy: .newlines)
        let pattern = try! NSRegularExpression(pattern: #"^\s*model_provider\s*=\s*["']([A-Za-z0-9_-]+)["']\s*(?:#.*)?$"#)
        var provider: String?
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            let string = line as NSString
            if let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) { provider = string.substring(with: match.range(at: 1)) }
        }
        guard let provider else { return nil }
        let allowed: Set<String> = ["name", "base_url", "wire_api", "env_key", "experimental_bearer_token", "requires_openai_auth", "supports_websockets", "request_max_retries", "stream_max_retries", "stream_idle_timeout_ms"]
        var selected = false, values: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { selected = line == "[model_providers." + provider + "]"; continue }
            guard selected, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard allowed.contains(key), !value.hasPrefix("\"\"\""), !value.hasPrefix("'" + "''") else { continue }
            values.append(key + " = " + value)
        }
        guard !values.isEmpty else { return nil }
        return "model_provider = \"" + provider + "\"\n[model_providers." + provider + "]\n" + values.joined(separator: "\n") + "\n"
    }
    static func generate(prompt: String, configuration: AICommitConfiguration) async throws -> String {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("RayGit-AI-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = AICommitConfiguration.resolvedExecutable(configuration.executable)
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw AICommitFailure("Codex executable was not found") }
        let isolatedHome = temporary.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let authHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        if let providerConfig = isolatedProviderConfig(from: authHome) {
            let config = isolatedHome.appendingPathComponent("config.toml")
            try Data(providerConfig.utf8).write(to: config, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        let auth = authHome.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: auth.path) {
            try FileManager.default.copyItem(at: auth, to: isolatedHome.appendingPathComponent("auth.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: isolatedHome.appendingPathComponent("auth.json").path)
        }
        let output = temporary.appendingPathComponent("message.txt"), input = temporary.appendingPathComponent("prompt.txt")
        try Data(prompt.utf8).write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = isolatedHome.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        let arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "--color", "never", "--model", configuration.model, "--enable", "skip_host_skill_discovery", "--disable", "skill_search", "--disable", "apps", "--disable", "shell_tool", "--disable", "unified_exec", "--config", "web_search=\"disabled\"", "--config", "developer_instructions=\"Return only the commit message. Do not call any tools or access files.\"", "--output-last-message", output.path, "-"]
        let status: Int32
        do { status = try await BoundedProcess().run(executable: URL(fileURLWithPath: executable), arguments: arguments, directory: temporary, environment: environment, input: input) }
        catch BoundedProcessError.timedOut { throw AICommitFailure("Generation timed out") }
        guard status == 0 else { throw AICommitFailure("Codex generation failed; check login, executable and model") }
        guard let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber, size.intValue <= 16_000 else { throw AICommitFailure("Generation failed; check AI settings") }
        return try String(contentsOf: output, encoding: .utf8)
    }
}

struct AICommitSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = AICommitConfiguration()
    @State private var key = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(aiCommitText("Settings")).font(.headline)
            Text(aiCommitText("Only changes in the selected scope are sent to your service. Generated text fills the draft and never stages or commits.")).font(.caption).foregroundStyle(.secondary)
            Picker(aiCommitText("Service"), selection: $configuration.provider) {
                Text(aiCommitText("Choose a service")).tag("")
                Text(aiCommitText("Local Codex CLI")).tag("codex")
                Text(aiCommitText("OpenAI-compatible API")).tag("api")
            }
            if configuration.provider == "codex" {
                Text(aiCommitText("Uses your current Codex login and model provider; tools and project settings remain isolated.")).font(.caption).foregroundStyle(.secondary)
                StableTextField(aiCommitText("Codex executable"), text: $configuration.executable)
            }
            if configuration.provider == "api" {
                StableTextField(aiCommitText("API endpoint"), text: $configuration.endpoint)
                SecureField(aiCommitText("API key (stored in Keychain)"), text: $key)
            }
            StableTextField(aiCommitText("Model"), text: $configuration.model)
            HStack {
                Text(aiCommitText("Patch limit (KB)"))
                TextField("120", value: $configuration.maximumPatchKB, format: .number.grouping(.never)).frame(width: 80)
                Stepper("", value: $configuration.maximumPatchKB, in: 30...4000, step: 10).labelsHidden()
                Text("30–4000").font(.caption).foregroundStyle(.secondary)
            }
            Text(aiCommitText("Increase the patch limit in AI settings, or generate from file names and change counts. Summary mode cannot describe code details.")).font(.caption).foregroundStyle(.secondary)

            HStack { if !error.isEmpty { FloatingNotice(message: error) }; DialogButton(aiCommitText("Cancel"), role: .cancel) { dismiss() }; DialogButton(aiCommitText("Save"), prominent: true) {
                do { if !key.isEmpty { try AICommitSecret.save(key) }; configuration.save(); dismiss() }
                catch { self.error = OperationFailure.message(error) }
            }.disabled(configuration.provider.isEmpty || configuration.model.trimmingCharacters(in: .whitespaces).isEmpty || !(30...4000).contains(configuration.maximumPatchKB)) }.buttonStyle(RayGitDialogButtonStyle()).frame(maxWidth: .infinity)
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 520)
    }
}
