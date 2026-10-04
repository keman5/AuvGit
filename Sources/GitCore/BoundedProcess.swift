import Foundation

public enum BoundedProcessError: Error { case timedOut }

/// A cancellable subprocess with bounded lifetime and discarded diagnostics.
/// Intended for providers that return their result in an explicitly named file.
public final class BoundedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    private func stop() {
        lock.lock(); cancelled = true; let active = process; lock.unlock()
        guard let active, active.isRunning else { return }
        active.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { if active.isRunning { kill(active.processIdentifier, SIGKILL) } }
    }
    public func run(executable: URL, arguments: [String], directory: URL, environment: [String: String], input: URL, timeout: TimeInterval = 90) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let handle = try FileHandle(forReadingFrom: input); defer { try? handle.close() }
                        let active = Process(); active.executableURL = executable; active.arguments = arguments
                        active.currentDirectoryURL = directory; active.environment = environment
                        active.standardInput = handle; active.standardOutput = FileHandle.nullDevice; active.standardError = FileHandle.nullDevice
                        let ended = DispatchSemaphore(value: 0); active.terminationHandler = { _ in ended.signal() }
                        self.lock.lock()
                        guard !self.cancelled else { self.lock.unlock(); throw CancellationError() }
                        self.process = active
                        do { try active.run() } catch { self.lock.unlock(); throw error }
                        self.lock.unlock()
                        if ended.wait(timeout: .now() + max(0.01, timeout)) == .timedOut {
                            self.stop(); _ = ended.wait(timeout: .now() + 2)
                            throw BoundedProcessError.timedOut
                        }
                        self.lock.lock(); let wasCancelled = self.cancelled; self.process = nil; self.lock.unlock()
                        if wasCancelled { throw CancellationError() }
                        continuation.resume(returning: active.terminationStatus)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.stop() }
    }
}
