import SwiftUI
import AppKit
import GitCore

/// A quiet file/repository outline with a small, colored action mark.
struct RepositoryOperationIcon: View {
    let symbol: String
    private var appearance: (String, String?, Color) {
        switch symbol {
        case "arrow.down.to.line": return ("shippingbox", "arrow.down", .blue)
        case "arrow.up.to.line": return ("shippingbox", "arrow.up", .orange)
        case "plus.circle": return ("doc", "checkmark", .green)
        case "minus.circle": return ("doc", "minus", .orange)
        case "arrow.uturn.backward": return ("doc", "arrow.uturn.backward", .red)
        case "archivebox": return ("tray", "arrow.turn.down.right", .blue)
        case "archivebox.fill": return ("tray", "arrow.turn.up.right", .orange)
        case "arrow.clockwise": return ("folder", "arrow.clockwise", .blue)
        case "folder.badge.plus": return ("folder", "plus", .green)
        default: return (symbol, nil, .secondary)
        }
    }
    @MainActor private static var renderedImages: [String: NSImage] = [:]
    /// AppKit's split Menu extracts a single image from its Label. Flatten the
    /// outline and badge first so its primary button cannot lose the action mark.
    @MainActor static func toolbarImage(symbol: String, colorScheme: ColorScheme) -> NSImage {
        let key = symbol + "|" + (colorScheme == .dark ? "dark" : "light") + "|" + NSApp.effectiveAppearance.name.rawValue
        if let image = renderedImages[key] { return image }
        let renderer = ImageRenderer(content: RepositoryOperationIcon(symbol: symbol).environment(\.colorScheme, colorScheme))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 24, height: 23))
        image.size = NSSize(width: 24, height: 23)
        image.isTemplate = false
        renderedImages[key] = image
        return image
    }
    var body: some View {
        let (base, mark, tint) = appearance
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: base).font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                .frame(width: 21, height: 21)
            if let mark {
                Image(systemName: mark).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 12, height: 12).background(RayGitStyle.chrome, in: Circle())
                    .offset(x: 2, y: 1)
            }
        }.frame(width: 24, height: 23).accessibilityHidden(true)
    }
}

struct WorkspaceStatusIcon: View {
    enum Kind { case all, modified, added, deleted, conflict, untracked, renamed, staged, ignored, ordinary }
    let kind: Kind
    init(kind: Kind) { self.kind = kind }
    init(file: GitFile?) {
        guard let file else { kind = .ignored; return }
        if file.isConflict { kind = .conflict }
        else if file.isUntracked { kind = .untracked }
        else if file.indexStatus == "D" || file.worktreeStatus == "D" { kind = .deleted }
        else if file.indexStatus == "R" || file.worktreeStatus == "R" { kind = .renamed }
        else if file.indexStatus == "A" || file.worktreeStatus == "A" { kind = .added }
        else if file.isStaged && !file.isUnstaged { kind = .staged }
        else if file.isUnstaged { kind = .modified }
        else { kind = .ordinary }
    }
    init(filter: WorkspaceStatusFilter) {
        switch filter {
        case .all: kind = .all
        case .modified: kind = .modified
        case .added: kind = .added
        case .deleted: kind = .deleted
        case .conflict: kind = .conflict
        case .untracked: kind = .untracked
        case .renamed: kind = .renamed
        case .staged: kind = .staged
        }
    }
    private var badge: (String, Color)? {
        switch kind {
        case .modified: return ("pencil", .orange)
        case .added: return ("plus", .green)
        case .deleted: return ("minus", .red)
        case .conflict: return ("exclamationmark", .red)
        case .untracked: return ("questionmark", .blue)
        case .renamed: return ("arrow.right", .blue)
        case .staged: return ("checkmark", .green)
        case .ignored: return ("nosign", .secondary)
        case .all, .ordinary: return nil
        }
    }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: kind == .all ? "doc.on.doc" : "doc").font(.system(size: 17)).foregroundStyle(.secondary)
                .frame(width: 21, height: 21)
            if let (mark, tint) = badge {
                Image(systemName: mark).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 11, height: 11).background(RayGitStyle.canvas, in: Circle())
                    .offset(x: 2, y: 1)
            }
        }.frame(width: 24, height: 23).accessibilityHidden(true)
    }
}
