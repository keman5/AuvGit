import Foundation

public enum ShortcutRules {
    public static let defaults = ["o", "r", "t", "k"]
    public static let reserved = Set("qwhm,cvxzafs".map(String.init))
    public static func isValid(_ key: String) -> Bool {
        key.count == 1 && key.first?.isASCII == true && key.first?.isLetter == true && !reserved.contains(key.lowercased())
    }
    /// Repairs older or externally edited preferences without creating duplicate commands.
    public static func normalized(_ keys: [String]) -> [String] {
        var result = Array(repeating: "", count: 4), used = Set<String>()
        for index in result.indices where index < keys.count {
            let key = keys[index].lowercased()
            if isValid(key), used.insert(key).inserted { result[index] = key }
        }
        let candidates = defaults + "bdegijklnoprtuy".map(String.init)
        for index in result.indices where result[index].isEmpty {
            let preferred = defaults[index]
            let key = !used.contains(preferred) ? preferred : candidates.first { !used.contains($0) }!
            result[index] = key; used.insert(key)
        }
        return result
    }
}
