import AppKit
import SwiftUI
import Combine

/// Keep the file scope when a toolbar button takes the mouse, but clear it when
/// another content pane is clicked or keyboard focus moves into that pane.
final class WorkspaceFileFocus: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var hasFileFocus = false
    private var regions: [ObjectIdentifier: WeakRegion] = [:]
    private var monitor: Any?
    private struct WeakRegion { weak var view: NSView?; let toolbar: Bool }
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            self?.handle(event); return event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    func register(_ view: NSView, toolbar: Bool) { regions[ObjectIdentifier(view)] = WeakRegion(view: view, toolbar: toolbar) }
    @discardableResult func focus(in window: NSWindow, text: Bool = false) -> Bool {
        let live = regions.values.compactMap { region -> NSView? in
            guard !region.toolbar, let view = region.view, view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return view
        }
        guard !live.isEmpty, let content = window.contentView else { return false }
        func candidates(_ view: NSView) -> [NSView] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            let visible = view.visibleRect.intersection(view.bounds)
            let center = NSPoint(x: visible.midX, y: visible.midY)
            let inside = !visible.isEmpty && live.contains { $0.bounds.contains($0.convert(center, from: view)) }
            let supported = text ? view is NSTextView : view is NSTableView
            let current: [NSView] = inside && view.acceptsFirstResponder && supported ? [view] : []
            return current + view.subviews.flatMap(candidates)
        }
        let targets = candidates(content)
        for target in targets where window.makeFirstResponder(target) { updateScope(true); return true }
        return false
    }
    func handle(_ event: NSEvent) {
        guard let window = event.window else { return }
        guard event.type != .leftMouseUp, event.type != .rightMouseUp else { return }
        let live = regions.values.filter { $0.view?.window === window }
        guard !live.isEmpty else { return }
        if event.type == .keyDown {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let responder = window?.firstResponder as? NSView else { return }
                let visible = responder.visibleRect
                let center = NSPoint(x: visible.midX, y: visible.midY)
                let windowCenter = responder.convert(center, to: nil)
                let toolbarFocus = windowCenter.y >= (window?.contentLayoutRect.maxY ?? .greatestFiniteMagnitude) || live.contains { region in
                    guard region.toolbar, let view = region.view else { return false }
                    return view.bounds.contains(view.convert(center, from: responder))
                }
                guard !toolbarFocus else { return }
                let scope = live.contains { region in
                    guard !region.toolbar, let view = region.view, view.window === responder.window else { return false }
                    return view.bounds.contains(view.convert(center, from: responder))
                }
                self.updateScope(scope)
            }
            return
        }
        func contains(_ region: WeakRegion) -> Bool {
            guard let view = region.view else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
        // The native toolbar lives outside the content layout rectangle.
        if event.locationInWindow.y >= window.contentLayoutRect.maxY || live.contains(where: { $0.toolbar && contains($0) }) { return }
        // The command scope is immediately accurate, but do not invalidate the
        // hosting tree while NSTableView is tracking this click. Its mouseUp can
        // be consumed inside tracking, bypassing the normal local event monitor.
        updateScope(live.contains { !$0.toolbar && contains($0) })
    }
    private func updateScope(_ scope: Bool) {
        guard hasFileFocus != scope else { return }
        hasFileFocus = scope
        RunLoop.main.perform(inModes: [.default]) { [weak self] in self?.objectWillChange.send() }
    }
}

struct WorkspaceFileFocusRegion: NSViewRepresentable {
    let focus: WorkspaceFileFocus
    var toolbar = false
    final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView { let view = RegionView(); focus.register(view, toolbar: toolbar); return view }
    func updateNSView(_ view: NSView, context: Context) { focus.register(view, toolbar: toolbar) }
}
