import SwiftUI
import AppKit

/// Shared chrome for the native workspace. Content remains edge-to-edge and dense.
enum AuvGitStyle {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.19, alpha: 1) : NSColor(calibratedRed: 0.92, green: 0.935, blue: 0.955, alpha: 1)
    })
    static let chrome = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .controlBackgroundColor : NSColor(calibratedRed: 0.98, green: 0.985, blue: 0.995, alpha: 1)
    })
    static let windowCornerRadius: CGFloat = 12
    static let toolbar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.16, alpha: 1)
            : NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.965, alpha: 1)
    })
    static let border = Color(nsColor: .separatorColor).opacity(0.65)
    static let horizontalInset: CGFloat = 12
    static let rowHeight: CGFloat = 30
    static let blue = Color(red: 0.04, green: 0.46, blue: 1)
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
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 15)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let count { AuvGitBadge(String(count), tint: .secondary).accessibilityHidden(true) }
        }
        .padding(.horizontal, AuvGitStyle.horizontalInset).frame(height: 34)
        .auvGitChrome()
        .overlay(alignment: .bottom) { Rectangle().fill(AuvGitStyle.border).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

struct AuvGitBadge: View {
    let title: String
    var tint: Color
    init(_ title: String, tint: Color = .accentColor) { self.title = title; self.tint = tint }
    var body: some View {
        Text(title).font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct AuvGitEmptyState: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
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
}
