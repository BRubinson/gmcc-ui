import SwiftUI
import SwiftData

@main
struct GMVibesApp: App {
    // Bounded flush of dirty prompt edits on quit (replaces the old
    // synchronous main-thread write in onDisappear).
    @NSApplicationDelegateAdaptor(GMVibesAppDelegate.self) private var appDelegate
    @State private var services = GMVibesServices()

    var body: some Scene {
        // Primary launcher (singleton).
        Window("GM Vibes", id: "landing") {
            LandingView()
                .gmccEnv(services)
        }
        .windowResizability(.contentMinSize)
        .commands {
            YeetFindCommands()
        }

        // Feature windows. Yeet Viewer + KBites are singletons (openWindow(id:)
        // focuses the existing one). Projects is a group so multiples can open.
        Window("Yeet Viewer", id: "yeet-viewer") {
            YeetViewerScene()
                .gmccEnv(services)
        }

        Window("Knowledge Bites", id: "kbites") {
            KBitesScene()
                .gmccEnv(services)
        }

        WindowGroup("Projects", id: "projects") {
            ProjectsScene()
                .gmccEnv(services)
        }

        // One window per session (keyed on SessionWindowID.sessionUUID).
        WindowGroup(for: SessionWindowID.self) { $windowID in
            if let windowID {
                SessionTodoView(windowID: windowID)
                    .gmccEnv(services)
                    .modelContainer(PromptHistoryStore.container)
            } else {
                Text("No session")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 480, minHeight: 320)
            }
        }

        // Per-file KBite markdown window.
        WindowGroup("KBite File", id: "kbite-md", for: URL.self) { $url in
            KBiteMarkdownWindowView(url: url)
                .gmccEnv(services)
        }

        // Popped-out Memories explorer (one per prompt's memory folder). MUST inject
        // .gmccEnv — the explorer reads FileTreeStore for the polled file
        // tree, so without it the window would crash on a missing environment object.
        WindowGroup("Prompt Memories", id: "prompt-memories", for: PromptMemoriesWindowID.self) { $windowID in
            PromptMemoriesWindow(windowID: windowID)
                .gmccEnv(services)
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
