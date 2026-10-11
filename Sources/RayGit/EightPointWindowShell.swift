import AppKit
import SwiftUI

/// Public eight-point main-window shell. Native mode is an explicit fallback.
@MainActor
enum EightPointWindowShell {
    private static let installed = NSHashTable<NSWindow>.weakObjects()
    private static var controllers: [ObjectIdentifier: NSWindowController] = [:]
    private static var requestedMode: String? {
        if let index = CommandLine.arguments.firstIndex(of: "--window-frame") ?? CommandLine.arguments.firstIndex(of: "--window-frame-prototype"), CommandLine.arguments.indices.contains(index + 1) { return CommandLine.arguments[index + 1] }
        return UserDefaults.standard.string(forKey: "window.frameMode") ?? UserDefaults.standard.string(forKey: "window.framePrototype") ?? "borderless"
    }
    static var usesBorderlessMode: Bool { requestedMode == "borderless" }
    static func install(on window: NSWindow, content: ((BorderlessToolbarModel) -> NSView)?) {
        guard !installed.contains(window) else { return }
        let mode = requestedMode
        guard mode == "native" || mode == "borderless" else { return }
        installed.add(window)
        if mode == "native" { return }
        else if let content {
            let toolbarModel = BorderlessToolbarModel(original: window.toolbar)
            let shell = BorderlessShellWindow(contentRect: window.frame, styleMask: [.borderless, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            shell.title = window.title
            shell.isOpaque = false; shell.backgroundColor = .clear; shell.hasShadow = true
            shell.isReleasedWhenClosed = false
            shell.minSize = NSSize(width: max(1000, window.minSize.width), height: max(714, window.minSize.height))
            shell.collectionBehavior = [.managed, .fullScreenPrimary]
            shell.contentView = EightPointFrameView(content: content(toolbarModel))
            let key = ObjectIdentifier(window)
            let controller = BorderlessShellController(window: shell, original: window) { [weak window] in
                controllers.removeValue(forKey: key)
                if let window { installed.remove(window) }
            }
            controllers[key] = controller
            let saved = UserDefaults.standard.string(forKey: BorderlessShellController.framePreference).flatMap { WindowShellGeometry.restore(NSRectFromString($0), minimum: shell.minSize, screens: NSScreen.screens.map(\.visibleFrame)) }
            shell.setFrame(saved ?? window.frame, display: false)
            window.orderOut(nil)
            controller.showWindow(nil); shell.makeKeyAndOrderFront(nil)
        }
    }
}

private final class BorderlessShellController: NSWindowController, NSWindowDelegate {
    private weak var original: NSWindow?
    static let framePreference = "window.shellFrame.v1"
    private var transitioningFullScreen = false
    private let closed: () -> Void
    init(window: NSWindow, original: NSWindow, closed: @escaping () -> Void) { self.original = original; self.closed = closed; super.init(window: window); window.delegate = self }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func saveFrame() {
        guard !transitioningFullScreen, let window, !window.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.framePreference)
    }
    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowWillEnterFullScreen(_ notification: Notification) { saveFrame(); transitioningFullScreen = true }
    func windowDidEnterFullScreen(_ notification: Notification) { transitioningFullScreen = false }
    func windowWillExitFullScreen(_ notification: Notification) { transitioningFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { transitioningFullScreen = false; saveFrame() }
    func windowWillClose(_ notification: Notification) { saveFrame(); original?.close(); closed() }
}

private final class BorderlessShellWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class EightPointFrameView: NSView {
    private let hosted: NSView
    private let chrome: ShellTitlebar
    private let edges: ShellResizeEdges
    init(content: NSView) {
        hosted = content
        chrome = ShellTitlebar(frame: .zero)
        edges = ShellResizeEdges(frame: .zero)
        super.init(frame: content.frame)
        wantsLayer = true; layer?.cornerRadius = RayGitStyle.windowCornerRadius; layer?.masksToBounds = true
        addSubview(hosted)
        addSubview(chrome)
        addSubview(edges)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Native sheet dimming is a sibling of the content view. Clip the whole
        // frame so the dimmer cannot fill the transparent eight-point corners.
        if let window { WindowFrameAppearance.clip(window) }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    func updateTitle() { chrome.needsLayout = true }
    override func layout() {
        super.layout()
        hosted.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 34))
        chrome.frame = NSRect(x: 0, y: max(0, bounds.height - 34), width: bounds.width, height: 34)
        edges.frame = bounds
    }
}

private final class ShellTitlebar: NSView {
    private let title = ShellTitleField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = NSWindow.standardWindowButton(type, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
            button.frame = NSRect(x: 12 + CGFloat(index) * 20, y: 10, width: 14, height: 14)
            button.target = self
            button.action = index == 0 ? #selector(closeWindow) : index == 1 ? #selector(minimizeWindow) : #selector(fullScreenWindow)
            addSubview(button)
        }
        title.font = .systemFont(ofSize: 12, weight: .medium); title.lineBreakMode = .byTruncatingMiddle
        title.alignment = .center; addSubview(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); title.stringValue = window?.title ?? ""
        title.frame = NSRect(x: 84, y: 9, width: max(0, bounds.width - 168), height: 18)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.zoom(nil) }
        else { window?.performDrag(with: event) }
    }
    @objc private func closeWindow() {
        guard let window, window.delegate?.windowShouldClose?(window) != false else { return }
        window.close()
    }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func fullScreenWindow() { window?.toggleFullScreen(nil) }
}

private final class ShellTitleField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Public NSWindow frame operations support all four edges on every display.
private final class ShellResizeEdges: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local), window?.styleMask.contains(.fullScreen) != true else { return nil }
        return WindowShellGeometry.edges(at: local, in: bounds).isEmpty ? nil : self
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initial = window.frame, mouse = window.convertPoint(toScreen: event.locationInWindow)
        let edges = WindowShellGeometry.edges(at: convert(event.locationInWindow, from: nil), in: bounds)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            let frame = WindowShellGeometry.resize(initial, edges: edges, delta: NSPoint(x: current.x - mouse.x, y: current.y - mouse.y), minimum: window.minSize)
            window.setFrame(frame, display: true)
        }
    }
}

/// Clip both the content and the native frame containing sheet dimming.
@MainActor
enum WindowFrameAppearance {
    static func clip(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.cornerRadius = RayGitStyle.windowCornerRadius
            view.layer?.masksToBounds = true
        }
    }
}
