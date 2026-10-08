import AppKit
import SwiftUI

extension View {
    func rayGitSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().background(Color(nsColor: .windowBackgroundColor)).background(DialogFrameStyle())
                .presentationCornerRadius(RayGitStyle.windowCornerRadius)
        }
    }
    func rayGitSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                       @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).background(Color(nsColor: .windowBackgroundColor)).background(DialogFrameStyle())
                .presentationCornerRadius(RayGitStyle.windowCornerRadius)
        }
    }
    func rayGitAlert<Message: View>(_ title: String, isPresented: Binding<Bool>,
                                    @RayGitAlertActions actions: @escaping () -> [RayGitAlertButton],
                                    @ViewBuilder message: @escaping () -> Message) -> some View {
        rayGitSheet(isPresented: isPresented) {
            RayGitAlertView(title: title, message: message(), buttons: actions()) { isPresented.wrappedValue = false }
        }
    }
    func rayGitAlert(_ title: String, isPresented: Binding<Bool>,
                     @RayGitAlertActions actions: @escaping () -> [RayGitAlertButton]) -> some View {
        rayGitAlert(title, isPresented: isPresented, actions: actions) { EmptyView() }
    }
    func rayGitAlert<Item: Identifiable>(item: Binding<Item?>,
                                         content: @escaping (Item) -> RayGitAlert) -> some View {
        rayGitSheet(item: item) { value in
            let alert = content(value)
            RayGitAlertView(title: alert.title, message: Text(alert.message), buttons: alert.buttons) { item.wrappedValue = nil }
        }
    }
}

struct RayGitAlert {
    let title: String
    let message: String
    let buttons: [RayGitAlertButton]
}

struct RayGitAlertButton {
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
enum RayGitAlertActions {
    static func buildBlock(_ buttons: RayGitAlertButton...) -> [RayGitAlertButton] { buttons }
}

private struct RayGitAlertView<Message: View>: View {
    let title: String
    let message: Message
    let buttons: [RayGitAlertButton]
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline)
            message.textSelection(.enabled)
            HStack {
                ForEach(buttons.indices, id: \.self) { index in
                    let button = buttons[index]
                    Button(button.title, role: button.role) { button.action(); close() }
                        .disabled(button.isDisabled)
                        .keyboardShortcut(button.role == .cancel ? .cancelAction :
                            index == buttons.firstIndex(where: { $0.role == nil }) ? .defaultAction : nil)
                }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).padding(24).frame(width: 360).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
enum DialogAppearance {
    static func style(_ window: NSWindow) {
        // SwiftUI sheets accept a borderless frame; native NSAlert panels do not.
        // App confirmations use RayGitAlertView so modality stays with SwiftUI.
        window.styleMask = window.styleMask.intersection([.resizable])
        guard let frame = window.contentView?.superview else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        frame.wantsLayer = true
        frame.layer?.cornerRadius = RayGitStyle.windowCornerRadius
        frame.layer?.masksToBounds = true
    }

    static func confirmClose(title: String, message: String, save: String, discard: String, cancel: String) -> NSApplication.ModalResponse {
        let window = DialogPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let buttons = [RayGitAlertButton(save) { NSApp.stopModal(withCode: .alertFirstButtonReturn) },
                       RayGitAlertButton(discard, role: .destructive) { NSApp.stopModal(withCode: .alertSecondButtonReturn) },
                       RayGitAlertButton(cancel, role: .cancel) { NSApp.stopModal(withCode: .alertThirdButtonReturn) }]
        let host = NSHostingView(rootView: RayGitAlertView(title: title, message: Text(message), buttons: buttons, close: {})
            .background(Color(nsColor: .windowBackgroundColor)))
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

private struct DialogFrameStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> FrameView { FrameView() }
    func updateNSView(_ view: FrameView, context: Context) {}
    final class FrameView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                DialogAppearance.style(window)
            }
        }
    }
}
