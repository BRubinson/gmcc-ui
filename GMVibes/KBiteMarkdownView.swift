import SwiftUI

struct KBiteMarkdownView: View {
    let url: URL
    var showOpenInWindow: Bool = true

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.headline)
                    Text(url.path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                if showOpenInWindow {
                    Button {
                        openWindow(id: "kbite-md", value: url)
                    } label: {
                        Label("Open in Window", systemImage: "macwindow.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch KBiteMarkdown.preview(for: url) {
        case .markdown(let attributed):
            Text(attributed)
                .textSelection(.enabled)
        case .text(let raw):
            Text(raw)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "doc.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
