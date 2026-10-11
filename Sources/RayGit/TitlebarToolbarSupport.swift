import AppKit
import SwiftUI
import RayGitLocalization

/// Installs a forwarding toolbar delegate to expose AppKit's repeatable spaces.
/// SwiftUI's original delegate still creates and manages all ordinary toolbar items.
struct TitlebarToolbarSupport: NSViewRepresentable {
    var shellContent: ((BorderlessToolbarModel) -> NSView)? = nil
    var hidesNativeToolbar = false
    var shellWindowTitle: String? = nil
    func makeNSView(context: Context) -> TitlebarView { let view = TitlebarView(); view.shellContent = shellContent; view.hidesNativeToolbar = hidesNativeToolbar; view.shellWindowTitle = shellWindowTitle; return view }
    func updateNSView(_ nsView: TitlebarView, context: Context) { nsView.shellContent = shellContent; nsView.hidesNativeToolbar = hidesNativeToolbar; nsView.shellWindowTitle = shellWindowTitle; nsView.scheduleToolbarConfiguration() }

    final class TitlebarView: NSView {
        var shellContent: ((BorderlessToolbarModel) -> NSView)?
        var hidesNativeToolbar = false
        var shellWindowTitle: String?
        private var eventMonitor: Any?
        private var customizationDelegate: SpaceCustomizationDelegate?
        private var titleVisibilityObservation: NSKeyValueObservation?
        private var configurationPending = false

        func scheduleToolbarConfiguration() {
            // SwiftUI may order its window before the deferred toolbar is ready.
            // Keep that placeholder invisible until the restored shell is shown.
            if let window, !hidesNativeToolbar, shellContent != nil, EightPointWindowShell.usesBorderlessMode {
                window.alphaValue = 0
            }
            guard !configurationPending else { return }
            configurationPending = true
            DispatchQueue.main.async { [weak self] in
                self?.configurationPending = false
                self?.configureToolbar()
            }
        }

        private func configureToolbar() {
            guard let window else { return }
            if hidesNativeToolbar {
                if window.toolbar?.isVisible == true { window.toolbar?.isVisible = false }
                if let shellWindowTitle, window.title != shellWindowTitle {
                    window.title = shellWindowTitle
                    (window.contentView as? EightPointFrameView)?.updateTitle()
                }
                return
            }
            EightPointWindowShell.install(on: window, content: shellContent)
            if let toolbar = window.toolbar, let delegate = toolbar.delegate,
               !(delegate is SpaceCustomizationDelegate) {
                let proxy = SpaceCustomizationDelegate(original: delegate)
                customizationDelegate = proxy
                toolbar.delegate = proxy
            }
            // Hide the expanding unified title on older systems; newer systems
            // remove it through MainWindow's toolbar title modifier.
            if #unavailable(macOS 15.0) {
                window.titleVisibility = .hidden
                if titleVisibilityObservation == nil {
                    titleVisibilityObservation = window.observe(\.titleVisibility) { window, _ in
                        guard window.titleVisibility != .hidden else { return }
                        window.titleVisibility = .hidden
                    }
                }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
            guard window != nil else { return }
            scheduleToolbarConfiguration()
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      let toolbar = window.toolbar, toolbar.allowsUserCustomization,
                      !toolbar.customizationPaletteIsRunning else { return event }
                let titlebarBottom = window.contentLayoutRect.maxY
                guard event.locationInWindow.y >= titlebarBottom else { return event }
                // Toolbar items retain AppKit's own Remove From Toolbar menu.
                if let frameView = window.contentView?.superview {
                    let point = frameView.convert(event.locationInWindow, from: nil)
                    var hitView = frameView.hitTest(point)
                    while let view = hitView {
                        if view is NSButton || NSStringFromClass(type(of: view)).contains("ToolbarItem") { return event }
                        hitView = view.superview
                    }
                }
                let menu = NSMenu()
                let item = NSMenuItem(title: L10n.text("customizeToolbar", table: "Main"), action: #selector(self.customizeToolbar(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
                NSMenu.popUpContextMenu(menu, with: event, for: window.contentView ?? self)
                return nil
            }
        }

        @objc private func customizeToolbar(_ sender: Any?) {
            configureToolbar()
            window?.toolbar?.runCustomizationPalette(sender)
        }

        deinit {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }
    }
}


/// Forward SwiftUI item creation and restoration unchanged while exposing AppKit's
/// repeatable spaces in the customization palette.
private final class SpaceCustomizationDelegate: NSObject, NSToolbarDelegate {
    private let original: NSToolbarDelegate
    init(original: NSToolbarDelegate) { self.original = original; super.init() }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original.responds(to: selector)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? {
        original.responds(to: selector) ? original : super.forwardingTarget(for: selector)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers = original.toolbarAllowedItemIdentifiers?(toolbar) ?? []
        for identifier in [NSToolbarItem.Identifier.space, .flexibleSpace] where !identifiers.contains(identifier) {
            identifiers.append(identifier)
        }
        return identifiers
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        original.toolbarDefaultItemIdentifiers?(toolbar) ?? []
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .space || identifier == .flexibleSpace { return NSToolbarItem(itemIdentifier: identifier) }
        return original.toolbar?(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: flag)
    }
}
