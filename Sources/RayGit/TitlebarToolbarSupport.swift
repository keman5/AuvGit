import AppKit
import SwiftUI
import RayGitLocalization

/// Extends the native customization menu without replacing SwiftUI's toolbar delegate.
/// SwiftUI must own its item identifiers and restoration state through every view update.
struct TitlebarToolbarSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> TitlebarView { TitlebarView() }
    func updateNSView(_ nsView: TitlebarView, context: Context) { nsView.scheduleToolbarConfiguration() }

    final class TitlebarView: NSView {
        private var eventMonitor: Any?
        private var titleVisibilityObservation: NSKeyValueObservation?

        func scheduleToolbarConfiguration() {
            DispatchQueue.main.async { [weak self] in self?.configureToolbar() }
        }

        private func configureToolbar() {
            guard let window else { return }
            // The unified window title reserves flexible width outside the toolbar.
            // MainWindow displays the title as a normal item so native flexible
            // spaces can use all remaining width within the single toolbar row.
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

