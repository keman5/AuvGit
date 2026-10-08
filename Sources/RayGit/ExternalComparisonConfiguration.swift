import Foundation

enum ExternalComparisonConfiguration {
    static let beyondCompare = "/Applications/Beyond Compare.app/Contents/MacOS/bcomp"
    static let compareArguments = #"["-solo", "-ro", "{left}", "{right}"]"#
    static let mergeArguments = #"["-solo", "{left}", "{right}", "{base}", "{result}"]"#
    static var defaultExecutable: String {
        FileManager.default.isExecutableFile(atPath: beyondCompare) ? beyondCompare : ""
    }
    static func executable(_ path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        let launcher = url.appendingPathComponent("Contents/MacOS/bcomp")
        return url.pathExtension == "app" && FileManager.default.isExecutableFile(atPath: launcher.path) ? launcher : url
    }
}
