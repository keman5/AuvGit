import SwiftUI
import AppKit
import GitCore
import AuvGitLocalization

func terminalText(_ key: String, _ arguments: CVarArg...) -> String { L10n.text(key, table: "Terminal", arguments: arguments) }

struct TerminalPane: View {
    @ObservedObject var terminals: TerminalSessions
    @ObservedObject var store: RepositoryStore
    let directory: URL
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(terminalText("title"), systemImage: "terminal").font(.system(size: 12, weight: .semibold))
                Text(directory.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled).layoutPriority(-1)
                Spacer(minLength: 0)
                Menu {
                    ForEach(terminals.sessions.keys.sorted(), id: \.self) { path in
                        Button(terminalText("closeSession", path)) { terminals.close(URL(fileURLWithPath: path)) }
                    }
                } label: { Label(terminalText("sessions", terminals.sessions.count, TerminalConfiguration.maximumSessions), systemImage: "square.stack") }
                .menuStyle(.borderlessButton).font(.system(size: 11)).fixedSize().help(terminalText("sessions", terminals.sessions.count, TerminalConfiguration.maximumSessions))
                Button { terminals.hide() } label: { Image(systemName: "chevron.down").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(terminalText("hide")).accessibilityLabel(terminalText("hide"))
                Button { terminals.close(directory); terminals.hide() } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help(terminalText("close")).accessibilityLabel(terminalText("close"))
            }.controlSize(.small).padding(.horizontal, 12).frame(height: 32)
            Divider()
            if let session = terminals.session(for: directory) {
                TerminalSessionPane(session: session, terminals: terminals, store: store)
            } else {
                VStack(spacing: 12) {
                    Text(terminalText("limit", TerminalConfiguration.maximumSessions)).foregroundStyle(.secondary)
                    Button(terminalText("start")) { terminals.show(for: directory, store: store) }.disabled(terminals.sessions.count >= TerminalConfiguration.maximumSessions)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TerminalSessionPane: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var terminals: TerminalSessions
    @ObservedObject var store: RepositoryStore
    var body: some View {
        VStack(spacing: 0) {
            TerminalHost(session: session, focusGeneration: terminals.focusGeneration)
            if session.exited {
                HStack {
                    Text(session.failedToStart ? terminalText("failed") : terminalText("exited", session.exitStatus ?? -1)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(terminalText("restart")) { terminals.restart(session.directory, store: store) }
                }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let focusGeneration: Int
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ container: NSView, context: Context) {
        session.view.setAccessibilityElement(true)
        session.view.setAccessibilityRole(.textArea)
        session.view.setAccessibilityLabel(terminalText("title") + " — " + session.directory.path)
        if session.view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            session.view.removeFromSuperview()
            session.view.frame = container.bounds
            session.view.autoresizingMask = [.width, .height]
            container.addSubview(session.view)
        }
        let generation = focusGeneration
        DispatchQueue.main.async {
            guard session.view.superview === container, session.view.window != nil, session.view.acceptsInput() else { return }
            session.startIfNeeded()
            if context.coordinator.focusGeneration != generation {
                session.view.window?.makeFirstResponder(session.view)
                context.coordinator.focusGeneration = generation
            }
        }
    }
    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        if let responder = container.window?.firstResponder as? NSView, responder.isDescendant(of: container) { container.window?.makeFirstResponder(nil) }
        container.subviews.forEach { $0.removeFromSuperview() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var focusGeneration: Int? }
}

/// Scoped to this host's window; compare/settings/sheets keep macOS's window shortcut.
struct TerminalShortcutMonitor: NSViewRepresentable {
    var isActive = true
    let toggle: () -> Void
    static func isToggleShortcut(_ event: NSEvent) -> Bool {
        event.keyCode == 50 &&
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad]) == .control
    }
    func makeNSView(context: Context) -> ShortcutView { ShortcutView(isActive: isActive, toggle: toggle) }
    func updateNSView(_ view: ShortcutView, context: Context) { view.toggle = toggle; view.isActive = isActive }
    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.removeMonitor() }
    final class ShortcutView: NSView {
        var toggle: () -> Void
        var isActive: Bool
        private var monitor: Any?
        init(isActive: Bool = true, toggle: @escaping () -> Void) { self.isActive = isActive; self.toggle = toggle; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard isActive, let window, event.window === window, window.attachedSheet == nil else { return event }
            // SwiftTerm's keyDown is not open. Reuse this existing window-
            // scoped monitor only when its terminal owns the first responder.
            if let terminal = window.firstResponder as? RepositoryTerminalView,
               NativeFocusNavigation.leaveEditor(event, from: terminal) { return nil }
            guard TerminalShortcutMonitor.isToggleShortcut(event) else { return event }
            toggle()
            return nil
        }
        func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { removeMonitor() }
    }
}
