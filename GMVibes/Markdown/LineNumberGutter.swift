import SwiftUI

// A CodeEdit-inspired line-number column. Renders one right-aligned number per logical
// source line, each in a row sized to that line's height (headings are taller), so the
// numbers track the editor's per-line layout. Relies on the editor running no-wrap
// (one logical line == one visual row) for alignment to hold.
struct LineNumberGutter: View {
    /// One entry per source line; the heading level (1...6) or nil for body lines.
    let levels: [Int?]
    var topInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Text("\(index + 1)")
                    .font(MarkdownHeaderStyle.bodyFont)
                    .foregroundStyle(.tertiary)
                    .frame(height: MarkdownHeaderStyle.lineHeight(forLevel: level))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topInset)
        .padding(.horizontal, 6)
        .frame(width: width, alignment: .trailing)
    }

    private var width: CGFloat {
        let digits = max(2, String(max(1, levels.count)).count)
        return CGFloat(digits) * 8 + 16
    }
}
