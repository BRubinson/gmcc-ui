import SwiftUI

/// The single window root. Every window can reach the whole app: a sliding
/// global rail on the left (collapsed by default) and a route-switched content
/// area. The session screen is a `NavigationSplitView`, so routes swap at the
/// root instead of pushing onto a `NavigationStack`.
struct GMVibesWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(GMCCEnvironment.self) private var gmcc
    @State private var nav: WindowNav

    init(seed: WindowSeed) {
        _nav = State(initialValue: WindowNav(initial: seed.route))
    }

    var body: some View {
        // The rail SLIDES OVER content (ZStack) rather than pushing it aside:
        // an HStack would add its 200pt to the content's own minWidth and
        // over-constrain a minimum-size window.
        ZStack(alignment: .leading) {
            content
                // Recreate per route so each screen's toolbar/title declarations
                // tear down cleanly on navigation.
                .id(nav.route)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if nav.railOpen {
                GlobalNavRail()
                    .shadow(radius: 8, x: 2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: nav.railOpen)
        .frame(minWidth: 760, minHeight: 480)
        // The shared app top bar, leading group — identical on every window.
        // Middle (title/subtitle) and trailing slot are declared per screen via
        // .navigationTitle/.navigationSubtitle and .toolbar(.primaryAction).
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if nav.canGoBack {
                    Button {
                        nav.goBack()
                    } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .help("Go back")
                }
                GmccDaemonStatus()
                Button {
                    nav.railOpen.toggle()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.leading")
                }
                .help("Toggle the global navigation sidebar")
                Button {
                    openWindow(value: WindowSeed())
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                }
                .help("Open a new GM Vibes window on the landing page")
                Button {
                    nav.paletteOpen = true
                } label: {
                    Label("Actions", systemImage: "command")
                }
                .help("App-wide actions (⌘K)")
            }
        }
        .overlay {
            if nav.paletteOpen { CommandPalette() }
        }
        .focusedSceneValue(\.commandPalette) { nav.paletteOpen = true }
        // PATHS_GET loader at the window root (not Landing — instance-only
        // windows need it too). GMCCEnvironment's env fetch can't live in its
        // synchronous init; the probe seeds values there and the daemon's
        // typed roots overlay them here on every generation bump and on
        // CONFIG_SET (.paths). Coalescing is the env's own change-gate.
        .task(id: daemon.generation) {
            let paths = daemon.hub.stream(for: .paths)
            await gmcc.loadFromDaemon()   // single-flight — N windows, 1 RPC
            for await _ in paths {
                await gmcc.loadFromDaemon()
            }
        }
        .environment(nav)
    }

    @ViewBuilder
    private var content: some View {
        switch nav.route {
        case nil:
            LandingView()
                .todoTrailingSlot()
        case .session(let windowID):
            SessionPromptEditorView(windowID: windowID)
        case .instance(let instanceUuid):
            InstanceScreen(instanceUuid: instanceUuid)
        case .projects:
            ProjectsView()
                .todoTrailingSlot()
        case .kbites:
            KBitesScene()
                .todoTrailingSlot()
        case .kbiteFile(let url):
            KBiteMarkdownWindowView(url: url)
                .todoTrailingSlot()
        case .promptMemories(let windowID):
            PromptMemoriesWindow(windowID: windowID)
                .todoTrailingSlot()
        }
    }
}

extension View {
    /// The top bar's trailing slot when the active screen sets nothing.
    func todoTrailingSlot() -> some View {
        toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("TODO: Use later")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

