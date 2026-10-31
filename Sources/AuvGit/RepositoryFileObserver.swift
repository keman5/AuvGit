import Foundation
import CoreServices

/// Recursive filesystem events include content changes even when Git status stays M.
final class RepositoryFileObserver {
    struct Changes {
        var paths: Set<String> = []
        var directories: Set<String> = []
        var requiresRescan = false
        mutating func merge(_ other: Self) {
            paths.formUnion(other.paths)
            directories.formUnion(other.directories)
            requiresRescan = requiresRescan || other.requiresRescan
        }
    }
    private var stream: FSEventStreamRef?
    private let changed: (Changes) -> Void
    init(paths: [String], changed: @escaping (Changes) -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let observer = Unmanaged<RepositoryFileObserver>.fromOpaque(info).takeUnretainedValue()
            let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var changes = Changes()
            for index in 0..<count {
                let path = String(cString: names[index])
                changes.paths.insert(path)
                if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { changes.directories.insert(path) }
                let dropped = kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
                if flags[index] & FSEventStreamEventFlags(dropped) != 0 { changes.requiresRescan = true }
            }
            observer.changed(changes)
        }
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}

/// Unknown paths and dropped events always fall back to a complete check.
enum RepositoryEventScope {
    static func classify(_ changes: RepositoryFileObserver.Changes, root: URL, metadata: [String]) -> (full: Bool, worktree: [String]) {
        if changes.requiresRescan { return (true, []) }
        let rootPath = root.standardizedFileURL.path
        var worktree = Set<String>()
        for path in changes.paths {
            if let directory = metadata.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                let relative = String(path.dropFirst(directory.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                // Dropping an older stash rewrites its reflog without changing refs/stash.
                if relative == "logs/refs/stash" { return (true, []) }
                if relative.hasPrefix("objects/") || relative.hasPrefix("logs/") || relative.hasSuffix(".lock") || ["objects", "logs", "FETCH_HEAD", "COMMIT_EDITMSG"].contains(relative) { continue }
                return (true, [])
            }
            guard path.hasPrefix(rootPath + "/") else { return (true, []) }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if relative == ".git" || relative.hasPrefix(".git/") { return (true, []) }
            // A directory rename/deletion can contain tracked descendants even
            // when Git ignores the directory itself.
            if changes.directories.contains(path) { return (true, []) }
            worktree.insert(relative)
        }
        return (false, worktree.sorted())
    }
}
