import SwiftUI

// CodeEdit-style file explorer over a prompt's memory/ folder: a recursive
// navigator on the left, a block-markdown / find-in-page reader on the right. Backed
// by FileTreeStore.fileTrees (polled), so files an architect agent writes
// mid-session appear live. The same view is hosted both inline (Memories tab) and in
// the CMD-click popout window — selection/expansion live in MemoriesExplorerModel.
struct MemoriesExplorer: View {
    let rootURL: URL
    @Bindable var model: MemoriesExplorerModel
    /// Set (with `isDaemonWatched`) to refresh on PROMPT_MEMORY_CHANGED
    /// instead of polling. nil/false ⇒ the permanent 1s poll — the 105
    /// pre-m0002 prompts have no storage path and never receive the event,
    /// and an artifact-common-ancestor root isn't the watched directory.
    var promptUuid: String? = nil
    var isDaemonWatched: Bool = false

    @Environment(FileTreeStore.self) private var fs
    @Environment(DaemonConnectionModel.self) private var daemon

    private var tree: FileTreeNode? { fs.fileTrees[rootURL] }

    private struct RefreshKey: Hashable {
        let root: URL
        let generation: Int
        /// In the key so a re-resolution that flips the strategy without
        /// changing the root still restarts the task.
        let daemonWatched: Bool
    }

