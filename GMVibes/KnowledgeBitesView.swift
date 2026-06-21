import SwiftUI

struct KnowledgeBitesView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(KBiteStore.self) private var store

    @State private var selectedTab: KBiteRoot = .digested

    var body: some View {
        TabView(selection: $selectedTab) {
            KBitesPaneView(root: .open)
                .tabItem { Label("Open", systemImage: "tray") }
                .tag(KBiteRoot.open)

            KBitesPaneView(root: .digested)
                .tabItem { Label("Digested", systemImage: "books.vertical") }
                .tag(KBiteRoot.digested)
        }
        .navigationTitle("Knowledge Bites")
        .toolbar {
            ToolbarItem {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}

private struct KBitesPaneView: View {
    let root: KBiteRoot

    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(KBiteStore.self) private var store

    @State private var selectedFile: URL?

    var body: some View {
        let kbites = store.kbites(in: root, gmcc: gmcc)

        if kbites.isEmpty {
            emptyState
        } else {
            HSplitView {
                KBiteAccordionSidebar(kbites: kbites, selection: $selectedFile)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)

                if let file = selectedFile, isPreviewableFile(file) {
                    KBiteMarkdownView(url: file)
                        .frame(minWidth: 360)
                } else {
                    Text("Select a kbite, then click a file to preview.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minWidth: 360)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        guard let path = gmcc[root.envKey] else {
            return "\(root.envKey.rawValue) is not set in ~/.zshrc."
        }
        return "No kbites at\n\(path)"
    }

    private func isPreviewableFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return !isDir.boolValue
    }
}

private struct KBiteAccordionSidebar: View {
    let kbites: [KBiteEntry]
    @Binding var selection: URL?

    @State private var expandedURL: URL?
    @State private var loadedNodes: [URL: KBiteFileNode] = [:]

    var body: some View {
        List(selection: $selection) {
            ForEach(kbites) { kbite in
                kbiteSection(kbite)
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            if expandedURL == nil, let first = kbites.first {
                expand(first.url)
            }
        }
    }

    @ViewBuilder
    private func kbiteSection(_ kbite: KBiteEntry) -> some View {
        DisclosureGroup(isExpanded: bindingFor(kbite.url)) {
            if let node = loadedNodes[kbite.url] {
                OutlineGroup(node.children ?? [], children: \.children) { child in
                    fileRow(child)
                        .tag(child.url as URL?)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label(kbite.name, systemImage: "shippingbox.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = kbite.url
                    if expandedURL == kbite.url {
                        expandedURL = nil
                    } else {
                        expand(kbite.url)
                    }
                }
        }
        .tag(kbite.url as URL?)
    }

    @ViewBuilder
    private func fileRow(_ node: KBiteFileNode) -> some View {
        if node.isDirectory {
            Label(node.name, systemImage: "folder.fill")
                .foregroundStyle(.secondary)
        } else {
            let isMarkdown = node.url.pathExtension.lowercased() == "md"
            Label {
                Text(node.name)
                    .fontWeight(isMarkdown ? .medium : .regular)
            } icon: {
                Image(systemName: isMarkdown ? "doc.text.fill" : "doc")
                    .foregroundStyle(isMarkdown ? Color.accentColor : .secondary)
            }
            .contextMenu {
                OpenInWindowButton(url: node.url)
            }
        }
    }

    private func bindingFor(_ url: URL) -> Binding<Bool> {
        Binding(
            get: { expandedURL == url },
            set: { isOpen in
                if isOpen {
                    expand(url)
                } else if expandedURL == url {
                    expandedURL = nil
                }
            }
        )
    }

    private func expand(_ url: URL) {
        expandedURL = url
        if loadedNodes[url] == nil {
            loadedNodes[url] = KBiteFileNode.load(from: url)
        }
    }
}

private struct OpenInWindowButton: View {
    let url: URL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "kbite-md", value: url)
        } label: {
            Label("Open in Window", systemImage: "macwindow.badge.plus")
        }
    }
}
