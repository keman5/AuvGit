import SwiftUI
import AuvGitLocalization

func designText(_ key: String) -> String { L10n.text(key, table: "DesignWorkflows") }

/// A row owns the control height; native button padding must not add another
/// bezel-sized region around a label that already has its toolbar dimensions.
struct ToolbarRowButtonStyle: ButtonStyle {
    var height: CGFloat = 24
    var minimumWidth: CGFloat = 24
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: minimumWidth).frame(height: height)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.secondary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Comparison icons own an exact hit region, including the button style.
/// A minimum width can still accept an expanded toolbar layout proposal.
struct ComparisonToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 22, height: 24).fixedSize()
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color.secondary.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct DesignPageHeading: View {
    let title: String
    let subtitle: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 13) {
            if let icon { Image(systemName: icon).font(.system(size: 25, weight: .medium)).foregroundStyle(Color.accentColor) }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 24, weight: .bold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
}

struct DesignCard<Content: View>: View {
    private let title: String?
    private let content: Content
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold)).padding(14)
                Divider()
            }
            content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1))
    }
}

struct DesignSettingRow<Control: View>: View {
    let title: String
    var detail: String = ""
    private let control: Control
    init(_ title: String, detail: String = "", @ViewBuilder control: () -> Control) { self.title = title; self.detail = detail; self.control = control() }
    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 14)
            control
        }.padding(.vertical, 7)
    }
}

struct DesignActionChip: View {
    let title: String
    var color: Color = .accentColor
    var body: some View {
        Text(title).font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(color).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
