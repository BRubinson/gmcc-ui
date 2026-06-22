import SwiftUI

// A SwiftUI-native, code-editor-style editable text field with live markdown header
// highlighting (purplish + level-scaled larger font, `#` markers stay visible) and a
// line-number gutter. Replaces the AppKit FindableTextEditor for the prompt editor's
// Backstory/Goal/Detail fields.
//
// The public contract is a plain `Binding<String>`: the view owns the
// String⇄AttributedString conversion internally and flattens all styling away on every
// edit, so the host's persistence/undo/autosave (all keyed on the plain String) are
// untouched. Styling is re-derived from the text, never stored.
//
// Lines do not soft-wrap (one logical line == one visual row) so the gutter numbers
// stay aligned with the editor's per-line layout; long lines scroll horizontally. Row
// heights are estimated from MarkdownHeaderStyle metrics — alignment is close but not
// pixel-perfect (SwiftUI exposes no per-line geometry for TextEditor).
struct MarkdownSourceEditor: View {
    @Binding var text: String
    var minHeight: CGFloat
    // Find-in-page: when this field is the active find segment, select the active match
    // so it's visible inside the editor (native selection == the highlight).
    var query: SearchQuery = SearchQuery("")
    var activeOccurrence: Int? = nil

    @State private var attributed = AttributedString()
    @State private var selection = AttributedTextSelection()

    private var lines: [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }
    private var lineLevels: [Int?] {
        lines.map { MarkdownDocument.headingLevel(of: String($0)) }
    }
    private var contentHeight: CGFloat {
        let sum = lineLevels.reduce(CGFloat(0)) { $0 + MarkdownHeaderStyle.lineHeight(forLevel: $1) }
        // Pad top+bottom, plus one extra body line of slack so the non-scrolling editor
        // never clips its last line if the per-line estimate runs slightly short.
        let slack = MarkdownHeaderStyle.lineHeight(forLevel: nil)
        return max(minHeight, sum + MarkdownHeaderStyle.verticalPadding * 2 + slack)
    }
    private var contentWidth: CGFloat {
        let widest = zip(lines, lineLevels).reduce(CGFloat(0)) { acc, pair in
            max(acc, CGFloat(pair.0.count) * MarkdownHeaderStyle.charWidth(forLevel: pair.1))
        }
        return widest + 48   // generous trailing slack so the last glyph never clips
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumberGutter(levels: lineLevels, topInset: MarkdownHeaderStyle.verticalPadding)
            Divider()
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: true) {
                    TextEditor(text: $attributed, selection: $selection)
                        .attributedTextFormattingDefinition(MarkdownHeaderFormattingDefinition())
                        .font(MarkdownHeaderStyle.bodyFont)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        // Fill the available width when content is short (so the whole
                        // area is clickable/editable), scroll horizontally when it's long.
                        .frame(width: max(geo.size.width - MarkdownHeaderStyle.horizontalPadding * 2,
                                          contentWidth),
                               height: contentHeight,
                               alignment: .topLeading)
                        .padding(.vertical, MarkdownHeaderStyle.verticalPadding)
                        .padding(.horizontal, MarkdownHeaderStyle.horizontalPadding)
                }
            }
        }
        .frame(height: contentHeight)
        .onAppear { rebuildFromText() }
        .onChange(of: text) { _, newValue in
            // External change (load / undo / redo): rebuild without clobbering the caret
            // mid-edit — only when the model genuinely diverged from what we're showing.
            if String(attributed.characters) != newValue { rebuildFromText() }
        }
        .onChange(of: attributed) { _, newValue in
            // Local edit: push the flattened plain text up to the model...
            let plain = String(newValue.characters)
            if plain != text { text = plain }
            // ...then re-derive header tags. `tag` is idempotent, so reassigning only on
            // a real change terminates the loop after one stabilizing pass. Character
            // identity is preserved, so the separate `selection` indices stay valid.
            var retagged = newValue
            MarkdownHeaderTagger.tag(&retagged)
            if retagged != newValue { attributed = retagged }
        }
        .onChange(of: activeOccurrence) { _, _ in selectActiveMatch() }
        .onChange(of: query) { _, _ in selectActiveMatch() }
    }

    private func rebuildFromText() {
        attributed = MarkdownHeaderTagger.tagged(text)
    }

    // Move the editor's selection to the active find match in this field, so the match
    // is visible. No-op when this field isn't the active find segment.
    private func selectActiveMatch() {
        guard query.isActive, let occ = activeOccurrence else { return }
        let ranges = query.ranges(in: text)
        guard ranges.indices.contains(occ) else { return }
        let r = ranges[occ]
        // attributed.characters mirrors `text`, so character offsets map across. Clamp
        // defensively in case the two are momentarily out of sync.
        let count = attributed.characters.count
        let lowerOffset = min(text.distance(from: text.startIndex, to: r.lowerBound), count)
        let upperOffset = min(text.distance(from: text.startIndex, to: r.upperBound), count)
        let lo = attributed.index(attributed.startIndex, offsetByCharacters: lowerOffset)
        let hi = attributed.index(attributed.startIndex, offsetByCharacters: upperOffset)
        selection = AttributedTextSelection(range: lo..<hi)
    }
}
