import Foundation

public struct GitError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) {
        self.message = message.replacingOccurrences(of: #"(https?://)[^/\s@]+@"#, with: "$1[redacted]@", options: .regularExpression)
    }
}

struct GitOutput: Sendable { let data: Data; let error: String; let code: Int32
    var text: String { String(decoding: data, as: UTF8.self) }
}
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func read(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            lock.lock()
            let remaining = max(0, 32 * 1024 * 1024 - bytes.count)
            bytes.append(chunk.prefix(remaining))
            if chunk.count > remaining { overflow = true }
            lock.unlock()
        }
    }
    func result() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, overflow) }
}

enum GitProcess {
    static func run(at directory: URL, arguments: [String], allowedCodes: Set<Int32> = [0]) async throws -> GitOutput {
        try await Task.detached(priority: .userInitiated) {
            try runBlocking(at: directory, arguments: arguments, allowedCodes: allowedCodes)
        }.value
    }
    private static func runBlocking(at directory: URL, arguments: [String], allowedCodes: Set<Int32>) throws -> GitOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = directory
            process.arguments = ["--no-pager"] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_LITERAL_PATHSPECS"] = "1"
            environment["GIT_ASKPASS"] = "/usr/bin/false"
            environment["SSH_ASKPASS"] = "/usr/bin/false"
            environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes"
            environment["LC_ALL"] = "C"
            process.environment = environment
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout; process.standardError = stderr; process.standardInput = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            let out = Capture(), err = Capture(), readers = DispatchGroup()
            readers.enter(); DispatchQueue.global().async { out.read(stdout.fileHandleForReading); readers.leave() }
            readers.enter(); DispatchQueue.global().async { err.read(stderr.fileHandleForReading); readers.leave() }
            let timedOut = done.wait(timeout: .now() + 120) == .timedOut
            if timedOut {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = done.wait(timeout: .now() + 2)
                }
                throw GitError("Git operation timed out after 120 seconds.")
            }
            // A hook/SSH descendant may retain inherited pipe handles after Git exits.
            // Bound this wait too, so that such descendants cannot block the caller.
            if readers.wait(timeout: .now() + 2) == .timedOut {
                throw GitError("Git exited but an external helper kept its output stream open.")
            }
            let (data, oversized) = out.result(), (errorData, errorOversized) = err.result()
            if oversized || errorOversized { throw GitError("Git output exceeds the 32 MB display limit.") }
            let output = GitOutput(data: data, error: String(decoding: errorData, as: UTF8.self), code: process.terminationStatus)
            if !allowedCodes.contains(output.code) { throw GitError(output.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Git command failed (\(output.code))." : output.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return output
    }
}
