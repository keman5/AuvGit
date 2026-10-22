import AppKit
import SwiftUI
import XCTest
@testable import AuvGit

@MainActor
final class ControlTypographyTests: XCTestCase {
    private final class Model: ObservableObject {
        @Published var checked = false
        @Published var selection = 0
        @Published var enabled = true
        @Published var method = RemoteAuthenticationMethod.accessToken
    }

    private struct Fixture: View {
        @ObservedObject var model: Model
        var body: some View {
            VStack {
                KeyViewProxy(label: "Include untracked files", checked: model.checked) { model.checked.toggle() }
                Toggle("Native checkbox", isOn: $model.checked).toggleStyle(.checkbox)
                Picker("Select", selection: $model.selection) {
                    Text("Alpha").tag(0)
                    Text("Bravo").tag(1)
                }.pickerStyle(.menu).frame(width: 240)
                Picker("Segment", selection: $model.selection) {
                    Text("Alpha").tag(0)
                    Text("Bravo").tag(1)
                }.pickerStyle(.segmented)
                ShortcutModifiers(modifiers: $model.selection)
                RemoteAuthenticationMethodPicker(selection: $model.method, isEnabled: model.enabled)
            }.disabled(!model.enabled).padding()
        }
    }

    func testControlTypographyAndHeightStayStableAcrossSelectionAndEnabledUpdates() async throws {
        _ = NSApplication.shared
        for size in [ControlSize.mini, .small, .regular, .large] {
            let model = Model()
            let host = NSHostingView(rootView: Fixture(model: model).controlSize(size).nativeFocusRoot())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            func settle() async throws {
                for _ in 0..<5 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            func controls(_ view: NSView) -> [NSControl] {
                if let control = view as? NSControl,
                   control is NSButton || control is NSSegmentedControl { return [control] }
                return view.subviews.flatMap(controls)
            }
            try await settle()
            let initial = controls(host)
            XCTAssertTrue(initial.contains { $0 is KeyViewProxy.Button })
            XCTAssertTrue(initial.contains { $0 is NSSegmentedControl })
            // SwiftUI draws its checkbox and menu picker without NSButton /
            // NSPopUpButton. Cover their layout alongside native cell metrics.
            let layoutSize = host.fittingSize
            let fonts = initial.map(\.font)
            let heights = initial.map { $0.intrinsicContentSize.height }
            let sizes = initial.map(\.controlSize)
            for index in 0..<6 {
                model.checked.toggle()
                model.selection = 1 - model.selection
                model.method = model.method == .accessToken ? .sshPrivateKey : .accessToken
                model.enabled = index % 3 != 0
                try await settle()
                XCTAssertEqual(host.fittingSize, layoutSize, "Selection must not resize checkbox/select layouts at \(size)")
                let updated = controls(host)
                XCTAssertEqual(updated.count, initial.count)
                for (offset, control) in updated.enumerated() where offset < initial.count {
                    XCTAssertEqual(control.font, fonts[offset], "State must not change font at \(size)")
                    XCTAssertEqual(control.controlSize, sizes[offset], "State must not change control size at \(size)")
                    XCTAssertEqual(control.intrinsicContentSize.height, heights[offset], "State must not change height at \(size)")
                }
            }
        }
    }
}
