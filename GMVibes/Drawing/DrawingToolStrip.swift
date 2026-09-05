import SwiftUI

/// Single-select tool radio strip plus the viewport controls, in KBitePillBox's
/// slot and card chrome. Explicitly NOT KBitePillBox's control model — that
/// binds `[String]` (multi-select); a tool palette is one enum value, and
/// "none selected" is not a legal state.
///
/// The active treatment is `Glass.stateBorder`, the purpose-built (and until
/// now unused) always-present border whose opacity animates so state changes
/// never shift layout.
///
/// Click-only in v0: no single-letter shortcuts — the title TextField above
/// would swallow them, and app-level Commands are the wrong scope for a canvas
/// tool. Shortcuts arrive with the diagrams prompt, canvas-focus-scoped.
struct DrawingToolStrip: View {
    @Binding var tool: DrawingTool
    @Binding var strokeColor: RGBAColor
    @Binding var strokeWidth: CGFloat
    let drawing: Drawing
    /// The canvas's current size, for Fit. Zero before first layout — Fit
    /// no-ops harmlessly then.
    let canvasSize: CGSize

    /// S / M / L stroke widths — enough control without a slider's fuss.
    private static let widths: [CGFloat] = [2, 4, 8]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DrawingTool.allCases) { candidate in
                Button {
                    tool = candidate
                } label: {
                    Label(candidate.title, systemImage: candidate.symbol)
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .frame(width: 36, height: 30)
                        .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(tool == candidate ? Color.accentColor : .secondary)
                .stateBorder(.accentColor, active: tool == candidate, cornerRadius: 8)
                .help(candidate.help)
                .accessibilityAddTraits(tool == candidate ? .isSelected : [])
            }

            Divider().frame(height: 20)

            // Stroke color swatches — single-select, brand orange first/default.
            ForEach(Array(RGBAColor.palette.enumerated()), id: \.offset) { _, swatch in
                Button {
                    strokeColor = swatch
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 16, height: 16)
                        .padding(4)
                        .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .stateBorder(.accentColor, active: strokeColor == swatch, cornerRadius: 8)
                .help("Stroke color")
                .accessibilityAddTraits(strokeColor == swatch ? .isSelected : [])
            }

            Divider().frame(height: 20)

            // Stroke width: S/M/L dots sized to match what they produce.
            ForEach(Self.widths, id: \.self) { width in
                Button {
                    strokeWidth = width
                } label: {
                    Circle()
                        .fill(.primary)
                        .frame(width: 4 + width, height: 4 + width)
                        .frame(width: 24, height: 24)
                        .contentShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .stateBorder(.accentColor, active: strokeWidth == width, cornerRadius: 8)
                .help("Stroke width \(Int(width))pt")
                .accessibilityAddTraits(strokeWidth == width ? .isSelected : [])
            }

            Spacer()

            // A zoomable canvas with no way home is a trap: pinch to 5% and the
            // drawing is a dot. Readout matches KBitePillBox's monospaced
            // counter idiom.
            Text("\(Int((drawing.viewport.zoom * 100).rounded()))%")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Button("Fit") { drawing.fit(in: canvasSize) }
                .disabled(drawing.elements.isEmpty)
                .help("Zoom to fit every element")
            Button("Reset") { drawing.resetViewport() }
                .help("Back to 100% at the origin")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
