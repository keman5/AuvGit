import SwiftUI
import AppKit

/// Shared chrome for the native workspace. Content remains edge-to-edge and dense.
enum RayGitStyle {
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let sidebar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.19, alpha: 1) : NSColor(calibratedRed: 0.92, green: 0.935, blue: 0.955, alpha: 1)
    })
    static let chrome = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .controlBackgroundColor : NSColor(calibratedRed: 0.98, green: 0.985, blue: 0.995, alpha: 1)
    })
    static let border = Color(nsColor: .separatorColor).opacity(0.65)
    static let horizontalInset: CGFloat = 12
    static let rowHeight: CGFloat = 30
    static let blue = Color(red: 0.04, green: 0.46, blue: 1)
}

struct RayGitPaneHeader: View {
    let title: String
    let systemImage: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).foregroundStyle(.secondary).frame(width: 15)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let count { RayGitBadge(String(count), tint: .secondary).accessibilityHidden(true) }
        }
        .padding(.horizontal, RayGitStyle.horizontalInset).frame(height: 34)
        .rayGitChrome()
        .overlay(alignment: .bottom) { Rectangle().fill(RayGitStyle.border).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
    }
}

struct RayGitBadge: View {
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

struct RayGitEmptyState: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 27, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RayGitStyle.canvas).accessibilityElement(children: .combine)
    }
}

extension View {
    func rayGitChrome() -> some View { background(RayGitStyle.chrome) }
    func rayGitInputSurface() -> some View {
        background(RayGitStyle.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(RayGitStyle.border, lineWidth: 0.5))
    }
}
