import AppKit
import SwiftUI
import SwiftTerm
import GitCore

final class RepositoryTerminalView: LocalProcessTerminalView {
    var acceptsInput: () -> Bool = { false }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateNativeColors()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateNativeColors()
    }
    fileprivate func updateNativeColors() {
        // SwiftTerm converts colors to RGB immediately, outside AppKit's drawing context.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeBackgroundColor = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
            nativeForegroundColor = NSColor.textColor.usingColorSpace(.sRGB)!
        }
    }
    override func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) {
        // Emulator replies (e.g. cursor-position queries) must keep working in hidden sessions.
        // User input reaches the distinct TerminalView delegate overload below.
        guard process?.running == true else { return }
        process.send(data: data)
    }
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard acceptsInput() else { return }
        super.send(source: source, data: data)
    }
}

final class TerminalSession: ObservableObject, LocalProcessTerminalViewDelegate {
    let directory: URL
    let view: RepositoryTerminalView
    @Published private(set) var exited = false
    @Published private(set) var exitStatus: Int32?
    @Published private(set) var failedToStart = false
    private var started = false
    private var stopped = false

    init(directory: URL) {
        self.directory = directory
        view = RepositoryTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 240), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: TerminalOptions(scrollback: 5000))
        view.updateNativeColors()
        view.processDelegate = self
    }

    func startIfNeeded() {
        guard !started, !stopped else { return }
        started = true
        let configuration = TerminalConfiguration(directory: directory, userShell: NSUserName().withCString { name in
            guard let account = getpwnam(name), let shell = account.pointee.pw_shell else { return nil }
            return String(cString: shell)
        })
        view.startProcess(executable: configuration.executable, args: configuration.arguments, environment: configuration.environment, currentDirectory: configuration.directory.path)
        failedToStart = !view.process.running
        exited = failedToStart
    }

    func stop(immediately: Bool = false) {
        guard !stopped else { return }
        stopped = true
        view.acceptsInput = { false }
        if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        // Capture the foreground job before closing the PTY.
        if view.process.running {
            let group = view.process.childfd >= 0 ? tcgetpgrp(view.process.childfd) : 0
            TerminalProcessShutdown.terminate(shellPID: view.process.shellPid, foregroundGroup: group, immediately: immediately)
            view.terminate()
        }
        view.removeFromSuperview()
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard !stopped else { return }
        // SwiftTerm exposes waitpid's raw status; decode it for the visible exit label.
        exitStatus = exitCode.map { ($0 & 0x7f) == 0 ? ($0 >> 8) & 0xff : 128 + ($0 & 0x7f) }
        exited = true
    }
}

final class TerminalSessions: ObservableObject {
    @Published private(set) var sessions: [String: TerminalSession] = [:]
    @Published var visible = false
    @Published private(set) var focusGeneration = 0
    private var terminationObserver: NSObjectProtocol?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.closeAll(immediately: true)
        }
    }
    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        for session in sessions.values { session.stop(immediately: true) }
    }
    func session(for directory: URL?) -> TerminalSession? {
        directory.flatMap { sessions[TerminalConfiguration.identity(for: $0)] }
    }
    func show(for directory: URL, store: RepositoryStore) {
        visible = true
        let path = TerminalConfiguration.identity(for: directory)
        if sessions[path] == nil, sessions.count < TerminalConfiguration.maximumSessions {
            let session = TerminalSession(directory: URL(fileURLWithPath: path))
            session.view.acceptsInput = { [weak self, weak store, weak session] in
                // SwiftTerm sends keyboard and terminal-reply data on the AppKit main queue.
                MainActor.assumeIsolated {
                    guard let self, let current = store?.repositoryURL else { return false }
                    return self.visible && TerminalConfiguration.identity(for: current) == path && self.sessions[path] === session
                }
            }
            sessions[path] = session
        }
        focusGeneration += 1
    }
    func toggle(for directory: URL?, store: RepositoryStore) {
        guard let directory else { return }
        if visible { hide() } else { show(for: directory, store: store) }
    }
    func hide() {
        for session in sessions.values where session.view.window?.firstResponder === session.view { session.view.window?.makeFirstResponder(nil) }
        visible = false
    }
    func close(_ directory: URL) {
        let path = TerminalConfiguration.identity(for: directory)
        sessions.removeValue(forKey: path)?.stop()
    }
    func restart(_ directory: URL, store: RepositoryStore) { close(directory); show(for: directory, store: store) }
    func retainRepositories(_ paths: [String]) {
        let retained = Set(paths.map { TerminalConfiguration.identity(for: URL(fileURLWithPath: $0)) })
        for path in Array(sessions.keys) where !retained.contains(path) { sessions.removeValue(forKey: path)?.stop() }
    }
    func closeAll(immediately: Bool = false) {
        for session in sessions.values { session.stop(immediately: immediately) }
        sessions.removeAll()
    }
}
