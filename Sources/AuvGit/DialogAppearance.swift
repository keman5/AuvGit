import AppKit
import SwiftUI

struct AuvGitDialogButtonStyle: PrimitiveButtonStyle {
    static let minimumWidth: CGFloat = 80
    static let height: CGFloat = 28
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.frame(minWidth: Self.minimumWidth)
        }
        Group {
            if prominent { button.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            else { button.buttonStyle(.bordered) }
        }.controlSize(.regular).frame(height: Self.height)
    }
}

/// Explicit dialog actions use the native button for rendering and activation.
struct DialogButton: View {
    let title: String
    var prominent = false
    var role: ButtonRole? = nil
    let action: () -> Void
    init(_ title: String, prominent: Bool = false, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.prominent = prominent; self.role = role; self.action = action
    }
    var body: some View {
        KeyViewProxy(label: title, keyEquivalent: role == .cancel ? "\u{1b}" : "", prominent: prominent,
                     minimumWidth: AuvGitDialogButtonStyle.minimumWidth, tint: role == .destructive ? .systemRed : nil, action: action)
    }
}

extension View {
    func auvGitPopover<Content: View>(isPresented: Binding<Bool>, arrowEdge: Edge = .top,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented, arrowEdge: arrowEdge) { content().nativeFocusRoot() }
    }
    func auvGitSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().nativeFocusRoot(focusesOnPresentation: true).background(Color(nsColor: .windowBackgroundColor)).background(DialogFrameStyle())
                .presentationCornerRadius(AuvGitStyle.windowCornerRadius)
        }
    }
    func auvGitSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, focusesOnPresentation: Bool = true,
                                                       @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).nativeFocusRoot(focusesOnPresentation: focusesOnPresentation).background(Color(nsColor: .windowBackgroundColor)).background(DialogFrameStyle())
                .presentationCornerRadius(AuvGitStyle.windowCornerRadius)
        }
    }
    func auvGitAlert<Message: View>(_ title: String, isPresented: Binding<Bool>,
                                    @AuvGitAlertActions actions: @escaping () -> [AuvGitAlertButton],
                                    @ViewBuilder message: @escaping () -> Message) -> some View {
        auvGitSheet(isPresented: isPresented) {
            AuvGitAlertView(title: title, message: message(), buttons: actions()) { isPresented.wrappedValue = false }
        }
    }
    func auvGitAlert(_ title: String, isPresented: Binding<Bool>,
                     @AuvGitAlertActions actions: @escaping () -> [AuvGitAlertButton]) -> some View {
        auvGitAlert(title, isPresented: isPresented, actions: actions) { EmptyView() }
    }
    func auvGitAlert<Item: Identifiable>(item: Binding<Item?>, focusesOnPresentation: Bool = true,
                                         content: @escaping (Item) -> AuvGitAlert) -> some View {
        auvGitSheet(item: item, focusesOnPresentation: focusesOnPresentation) { value in
            let alert = content(value)
            AuvGitAlertView(title: alert.title, message: Text(alert.message), buttons: alert.buttons) { item.wrappedValue = nil }
        }
    }
}

struct AuvGitAlert {
    let title: String
    let message: String
    let buttons: [AuvGitAlertButton]
}

struct AuvGitAlertButton {
    let title: String
    let role: ButtonRole?
    let action: () -> Void
    var isDisabled = false
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void = {}) {
        self.title = title; self.role = role; self.action = action
    }
    func disabled(_ value: Bool) -> Self { var button = self; button.isDisabled = value; return button }
}

@resultBuilder
enum AuvGitAlertActions {
    static func buildBlock(_ buttons: AuvGitAlertButton...) -> [AuvGitAlertButton] { buttons }
}

