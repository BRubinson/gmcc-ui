import SwiftUI

// The rich-text plumbing for in-editor markdown header highlighting.
//
// `markdownHeaderLevel` is a *semantic* attribute derived purely from the source text
// (set by MarkdownHeaderTagger). It is never persisted — the editor flattens the
// AttributedString back to a plain String on every edit. The formatting definition maps
// the semantic level to the visible color/font, so styling is re-derived live as the
// user types rather than stored.

/// Marks a run as belonging to a markdown heading of the given level (1...6).
enum MarkdownHeaderLevelAttribute: CodableAttributedStringKey {
    typealias Value = Int
    static let name = "GMVibes.markdownHeaderLevel"
    // Typing past a heading must not inherit its level, and a heading is a whole-line
    // concept, so its run shouldn't fragment as the caret moves through it.
    static let inheritedByAddedText = false
    static let runBoundaries: AttributedString.AttributeRunBoundaries? = .paragraph
}

extension AttributeScopes {
    /// Scope visible to the header formatting definition: the semantic level plus the
    /// two presentation attributes it derives.
    struct MarkdownEditorScope: AttributeScope {
        let markdownHeaderLevel: MarkdownHeaderLevelAttribute
        let foregroundColor: AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
        let font: AttributeScopes.SwiftUIAttributes.FontAttribute
    }

    var markdownEditor: MarkdownEditorScope.Type { MarkdownEditorScope.self }
}

/// Re-derives header color + size from `markdownHeaderLevel` on the runs the editor
/// renders, so no styling is ever stored. The tagging pass pre-applies the same values
/// across the whole document (covering off-screen runs the definition may skip).
struct MarkdownHeaderFormattingDefinition: AttributedTextFormattingDefinition {
    typealias Scope = AttributeScopes.MarkdownEditorScope

    var body: some AttributedTextFormattingDefinition<Scope> {
        HeaderColorConstraint()
        HeaderFontConstraint()
    }

    struct HeaderColorConstraint: AttributedTextValueConstraint {
        typealias Scope = AttributeScopes.MarkdownEditorScope
        typealias AttributeKey = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute

        func constrain(_ container: inout Attributes) {
            container.foregroundColor = container.markdownHeaderLevel != nil
                ? MarkdownHeaderStyle.color
                : MarkdownHeaderStyle.bodyColor   // explicit adaptive label color, not nil
        }
    }

    struct HeaderFontConstraint: AttributedTextValueConstraint {
        typealias Scope = AttributeScopes.MarkdownEditorScope
        typealias AttributeKey = AttributeScopes.SwiftUIAttributes.FontAttribute

        func constrain(_ container: inout Attributes) {
            if let level = container.markdownHeaderLevel {
                container.font = MarkdownHeaderStyle.font(level: level)
            } else {
                container.font = nil   // inherit the editor's body font
            }
        }
    }
}
