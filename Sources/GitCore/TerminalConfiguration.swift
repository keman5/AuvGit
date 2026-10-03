import Foundation

/// Arguments and cwd are passed directly to exec; repository paths never become shell code.
public struct TerminalConfiguration {
    public let directory: URL
    public let executable: String
    public let arguments: [String]
    public let environment: [String]
    public static let maximumSessions = 8

    public init(directory: URL, inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment, userShell: String? = nil) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = userShell ?? inheritedEnvironment["SHELL"] ?? "/bin/zsh"
        executable = candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
        arguments = ["-l", "-i"]
        var values = inheritedEnvironment
        values["TERM"] = "xterm-256color"
        values["COLORTERM"] = "truecolor"
        values["PWD"] = self.directory.path
        values["SHELL"] = executable
        if values["LANG"] == nil { values["LANG"] = "en_US.UTF-8" }
        if values["PATH"] == nil { values["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
        environment = values.keys.sorted().map { "\($0)=\(values[$0]!)" }
    }

    public static func identity(for directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
