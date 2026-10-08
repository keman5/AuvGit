import SwiftUI

/// One visual/hit region, with a primary action and a separate menu affordance.
/// Using a borderless Menu avoids AppKit's segmented primaryAction decoration.
struct UnifiedToolbarSplitButton<LabelContent: View, MenuContent: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let label: () -> LabelContent
    @ViewBuilder let menu: () -> MenuContent
    var menuWidth: CGFloat? = nil
    @State private var menuPresented = false
    func boundedMenu(width: CGFloat) -> Self {
        var copy = self; copy.menuWidth = width; return copy
    }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) { label().frame(minWidth: 32, minHeight: 28).contentShape(Rectangle()) }
                .buttonStyle(ToolbarRowButtonStyle(height: 28, minimumWidth: 32)).accessibilityLabel(title)
            if let menuWidth {
                Button { menuPresented.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .frame(width: 14, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title)
                    .rayGitPopover(isPresented: $menuPresented, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 4) { menu() }
                            .buttonStyle(.plain).lineLimit(1).truncationMode(.tail)
                            .frame(width: menuWidth - 20, alignment: .leading).padding(10)
                            .onTapGesture { menuPresented = false }
                    }
            } else {
            Menu(content: menu) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 28).contentShape(Rectangle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 28)
                .accessibilityLabel(title)
            }
        }.frame(height: 28).contentShape(Rectangle())
            .accessibilityElement(children: .contain)
    }
}
