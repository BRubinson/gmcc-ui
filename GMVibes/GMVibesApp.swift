import SwiftUI

@main
struct GMVibesApp: App {
    @State private var gmccEnvironment = GMCCEnvironment()
    @State private var fileSystem = GMCCFileSystemEmulation.shared

    var body: some Scene {
        // Primary launcher (singleton).
        Window("GM Vibes", id: "landing") {
            LandingView()
                .gmccEnv(gmccEnvironment, fileSystem)
        }
        .windowResizability(.contentMinSize)
        .commands {
            YeetFindCommands()
        }

        // Feature windows. Yeet Viewer + KBites are singletons (openWindow(id:)
        // focuses the existing one). Projects is a group so multiples can open.
        Window("Yeet Viewer", id: "yeet-viewer") {
            YeetViewerScene()
                .gmccEnv(gmccEnvironment, fileSystem)
        }

        Window("Knowledge Bites", id: "kbites") {
            KBitesScene()
                .gmccEnv(gmccEnvironment, fileSystem)
        }

        WindowGroup("Projects", id: "projects") {
            ProjectsScene()
                .gmccEnv(gmccEnvironment, fileSystem)
        }

        // One window per session (keyed on SessionWindowID.sessionUUID).
        WindowGroup(for: SessionWindowID.self) { $windowID in
            if let windowID {
                SessionTodoView(windowID: windowID)
                    .gmccEnv(gmccEnvironment, fileSystem)
            } else {
                Text("No session")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }

        // Per-file KBite markdown window (unchanged).
        WindowGroup("KBite File", id: "kbite-md", for: URL.self) { $url in
            KBiteMarkdownWindowView(url: url)
        }
    }
}

struct YeetFindCommands: Commands {
    @FocusedValue(\.yeetFind) private var find: (() -> Void)?
    @FocusedValue(\.yeetFindNext) private var findNext: (() -> Void)?
    @FocusedValue(\.yeetFindPrev) private var findPrev: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find\u{2026}") { find?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
            Button("Find Next") { findNext?() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(findNext == nil)
            Button("Find Previous") { findPrev?() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(findPrev == nil)
        }
    }
}

// Inject the shared GMCC singletons into a scene's root view in one call.
extension View {
    func gmccEnv(_ env: GMCCEnvironment, _ fs: GMCCFileSystemEmulation) -> some View {
        self
            .environment(env)
            .environment(fs)
    }
}
