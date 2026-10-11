import Foundation

/// Tracks ownership separately so editing a destination never loses the user's choice.
struct CloneDestination: Codable, Equatable {
    static let parentPreference = "repository.cloneParent.v1"
    var parent: URL
    private(set) var path = ""
    private(set) var automatic = true

    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let saved = defaults.string(forKey: Self.parentPreference), saved.hasPrefix("/") {
            parent = URL(fileURLWithPath: saved).standardizedFileURL
        } else {
            let projects = home.appendingPathComponent("Git-projects", isDirectory: true)
            var directory: ObjCBool = false
            parent = FileManager.default.fileExists(atPath: projects.path, isDirectory: &directory) && directory.boolValue ? projects : home
        }
    }
    mutating func sourceChanged(_ source: String) {
        guard automatic else { return }
        path = Self.repositoryName(source).map { parent.appendingPathComponent($0).path } ?? ""
    }
    mutating func replaceSource(_ source: String) { automatic = true; sourceChanged(source) }
    mutating func edit(_ value: String) { path = value; automatic = false }
    mutating func chooseParent(_ folder: URL, source: String) {
        let folder = folder.standardizedFileURL
        parent = folder.lastPathComponent == Self.repositoryName(source) ? folder.deletingLastPathComponent() : folder
        automatic = true
        sourceChanged(source)
    }
    func rememberSuccessfulClone(_ target: URL, defaults: UserDefaults = .standard) {
        defaults.set(target.deletingLastPathComponent().standardizedFileURL.path, forKey: Self.parentPreference)
    }
    static func repositoryName(_ source: String) -> String? {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.hasPrefix("-"), !source.contains("\0") else { return nil }
        let path: String
        if source.contains("://") {
            guard let url = URLComponents(string: source), ["https", "http", "ssh", "git", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            path = url.percentEncodedPath
        } else {
            let clean = source.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? ""
            if let colon = clean.firstIndex(of: ":"), !clean[..<colon].contains("/") {
                path = String(clean[clean.index(after: colon)...])
            } else { path = clean }
        }
        guard var name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)?.removingPercentEncoding else { return nil }
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("-"), name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"), !name.contains("?"), !name.contains("#"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return name
    }
    static func clipboardSource(_ value: String?) -> String? {
        guard let source = value?.trimmingCharacters(in: .whitespacesAndNewlines), repositoryName(source) != nil else { return nil }
        if source.contains("://") {
            guard let url = URLComponents(string: source) else { return nil }
            if url.scheme?.lowercased() == "file" { return url.path.hasPrefix("/") ? source : nil }
            return url.host?.isEmpty == false && !url.path.isEmpty ? source : nil
        }
        if source.hasPrefix("/") || source.hasPrefix("~/") { return source }
        guard source.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let colon = source.firstIndex(of: ":"), !source[..<colon].isEmpty, !source[..<colon].contains("/") else { return nil }
        return source
    }
    static func targetURL(_ value: String) -> URL? {
        let expanded = (value.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0"), expanded.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return url.path == "/" ? nil : url
    }
}

/// Persists only the form draft, including whether clone naming is automatic.
struct RepositoryCreationDraft: Codable, Equatable {
    static let preference = "repository.creationDraft.v1"
    var clone = false
    var source = ""
    var destination = ""
    var cloneDestination: CloneDestination

    init(defaults: UserDefaults = .standard) {
        cloneDestination = CloneDestination(defaults: defaults)
    }
    init(clone: Bool, source: String, destination: String, cloneDestination: CloneDestination) {
        self.clone = clone; self.source = source; self.destination = destination; self.cloneDestination = cloneDestination
    }
    @discardableResult mutating func applyClipboard(_ text: String?) -> Bool {
        guard let source = CloneDestination.clipboardSource(text) else { return false }
        clone = true; self.source = source
        cloneDestination.replaceSource(source)
        destination = cloneDestination.path
        return true
    }
    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: preference),
              let draft = try? JSONDecoder().decode(Self.self, from: data),
              draft.cloneDestination.parent.isFileURL,
              draft.cloneDestination.parent.path.hasPrefix("/") else { return Self(defaults: defaults) }
        return draft
    }
    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preference) }
    }
}
