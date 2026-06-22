import SwiftUI

// Renders parsed MarkdownBlocks as real SwiftUI layout: sized headings, indented
// lists, fenced code in a monospaced filled block, bordered blockquotes, and pipe
// tables in a Grid. Inline emphasis / links / code-spans within a block are handled
// by AttributedString's inline markdown parsing.
struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    init(source: String) { self.blocks = MarkdownDocument.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                view(for: block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(headingFont(level))
                .fontWeight(.bold)
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            inline(text)
                .font(.body)
                .textSelection(.enabled)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(item).font(.body)
                    }
                }
            }
            .padding(.leading, 6)

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(start + idx).").foregroundStyle(.secondary).monospacedDigit()
                        inline(item).font(.body)
                    }
                }
            }
            .padding(.leading, 6)

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
            }

        case .blockquote(let lines):
            HStack(spacing: 8) {
                Rectangle().fill(.tertiary).frame(width: 3)
                inline(lines.joined(separator: "\n"))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)

        case .rule:
            Divider()
        }
    }

    @ViewBuilder
    private func tableView(headers: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    inline(h).font(.callout.weight(.semibold))
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        inline(cell).font(.callout)
                    }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
    }

    // Inline markdown (bold/italic/links/code-spans) for the text within a block.
    private func inline(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title
        case 2:  return .title2
        case 3:  return .title3
        case 4:  return .headline
        default: return .subheadline
        }
    }
}