    var body: some View {
        // Minimums must stay UNDER the narrowest host (the trailing inspector
        // column) — an unsatisfiable AppKit constraint set here thrashes
        // layout on every pass and reads as a crash when the view loads.
        HSplitView {
            sidebar
                .frame(minWidth: 160, idealWidth: 240, maxWidth: 420)

            if let file = model.selectedFile {
                MemoriesReader(url: file)
                    .frame(minWidth: 240)
                    .id(file)
            } else {
                ContentUnavailableView(
                    "No File Selected",
                    systemImage: "doc.text",
                    description: Text("Pick a file in the memory folder to preview it.")
                )
                .frame(minWidth: 240)
            }
        }
        // Keyed on the generation too: PROMPT_MEMORY_CHANGED is ephemeral
        // (id 0, no replay), so changes during a disconnect are lost — the
        // task restart's immediate refresh below is the resync.
        .task(id: RefreshKey(root: rootURL, generation: daemon.generation,
                             daemonWatched: isDaemonWatched)) {
            if isDaemonWatched, let promptUuid {
                // Stream hoisted before the first await (house idiom).
                let events = daemon.hub.stream(for: .memories(promptUuid.lowercased()))
                await fs.refreshFileTree(at: rootURL)
                seedExpansionIfNeeded()
                for await _ in events {
                    await fs.refreshFileTree(at: rootURL)
                    seedExpansionIfNeeded()
                }
            } else {
                while !Task.isCancelled {
                    await fs.refreshFileTree(at: rootURL)
                    seedExpansionIfNeeded()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        // Backstop for the event-driven branch: "the root equals the watched
        // directory" is NOT "the daemon is delivering" — its FSEventStream is
        // rooted once at boot (CONFIG_SET never re-roots it), stream-create
        // failures are stderr-only, and the popout window ID snapshots the
        // flag. A slow safety poll keeps ~97% of the 1s-poll saving while
        // removing the silent-freeze class entirely.
        .task(id: rootURL) {
            guard isDaemonWatched else { return }   // the 1s poll already runs
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await fs.refreshFileTree(at: rootURL)
                seedExpansionIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        if let tree, let children = tree.children, !children.isEmpty {
            List(selection: $model.selectedFile) {
                ForEach(children) { node in
                    FileTreeRow(node: node, selection: $model.selectedFile, expanded: $model.expanded)
                }
            }
            .listStyle(.sidebar)
        } else if tree != nil {
            ContentUnavailableView(
                "Empty",
                systemImage: "folder",
                description: Text("This prompt has no memory files yet.")
            )
        } else {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // Default-expand every directory in the (small) memory tree once, so the folder
    // opens already expanded as requested.
    private func seedExpansionIfNeeded() {
        guard !model.didSeedExpansion, let tree else { return }
        var dirs: Set<URL> = []
        func collect(_ node: FileTreeNode) {
            if node.isDirectory {
                dirs.insert(node.url)
                node.children?.forEach(collect)
            }
        }
        collect(tree)
        model.expanded.formUnion(dirs)
        model.didSeedExpansion = true
    }
}

// Host for the CMD-click popout window. Seeds a fresh model from the handed-off
// payload (selection + expansion) so the popout opens where the inline tab was.
struct PromptMemoriesWindow: View {
    let windowID: PromptMemoriesWindowID?

    @State private var model = MemoriesExplorerModel()
    @State private var seeded = false

    var body: some View {
        Group {
            if let windowID {
                MemoriesExplorer(
                    rootURL: windowID.memoryRootURL,
                    model: model,
                    promptUuid: windowID.promptUuid,
                    isDaemonWatched: windowID.isDaemonWatched ?? false
                )
                    .navigationTitle("Memories — \(windowID.promptName)")
                    .onAppear {
                        guard !seeded else { return }
                        model.selectedFile = windowID.selectedFile
                        model.expanded = Set(windowID.expanded)
                        // Respect handed-off expansion; only auto-expand if none came over.
                        model.didSeedExpansion = !windowID.expanded.isEmpty
                        seeded = true
                    }
            } else {
                ContentUnavailableView("No Memory Folder", systemImage: "folder")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

// One row in the recursive tree. Directories are DisclosureGroups whose open/closed
// state is bound into the shared `expanded` set (so it survives polling and hands off
// to the popout). Files are selectable rows tagged by URL.
private struct FileTreeRow: View {
    let node: FileTreeNode
    @Binding var selection: URL?
    @Binding var expanded: Set<URL>

    var body: some View {
        if node.isDirectory {
            DisclosureGroup(isExpanded: expansionBinding) {
                ForEach(node.children ?? []) { child in
                    FileTreeRow(node: child, selection: $selection, expanded: $expanded)
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .foregroundStyle(.secondary)
            }
        } else {
            let isMarkdown = node.url.pathExtension.lowercased() == "md"
            Label {
                Text(node.name).fontWeight(isMarkdown ? .medium : .regular)
            } icon: {
                Image(systemName: isMarkdown ? "doc.text.fill" : "doc")
                    .foregroundStyle(isMarkdown ? Color.accentColor : .secondary)
            }
            .tag(node.url)
            .contextMenu {
                OpenMemoryFileButton(url: node.url)
            }
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.url) },
            set: { open in
                if open { expanded.insert(node.url) } else { expanded.remove(node.url) }
            }
        )
    }
}

private struct OpenMemoryFileButton: View {
    let url: URL
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button {
            openWindow(value: WindowSeed(.kbiteFile(url)))
        } label: {
            Label("Open in Window", systemImage: "macwindow.badge.plus")
        }
    }
}

// MARK: - Reader (block markdown when idle, highlighted plain text while searching)

private struct MemoriesReader: View {
    let url: URL
    @Environment(\.openWindow) private var openWindow

    @State private var find = FindController()
    @State private var source: String = ""
    @State private var blocks: [MarkdownBlock] = []
    @State private var isMarkdown = false
    @State private var loaded = false

    // The file is a single find segment; active-green steps through its occurrences.
    private var matches: FindMatches {
        FindMatches(segments: [(id: url.path, text: source)], query: find.searchQuery)
    }
    private var activeLocal: Int? {
        matches.activeLocalOccurrence(in: url.path, active: find.activeIndex)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if find.isPresented {
                FindBar(find: find, total: matches.total, onStep: step)
            }
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .task(id: url) {
            // Read once per file off-main, then parse once — never per render.
            find.reset()
            loaded = false
            let raw = await Task.detached(priority: .userInitiated) {
                FileTreeStore.readRawFile(at: url)
            }.value
            source = raw
            isMarkdown = url.pathExtension.lowercased() == "md"
            blocks = isMarkdown ? MarkdownDocument.parse(raw) : []
            loaded = true
        }
        // cmd+F toggles the find bar; reuses the shared Find menu command.
        .focusedSceneValue(\.findInPage) { find.isPresented = true }
        .focusedSceneValue(\.findNext, matches.total == 0 ? nil : { step(+1) })
        .focusedSceneValue(\.findPrevious, matches.total == 0 ? nil : { step(-1) })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.headline)
                Text(url.path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            Button { openWindow(value: WindowSeed(.kbiteFile(url))) } label: {
                Label("Open in Window", systemImage: "macwindow.badge.plus")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView().controlSize(.small)
        } else if find.searchQuery.isActive {
            // While searching, show highlighted plain text.
            HighlightedText(source: source, query: find.searchQuery, activeLocalOccurrence: activeLocal)
        } else if isMarkdown {
            MarkdownBlocksView(blocks)
        } else {
            Text(source)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func step(_ delta: Int) {
        guard matches.total > 0 else { return }
        find.activeIndex = matches.clampedActive(find.activeIndex + delta)
    }
}
