import SwiftUI

/// The drawings detail pane. Mirrors the prompt pane's anatomy — an editable
/// title in PromptLifecycleBar's slot and chrome, the tool strip in
/// KBitePillBox's slot and chrome — but the canvas is NOT inside a ScrollView
/// and carries NO 900pt readable-measure clamp: the surface wants every pixel.
///
/// Publishes NO find focused-scene-values, so ⌘F/⌘G stay disabled over the
/// canvas (the same collision discipline PromptEditorPane applies while the
/// memories inspector is open).
///
/// Instantiated with `.id(drawing.id)`: the pane's @State (active tool,
/// in-flight gesture drafts) resets per drawing selection, while elements,
/// viewport, selection and title all live on the `Drawing` in the store and
/// survive.
struct DrawingPane: View {
    @Bindable var drawing: Drawing
    @State private var tool: DrawingTool = .select
    @State private var strokeColor: RGBAColor = .brandOrange
    @State private var strokeWidth: CGFloat = 4
    @State private var canvasSize: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            // PromptLifecycleBar's chrome recipe, verbatim.
            HStack {
                TextField("Untitled", text: $drawing.title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(drawing.elements.count) elements")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))

            DrawingToolStrip(
                tool: $tool,
                strokeColor: $strokeColor,
                strokeWidth: $strokeWidth,
                drawing: drawing,
                canvasSize: canvasSize
            )

            DrawingCanvasView(drawing: drawing, tool: tool,
                              strokeColor: strokeColor, strokeWidth: strokeWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Titlebar rename from the same state; mapped through displayTitle so
        // an empty title doesn't blank the window title.
        .navigationTitle(Binding(
            get: { drawing.displayTitle },
            set: { drawing.title = ($0 == "Untitled" ? "" : $0) }
        ))
        .navigationSubtitle("Drawing")
    }
}
