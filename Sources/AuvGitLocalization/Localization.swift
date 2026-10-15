import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", ja
    public var id: String { rawValue }
    public var nativeName: String {
        switch self {
        case .system: return L10n.text("Follow System", table: "Language")
        case .en: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .ja: return "日本語"
        }
    }
}

public enum L10n {
    public static let resourceBundle: Bundle = {
        Bundle.main.url(forResource: "AuvGit_AuvGitLocalization", withExtension: "bundle").flatMap(Bundle.init(url:)) ?? Bundle.module
    }()
    private static let localizedBundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["en", "zh-Hans", "zh-Hant", "ja"].compactMap { code in
        let path = resourceBundle.path(forResource: code, ofType: "lproj")
            ?? resourceBundle.path(forResource: code.lowercased(), ofType: "lproj")
        guard let path, let bundle = Bundle(path: path) else { return nil }
        return (code, bundle)
    })
    public static let preferenceKey = "appLanguage"
    public static var language: AppLanguage { resolvedLanguage(preference: UserDefaults.standard.string(forKey: preferenceKey) ?? "system", preferredLanguages: Locale.preferredLanguages) }
    public static var locale: Locale { Locale(identifier: language.rawValue) }
    public static func resolvedLanguage(preference: String, preferredLanguages: [String]) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: preference), explicit != .system { return explicit }
        for candidate in preferredLanguages {
            let parts = candidate.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard let base = parts.first else { continue }
            if base == "en" { return .en }
            if base == "ja" { return .ja }
            if base == "zh" {
                if parts.contains("hant") { return .traditionalChinese }
                if parts.contains("hans") { return .simplifiedChinese }
                if parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) { return .traditionalChinese }
                return .simplifiedChinese
            }
        }
        return .en
    }
    public static func text(_ key: String, table: String = "App", arguments: [CVarArg] = []) -> String {
        text(key, table: table, language: language, arguments: arguments)
    }
    public static func text(_ key: String, table: String = "App", arguments: [CVarArg] = [], language: AppLanguage) -> String {
        text(key, table: table, language: language, arguments: arguments)
    }
    public static func text(_ key: String, table: String = "App", language: AppLanguage, arguments: [CVarArg]) -> String {
        let resolved = language == .system ? self.language : language
        func lookup(_ code: String) -> String? {
            guard let bundle = localizedBundles[code] else { return nil }
            let sentinel = "__AUVGIT_MISSING__"
            let value = bundle.localizedString(forKey: key, value: sentinel, table: table)
            return value == sentinel ? nil : value
        }
        let format = lookup(resolved.rawValue) ?? lookup("en") ?? key
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: resolved.rawValue), arguments: arguments)
    }
}
