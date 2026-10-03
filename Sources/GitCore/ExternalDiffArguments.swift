import Foundation

public enum ExternalDiffArguments {
    /// One array element becomes one argv element. Expansion never invokes a shell or reparses spaces.
    public static func expand(_ template: [String], files: [String: String]) throws -> [String] {
        guard !template.isEmpty, template.count <= 100 else { throw GitError("Provide 1–100 external tool arguments.") }
        let allowed = Set(["left", "right", "base", "result"])
        let regex = try NSRegularExpression(pattern: #"\{([^{}]+)\}"#)
        return try template.map { argument in
            guard !argument.contains("\0"), argument.utf8.count <= 8192 else { throw GitError("Invalid external tool argument.") }
            var value = argument
            for match in regex.matches(in: argument, range: NSRange(location: 0, length: argument.utf16.count)).reversed() {
                let name = (argument as NSString).substring(with: match.range(at: 1))
                guard allowed.contains(name), let file = files[name] else { throw GitError("External tool template references an unavailable version: \(name).") }
                value = (value as NSString).replacingCharacters(in: match.range, with: file)
            }
            return value
        }
    }
    public static func parse(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else { throw GitError("Arguments must be a JSON array of strings.") }
        _ = try expand(values, files: ["left": "left", "right": "right", "base": "base", "result": "result"])
        return values
    }
}
