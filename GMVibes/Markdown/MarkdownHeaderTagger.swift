import SwiftUI

// Whole-document header tagging pass. Walks each logical line of the plain source,
// classifies ATX headings via MarkdownDocument.headingLevel, and stamps each heading's
// character run with the semantic `markdownHeaderLevel` attribute plus the derived
// color/font. Pre-applying color/font across the whole document (not just visible runs)
// means off-screen headers stay styled even where the formatting definition's
// visible-range optimization would skip them.
//
// The pass is idempotent: tagging already-tagged text yields an equal AttributedString,
// so the editor's re-tag-on-change loop terminates after one stabilizing pass.
enum MarkdownHeaderTagger {
    /// Build a freshly-tagged AttributedString from plain source.
    static func tagged(_ source: String) -> AttributedString {
        var attr = AttributedString(source)
        tag(&attr)
        return attr
    }

    /// Re-tag in place: clear all header styling, then re-apply it to heading lines.
    static func tag(_ attr: inout AttributedString) {
        let source = String(attr.characters)

        // Explicit attribute-key subscripts (not dynamic-member access) — the custom
        // scope re-declares foregroundColor/font, which would make `attr[r].foregroundColor`
        // ambiguous against the built-in SwiftUI scope here in plain AttributedString land.
        typealias FG = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        typealias FT = AttributeScopes.SwiftUIAttributes.FontAttribute

        // Reset to the body baseline first so edits/deletions un-style correctly. Body
        // text gets an explicit adaptive color (not nil) — an absent foreground renders
        // black on the dark field background, making typed text invisible.
        let whole = attr.startIndex..<attr.endIndex
        attr[whole][MarkdownHeaderLevelAttribute.self] = nil
        attr[whole][FG.self] = MarkdownHeaderStyle.bodyColor
        attr[whole][FT.self] = nil

        // `omittingEmptySubsequences: false` keeps blank lines so character offsets
        // stay aligned with the source.
        var lineStartOffset = 0
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineLength = line.count
            if let level = MarkdownDocument.headingLevel(of: String(line)) {
                let start = attr.index(attr.startIndex, offsetByCharacters: lineStartOffset)
                let end = attr.index(start, offsetByCharacters: lineLength)
                attr[start..<end][MarkdownHeaderLevelAttribute.self] = level
                attr[start..<end][FG.self] = MarkdownHeaderStyle.color
                attr[start..<end][FT.self] = MarkdownHeaderStyle.font(level: level)
            }
            lineStartOffset += lineLength + 1   // +1 for the consumed "\n"
        }
    }
}