private struct AuvGitAlertView<Message: View>: View {
    let title: String
    let message: Message
    let buttons: [AuvGitAlertButton]
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline)
            ViewThatFits(in: .vertical) {
                message.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    message.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxHeight: 320)
            HStack {
                ForEach(buttons.indices, id: \.self) { index in
                    let button = buttons[index]
                    KeyViewProxy(label: button.title,
                        keyEquivalent: button.role == .cancel ? "\u{1b}" :
                            index == DialogAppearance.defaultButtonIndex(buttons) ? "\r" : "",
                        prominent: index == DialogAppearance.defaultButtonIndex(buttons),
                        minimumWidth: AuvGitDialogButtonStyle.minimumWidth) { button.action(); close() }
                        .disabled(button.isDisabled)
                }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(AuvGitDialogButtonStyle()).padding(24).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .onExitCommand {
                guard let cancel = buttons.first(where: { $0.role == .cancel && !$0.isDisabled }) else { return }
                cancel.action(); close()
            }
    }
}

@MainActor
enum DialogAppearance {
    private static var sheetShells: [ObjectIdentifier: DialogSheetShell] = [:]

    static func visibleWindow(for sheet: NSWindow) -> NSWindow {
        sheetShells[ObjectIdentifier(sheet)]?.panel ?? sheet
    }

    static func boundedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        let available = visibleFrame.insetBy(dx: 16, dy: 16)
        let size = NSSize(width: min(frame.width, max(1, available.width)),
                          height: min(frame.height, max(1, available.height)))
        return NSRect(x: max(available.minX, min(frame.minX, available.maxX - size.width)),
                      y: max(available.minY, min(frame.minY, available.maxY - size.height)),
                      width: size.width, height: size.height)
    }

    static func fileListSummary(_ paths: [String]) -> String {
        paths.count > 20 ? interactionText("File Count Summary", paths.count) : paths.joined(separator: "\n")
    }

    static func prepareSheet(_ window: NSWindow) {
        guard !(window is DialogPanel) else { return }
        // Hide the native modal frame before its first display, not one main
        // queue turn later when the borderless shell takes over.
        window.alphaValue = 0
        window.animationBehavior = .none
    }

    static func defaultButtonIndex(_ buttons: [AuvGitAlertButton]) -> Int? {
        buttons.firstIndex { !$0.isDisabled && $0.role == nil }
            ?? buttons.firstIndex { !$0.isDisabled && $0.role == .cancel }
            ?? buttons.firstIndex { !$0.isDisabled }
    }

    static func style(_ window: NSWindow) {
        if window.sheetParent != nil, !(window is DialogPanel) {
            let key = ObjectIdentifier(window)
            if sheetShells[key] == nil {
                sheetShells[key] = DialogSheetShell(original: window) { sheetShells.removeValue(forKey: key) }
            }
            return
        }
        if !(window is DialogPanel) {
            window.styleMask.insert([.titled, .fullSizeContentView])
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        }
        WindowFrameAppearance.clip(window)
        configureDefaultButton(in: window)
        sheetShells.values.first { $0.panel === window }?.updateContentSize()
    }

    /// A default action is independent of the editor's first responder.
    static func configureDefaultButton(in window: NSWindow) {
        func buttons(in view: NSView) -> [NSButton] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            if let button = view as? NSButton { return button.isEnabled ? [button] : [] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        guard let content = window.contentView else { return }
        let candidates = buttons(in: content)
        // NSWindow can rewrite its default cell's live key equivalent to Return.
        // Use declared actions so an early Cancel cannot outrank a later primary.
        func declaredKey(_ button: NSButton) -> String {
            (button as? KeyViewProxy.Button)?.declaredKeyEquivalent ?? button.keyEquivalent
        }
        let preferred = candidates.first { declaredKey($0) == "\r" }
            ?? candidates.first { ($0 as? KeyViewProxy.Button)?.isPrimaryAction == true || $0.bezelColor == .controlAccentColor }
            ?? candidates.last { declaredKey($0) == "\u{1b}" }
        window.defaultButtonCell = preferred?.cell as? NSButtonCell
    }

    static func confirmClose(title: String, message: String, save: String, discard: String, cancel: String) -> NSApplication.ModalResponse {
        let window = DialogPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let buttons = [AuvGitAlertButton(save) { NSApp.stopModal(withCode: .alertFirstButtonReturn) },
                       AuvGitAlertButton(discard, role: .destructive) { NSApp.stopModal(withCode: .alertSecondButtonReturn) },
                       AuvGitAlertButton(cancel, role: .cancel) { NSApp.stopModal(withCode: .alertThirdButtonReturn) }]
        let host = NSHostingView(rootView: AuvGitAlertView(title: title, message: Text(message), buttons: buttons, close: {})
            .background(Color(nsColor: .windowBackgroundColor)).nativeFocusRoot(focusesOnPresentation: true))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        style(window)
        window.center()
        let response = NSApp.runModal(for: window)
        window.orderOut(nil); window.close()
        return response
    }
}

