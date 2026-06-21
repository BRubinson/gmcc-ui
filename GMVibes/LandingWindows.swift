import SwiftUI

// Thin scene-root wrappers so each feature window owns its own view-local store —
// avoids the App-level @State-shared-across-WindowGroup-instances trap. The shared
// singletons (GMCCEnvironment, GMCCFileSystemEmulation) are injected by the App via
// the .gmccEnv(_:_:) modifier.

/// Yeet Viewer window. YeetViewerView provides its own NavigationStack + toolbar.
struct YeetViewerScene: View {
    @State private var store = YeetViewerStore()

    var body: some View {
        YeetViewerView()
            .environment(store)
            .frame(minWidth: 720, minHeight: 480)
    }
}

/// KBites window. KnowledgeBitesView is a TabView with a toolbar but no navigation
/// container of its own, so wrap it in a NavigationStack so the title/toolbar host.
struct KBitesScene: View {
    @State private var store = KBiteStore()

    var body: some View {
        NavigationStack {
            KnowledgeBitesView()
                .environment(store)
        }
        .frame(minWidth: 760, minHeight: 480)
    }
}

/// Projects window. ProjectsView owns its own NavigationStack + search.
struct ProjectsScene: View {
    var body: some View {
        ProjectsView()
            .frame(minWidth: 720, minHeight: 480)
    }
}

/// Per-session window — hosts the prompt-authoring editor (one window per session UUID).
struct SessionTodoView: View {
    let windowID: SessionWindowID

    var body: some View {
        SessionPromptEditorView(windowID: windowID)
    }
}
