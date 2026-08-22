import SwiftUI

/// App-wide action popup (cmd+K). Floats centered over all content; Esc or a
/// click outside dismisses. TODO body for now — the palette itself is a later
/// prompt's overhaul.
struct CommandPalette: View {
    @Environment(WindowNav.self) private var nav

    var body: some View {
        ZStack {
            // Click-outside scrim.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { nav.paletteOpen = false }

            VStack(spacing: 12) {
                Text("TODO")
                    .font(.title2.weight(.semibold))
                Text("Command palette coming soon — Esc or click outside to close.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(width: 480)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))

            // Esc dismissal that needs no focus plumbing: .onExitCommand only
            // fires for a focused responder, which this overlay doesn't have.
            Button("") { nav.paletteOpen = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onExitCommand { nav.paletteOpen = false }
    }
}
