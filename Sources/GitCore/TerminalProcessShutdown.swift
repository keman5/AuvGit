#if os(macOS)
import Foundation
import Darwin

/// Stop the shell and its current descendants, including foreground job process groups.
/// Check each process's kernel start time before signalling, including escalation.
public enum TerminalProcessShutdown {
    public static func terminate(shellPID: pid_t, foregroundGroup: pid_t = 0, immediately: Bool = false) {
        guard shellPID > 0 else { return }
        guard let shell = identity(shellPID) else { return }
        var buffer = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
        let count = buffer.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        let processes = buffer.prefix(max(0, Int(count))).compactMap(identity)
        var pids: Set<pid_t> = [shellPID]
        var changed = true
        while changed {
            changed = false
            for process in processes where pids.contains(process.parent) || process.group == shellPID || (foregroundGroup > 0 && process.group == foregroundGroup) {
                if pids.insert(process.pid).inserted { changed = true }
            }
        }
        // Retained by the source handlers and released when every source exits or times out.
        let cleanup = Cleanup(processes: processes.filter { pids.contains($0.pid) } + [shell], shellPID: shellPID)
        cleanup.start(immediately: immediately)
    }

    private struct Identity: Equatable {
        let pid: pid_t
        let parent: pid_t
        let group: pid_t
        let seconds: UInt64
        let microseconds: UInt64
    }
    private static func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return Identity(pid: pid, parent: pid_t(info.pbi_ppid), group: pid_t(info.pbi_pgid), seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }
    private final class Cleanup {
        let shellPID: pid_t
        let identities: [pid_t: Identity]
        var sources: [pid_t: DispatchSourceProcess] = [:]
        init(processes: [Identity], shellPID: pid_t) {
            self.shellPID = shellPID
            identities = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            for pid in identities.keys where pid != getpid() && pid > 1 {
                sources[pid] = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            }
        }
        func start(immediately: Bool) {
            for (pid, source) in sources {
                source.setEventHandler { [self] in
                    if pid == shellPID { var status: Int32 = 0; _ = waitpid(pid, &status, WNOHANG) }
                    sources.removeValue(forKey: pid)?.cancel()
                }
                source.activate()
            }
            for pid in sources.keys { signal(pid, SIGHUP); signal(pid, SIGTERM) }
            if immediately { for pid in sources.keys { signal(pid, SIGKILL) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                for pid in sources.keys { signal(pid, SIGKILL) }
            }
            // No indefinitely retained dispatch sources if an uninterruptible child remains.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                for source in sources.values { source.cancel() }
                sources.removeAll()
            }
        }
        func signal(_ pid: pid_t, _ value: Int32) {
            guard let expected = identities[pid], let current = identity(pid), expected.seconds == current.seconds, expected.microseconds == current.microseconds else { return }
            _ = kill(pid, value)
        }
    }
}
#endif
