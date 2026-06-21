import SwiftUI

@main
struct GMVibesApp: App {
    @State private var gmccEnvironment = GMCCEnvironment()
    @State private var kbiteStore = KBiteStore()
    @State private var yeetViewerStore = YeetViewerStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(gmccEnvironment)
                .environment(kbiteStore)
                .environment(yeetViewerStore)
        }
        .commands {
            YeetFindCommands()
        }

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
