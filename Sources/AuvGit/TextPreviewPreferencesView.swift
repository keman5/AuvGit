import SwiftUI

struct TextPreviewPreferencesView: View {
    @AppStorage(TextPreviewPreferences.key) private var saved = TextPreviewPreferences.defaultFormats
    @State private var draft = TextPreviewPreferences.formats()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(previewText("Force text preview")).font(.system(size: 15, weight: .semibold))
            DesignCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(previewText("Text preview formats help")).font(.system(size: 11)).foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 170, idealHeight: 220)
                        .accessibilityLabel(previewText("Text preview formats"))
                    HStack {
                        Button(previewText("Restore default formats")) { draft = TextPreviewPreferences.defaultFormats }
                        Spacer()
                        Button(previewText("Save formats")) { saved = draft }
                            .disabled(draft == saved)
                    }
                    Text(previewText("Saved formats apply immediately to the next preview."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