private final class DialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Keep SwiftUI's native sheet as the binding/dismiss anchor while presenting
/// its existing content in the same key-capable rounded frame as the app.
@MainActor
private final class DialogSheetShell {
    let panel: DialogPanel
    private weak var original: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private let closed: () -> Void

    init(original: NSWindow, closed: @escaping () -> Void) {
        self.original = original
        self.closed = closed
        let visibleFrame = original.sheetParent?.screen?.visibleFrame ?? original.screen?.visibleFrame ?? original.frame
        panel = DialogPanel(contentRect: DialogAppearance.boundedFrame(original.frame, visibleFrame: visibleFrame),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hasShadow = true
        let content = original.contentView
        let responder = original.firstResponder as? NSView
        let editor = responder as? NSTextView
        let editingControl = editor?.delegate as? NSView
        let selection = editor?.selectedRange()
        original.contentView = NSView(frame: content?.frame ?? .zero)
        panel.contentView = content
        WindowFrameAppearance.clip(panel)
        original.alphaValue = 0
        original.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        if let target = editingControl ?? responder, target.window === panel {
            panel.makeFirstResponder(target)
            if let selection, let editor = panel.firstResponder as? NSTextView { editor.setSelectedRange(selection) }
        }
        DialogAppearance.configureDefaultButton(in: panel)
        let center = NotificationCenter.default
        for source in [original, original.sheetParent].compactMap({ $0 }) {
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: source, queue: .main) { [weak self] _ in
                // Sheet presentation can restore either the hidden sheet or
                // its parent as key. Wait until AppKit finishes that transition.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.panel.isVisible, let original = self.original,
                          original.sheetParent?.attachedSheet === original,
                          NSApp.keyWindow === original || NSApp.keyWindow === original.sheetParent else { return }
                    self.panel.makeKey()
                }
            })
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: original, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFrame() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.didEndSheetNotification, object: original.sheetParent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: original, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        })
    }

    func updateContentSize() {
        guard let original, let content = panel.contentView else { return }
        let desired = content.fittingSize
        let screen = original.sheetParent?.screen?.visibleFrame ?? panel.screen?.visibleFrame ?? original.frame
        let size = DialogAppearance.boundedFrame(NSRect(origin: original.frame.origin, size: desired), visibleFrame: screen).size
        guard desired.width > 0, desired.height > 0,
              abs(size.width - panel.contentLayoutRect.width) > 0.5 || abs(size.height - panel.contentLayoutRect.height) > 0.5 else { return }
        original.setContentSize(size)
        syncFrame()
    }

    private func syncFrame() {
        guard let original else { return }
        let screen = original.sheetParent?.screen?.visibleFrame ?? panel.screen?.visibleFrame ?? original.frame
        panel.setFrame(DialogAppearance.boundedFrame(original.frame, visibleFrame: screen), display: true)
    }
    private func finish() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        original?.removeChildWindow(panel)
        if let original {
            let content = panel.contentView
            panel.contentView = NSView()
            original.contentView = content
            original.alphaValue = 1
        }
        panel.orderOut(nil)
        panel.close()
        closed()
    }
}

struct DialogFrameStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> FrameView { FrameView() }
    func updateNSView(_ view: FrameView, context: Context) { view.scheduleStyle() }
    final class FrameView: NSView {
        private var scheduled = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DialogAppearance.prepareSheet(window) }
            scheduleStyle()
        }
        func scheduleStyle() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                if let window = self.window { DialogAppearance.style(window) }
            }
        }
    }
}
