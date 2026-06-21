import SwiftUI

enum SidebarItem: String, Identifiable, CaseIterable, Hashable {
    case home
    case kbites
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .kbites: "Knowledge Bites"
        case .projects: "Projects"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .kbites: "lightbulb"
        case .projects: "folder"
        }
    }
}

struct ContentView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @State private var selection: SidebarItem? = .home

    private func isLocked(_ item: SidebarItem) -> Bool {
        !gmcc.isLoaded && item != .home
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
                .disabled(isLocked(item))
                .selectionDisabled(isLocked(item))
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .navigationTitle("GMVibes")
        } detail: {
            switch selection {
            case .home: HomeView()
            case .kbites: KnowledgeBitesView()
            case .projects: ProjectsView()
            case .none:
                Text("Select a section")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: gmcc.isLoaded, initial: true) { _, _ in
            if let current = selection, isLocked(current) {
                selection = .home
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(GMCCEnvironment())
        .environment(KBiteStore())
}
