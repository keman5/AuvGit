import Foundation
import Darwin

public struct GitError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) {
        self.message = message.replacingOccurrences(of: #"(https?://)[^/\s@]+@"#, with: "$1[redacted]@", options: .regularExpression)
    }
}
struct GitOutput: Sendable {
    let data: Data; let error: String; let code: Int32
    var text: String { String(decoding: data, as: UTF8.self) }
}
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var overflow = false
    func read(_ handle: FileHandle, onChunk: (@Sendable (String) -> Void)? = nil) {
        defer { try? handle.close() }
        while true {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { break }
            lock.lock()
            let remaining = max(0, 32 * 1024 * 1024 - bytes.count)
            bytes.append(chunk.prefix(remaining))
            if chunk.count > remaining { overflow = true }
            lock.unlock()
            onChunk?(String(decoding: chunk, as: UTF8.self))
        }
    }
    func result() -> (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (bytes, overflow) }
}
private final class GitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true
        if pid > 0 { kill(-pid, SIGTERM) }
        lock.unlock()
    }
    func install(_ value: pid_t) { lock.lock(); pid = value; if cancelled { kill(-pid, SIGTERM) }; lock.unlock() }
    func clear() { lock.lock(); pid = 0; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum GitProcess {
    static func run(at directory: URL, arguments: [String], allowedCodes: Set<Int32> = [0], timeout: TimeInterval = 120, progress: (@Sendable (String) -> Void)? = nil) async throws -> GitOutput {
        let cancellation = GitCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                try runBlocking(at: directory, arguments: arguments, allowedCodes: allowedCodes, timeout: timeout, progress: progress, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
    }
    private static func runBlocking(at directory: URL, arguments: [String], allowedCodes: Set<Int32>, timeout: TimeInterval, progress: (@Sendable (String) -> Void)?, cancellation: GitCancellation) throws -> GitOutput {
        if cancellation.isCancelled { throw CancellationError() }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_LITERAL_PATHSPECS"] = "1"
        environment["GIT_ASKPASS"] = "/usr/bin/false"; environment["SSH_ASKPASS"] = "/usr/bin/false"
        if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -oBatchMode=yes" }
        var searchPaths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(separatedBy: ":")
        for path in ["/opt/homebrew/bin", "/usr/local/bin"] where !searchPaths.contains(path) { searchPaths.append(path) }
        environment["PATH"] = searchPaths.joined(separator: ":"); environment["LC_ALL"] = "C"
        var stdoutFD = [Int32](repeating: 0, count: 2), stderrFD = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&stdoutFD) == 0 else { throw GitError("Cannot create Git output pipe.") }
        guard Darwin.pipe(&stderrFD) == 0 else { close(stdoutFD[0]); close(stdoutFD[1]); throw GitError("Cannot create Git error pipe.") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFD[1], STDERR_FILENO)
        for fd in stdoutFD + stderrFD { posix_spawn_file_actions_addclose(&actions, fd) }
        // The process group is installed atomically before exec, so descendants inherit it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = (["/usr/bin/git", "--no-pager"] + arguments).map { strdup($0) } + [nil]
        let env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) }; env.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnCode = argv.withUnsafeBufferPointer { argv in env.withUnsafeBufferPointer { env in
            posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        } }
        close(stdoutFD[1]); close(stderrFD[1])
        guard spawnCode == 0 else { close(stdoutFD[0]); close(stderrFD[0]); throw GitError("Cannot start Git: \(String(cString: strerror(spawnCode))).") }
        cancellation.install(pid)
        defer { cancellation.clear() }
        let out = Capture(), err = Capture(), readers = DispatchGroup()
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD[0], closeOnDealloc: true), stderrHandle = FileHandle(fileDescriptor: stderrFD[0], closeOnDealloc: true)
        readers.enter(); DispatchQueue.global().async { out.read(stdoutHandle); readers.leave() }
        readers.enter(); DispatchQueue.global().async { err.read(stderrHandle, onChunk: progress); readers.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0, stopped: Date?, timedOut = false, wasCancelled = false
        var waitFailure: Int32?
        while true {
            var info = siginfo_t()
            let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == -1 {
                if errno == EINTR { continue }
                waitFailure = errno; break
            }
            if info.si_pid == pid { break }
            if cancellation.isCancelled || Date() >= deadline {
                wasCancelled = cancellation.isCancelled; timedOut = !wasCancelled
                if stopped == nil { stopped = Date(); kill(-pid, SIGTERM) }
                if let stopped, Date().timeIntervalSince(stopped) >= 0.5 { kill(-pid, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        wasCancelled = wasCancelled || cancellation.isCancelled
        // Keep the exited leader unreaped until all group signalling is complete, avoiding PID reuse.
        if wasCancelled || timedOut || (waitFailure != nil && waitFailure != ECHILD) { kill(-pid, SIGKILL) }
        let retainedOutput = readers.wait(timeout: .now() + 2) == .timedOut
        if retainedOutput { kill(-pid, SIGKILL); _ = readers.wait(timeout: .now() + 1) }
        wasCancelled = wasCancelled || cancellation.isCancelled
        if wasCancelled { kill(-pid, SIGKILL) }
        cancellation.clear()
        var reap: pid_t
        repeat { reap = waitpid(pid, &status, 0) } while reap == -1 && errno == EINTR
        if wasCancelled { throw CancellationError() }
        if let waitFailure { throw GitError("Cannot wait for Git: \(String(cString: strerror(waitFailure))).") }
        if reap == -1 { throw GitError("Cannot collect Git exit status: \(String(cString: strerror(errno))).") }
        if retainedOutput { throw GitError("Git exited but an external helper kept its output stream open.") }
        if timedOut { throw GitError("Git operation timed out after \(Int(timeout)) seconds.") }
        let (data, oversized) = out.result(), (errorData, errorOversized) = err.result()
        if oversized || errorOversized { throw GitError("Git output exceeds the 32 MB display limit.") }
        let code: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        let output = GitOutput(data: data, error: String(decoding: errorData, as: UTF8.self), code: code)
        if !allowedCodes.contains(code), output.error.contains("git-lfs"), output.error.contains("not found") || output.error.contains("No such file") {
            throw GitError("Git LFS is required by this repository but git-lfs was not found. Install Git LFS or add its executable directory to PATH, then reopen RayGit.")
        }
        if !allowedCodes.contains(code) { throw GitError(output.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Git command failed (\(code))." : output.error.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return output
    }
}
