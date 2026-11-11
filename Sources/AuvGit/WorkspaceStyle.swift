import SwiftUI
import AppKit

/// Neutral, adaptive surfaces keep navigation behind the work and code on a solid canvas.
enum AuvGitStyle {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebarColor = adaptive(light: 0.945, dark: 0.155)
    static let chromeColor = adaptive(light: 0.978, dark: 0.185)
    static let toolbarColor = adaptive(light: 0.958, dark: 0.165)
    static let sidebar = Color(nsColor: sidebarColor)
    static let chrome = Color(nsColor: chromeColor)
    static let toolbar = Color(nsColor: toolbarColor)
    static let windowCornerRadius: CGFloat = 8
    static let border = Color(nsColor: .separatorColor).opacity(0.45)
    static let horizontalInset: CGFloat = 12
    static let rowHeight: CGFloat = 30
    static let blue = Color.accentColor
    static let sectionHeight: CGFloat = 34

    private static func adaptive(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(calibratedWhite: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
}

/// Limit live material to navigation chrome; editors and tables retain solid, legible surfaces.
struct AuvGitNavigationSurface: View {
    var sidebar = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Group {
            if reduceTransparency || contrast == .increased {
                sidebar ? AuvGitStyle.sidebar : AuvGitStyle.toolbar
            } else {
                NavigationMaterial(sidebar: sidebar)
                    .overlay((sidebar ? AuvGitStyle.sidebar : AuvGitStyle.toolbar).opacity(0.55))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    private struct NavigationMaterial: NSViewRepresentable {
        let sidebar: Bool
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.blendingMode = .behindWindow
            view.state = .followsWindowActiveState
            return view
        }
        func updateNSView(_ view: NSVisualEffectView, context: Context) {
            view.material = sidebar ? .sidebar : .headerView
        }
    }
}

struct AuvGitSectionLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label {
            Text(title).font(.system(size: 12, weight: .semibold))
        } icon: {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 16)
        }.lineLimit(1)
    }
}

extension HistoryGraphColorToken {
    var color: Color {
        switch self {
        case .blue: Color(red: 55 / 255, green: 138 / 255, blue: 221 / 255)
        case .cyan: Color(red: 29 / 255, green: 158 / 255, blue: 117 / 255)
        case .coral: Color(red: 216 / 255, green: 90 / 255, blue: 48 / 255)
        case .orange: Color(red: 240 / 255, green: 140 / 255, blue: 46 / 255)
        case .purple: Color(red: 127 / 255, green: 119 / 255, blue: 221 / 255)
        case .amber: Color(red: 186 / 255, green: 117 / 255, blue: 23 / 255)
        case .pink: Color(red: 212 / 255, green: 83 / 255, blue: 126 / 255)
        case .green: Color(red: 99 / 255, green: 153 / 255, blue: 34 / 255)
        case .gray: Color(red: 136 / 255, green: 135 / 255, blue: 128 / 255)
        }
    }
}

struct AuvGitPaneHeader: View {
    let title: String
    let systemImage: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 7) {
            AuvGitSectionLabel(title: title, systemImage: systemImage)
            Spacer(minLength: 4)
            if let count { AuvGitBadge(String(count), tint: .secondary).accessibilityHidden(true) }
        }
        .padding(.horizontal, AuvGitStyle.horizontalInset).frame(height: AuvGitStyle.sectionHeight)
        .auvGitSectionChrome()
        .accessibilityElement(children: .combine)
    }
}

struct AuvGitBadge: View {
    let title: String
    var tint: Color
    init(_ title: String, tint: Color = .accentColor) { self.title = title; self.tint = tint }
    var body: some View {
        Text(title).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            .foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 6).frame(minHeight: 18)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct AuvGitEmptyState: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 23, weight: .regular))
                .foregroundStyle(systemImage == "checkmark.circle" ? Color.green : AuvGitStyle.blue)
                .frame(width: 44, height: 44)
                .background((systemImage == "checkmark.circle" ? Color.green : AuvGitStyle.blue).opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AuvGitStyle.canvas).accessibilityElement(children: .combine)
    }
}

extension View {
    func auvGitChrome() -> some View { background(AuvGitStyle.chrome) }
    func auvGitInputSurface() -> some View {
        background(AuvGitStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(AuvGitStyle.border, lineWidth: 0.5))
    }
    func auvGitSectionChrome() -> some View {
        auvGitChrome().overlay(alignment: .bottom) {
            Rectangle().fill(AuvGitStyle.border).frame(height: 0.5)
        }
    }
}
