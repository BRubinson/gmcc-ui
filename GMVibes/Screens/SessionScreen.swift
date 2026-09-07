import SwiftUI
import GMCCDaemonKit

// The SESSION view (`Route.session`): the drill-down level between an
// instance and a single prompt. Sidebar: the tabbed navigator (prompts /
// drawings). Detail: per-tab — a status-rich prompt list that NAVIGATES into
// `Route.sessionPrompt`, or the drawing canvas. The editor itself lives one
// route deeper (SessionPromptScreen).

// TODO: Reality view (the 3D drawing gallery tab) was removed pending a
// future release. GMCC prompt 4 (`reality_view_capabilities`, session
// `ewwies`) documents what it was: a RealityKit gallery projecting each
// drawing onto a chamfered card swept along a parametric arc, with an
// observation-firewall card projection, keyed scene reconciliation, and
// tap-to-select wired back to the shared drawing sidebar selection.

/// Which sidebar list is showing. A switch, not a ternary, everywhere this is
/// consumed: adding a case is a build error instead of silently inheriting
/// another tab's behavior.
enum SessionTab: String, CaseIterable, Identifiable, Hashable {
    case prompts, drawings, dope
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The + button's label, or nil when the tab creates nothing (the button
    /// HIDES — a permanently-disabled button reads as a bug).
    var newItemLabel: String? {
        switch self {
        case .prompts: "New Prompt"
        case .drawings: "New Drawing"
        case .dope: nil      // Init is the pane's affordance, not a sidebar +
        }
    }
}

struct SessionScreen: View {
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    @Environment(WindowNav.self) private var nav
    @Environment(DrawingsStore.self) private var drawingsStore
    let windowID: SessionWindowID

    @State private var scope: SessionScope
    @State private var showCreatePrompt = false
    @State private var promptQuery = ""
    @State private var tab: SessionTab = .prompts
    @State private var selectedDrawingID: UUID?

    private var store: SessionStore { scope.store }

    init(windowID: SessionWindowID) {
        self.windowID = windowID
        // Create-or-get is side-effect-safe in init; the refcount lease is the
        // WINDOW's (GMVibesWindow, keyed on Route.sessionScopeUuid).
        _scope = State(initialValue: SessionScopeCache.shared.scope(for: windowID.sessionUUID.wireString))
    }

    private var instanceRow: InstanceRow? {
        catalog.instance(uuid: windowID.instanceUUID.wireString)
    }
    private var projectRow: ProjectRow? {
        guard let instance = instanceRow else { return nil }
        return catalog.projects.first { $0.uuid == instance.projectUuid }
    }
    /// Live session name: the route payload's copy is frozen at navigation
    /// time; a rename must reach the title and sidebar header.
    private var sessionDisplayName: String {
        catalog.session(uuid: windowID.sessionUUID.wireString)?.name ?? windowID.sessionName
    }

    // Window-lived, session-keyed drawing state (create-or-get is
    // side-effect-safe from body — the SessionScopeCache.scope contract).
    // Ownership stays on the WINDOW-root store: relocating it would lose
    // drawings on navigation (there is no daemon persistence behind them).
    private var book: DrawingBook { drawingsStore.book(for: windowID.sessionUUID.wireString) }
    private var selectedDrawing: Drawing? { book.drawing(id: selectedDrawingID) }
    private var filteredDrawings: [Drawing] {
        let q = SearchQuery(promptQuery)
        guard q.isActive else { return book.drawings }
        // displayTitle, not title — an untitled drawing must not vanish mid-search.
        return book.drawings.filter { q.matchesAny([$0.displayTitle]) }
    }

    private var prompts: [PromptStub] { store.prompts }
    private var filteredPrompts: [PromptStub] {
        let q = SearchQuery(promptQuery)
        guard q.isActive else { return prompts }
        return prompts.filter { stub in
            var fields = [stub.name, String(stub.seq)]
            if let detail = store.promptDetails[stub.uuid]?.prompt {
                fields.append(contentsOf: [detail.backstory, detail.goal, detail.detail])
            }
            return q.matchesAny(fields)
        }
    }

    var body: some View {
        ScreenScaffold(title: sessionDisplayName) {
            SessionNavigator(
                sessionName: sessionDisplayName,
                instanceName: instanceRow?.name ?? "—",
                repositoryName: projectRow?.gitRepoName,
                systemPath: instanceRow.map(\.absoluteFileSystemPath),
                changeSummary: store.changeSummary,
                prompts: filteredPrompts,
                query: $promptQuery,
                // Sidebar prompt rows NAVIGATE on activation (Button rows via
                // onOpenPrompt) — never a List selection binding: List drives
                // selection for arrow keys, type-select and VoiceOver focus,
                // and each of those writes must not swap the window route.
                onOpenPrompt: { openPrompt($0.uuid) },
                tab: $tab,
                drawings: filteredDrawings,
                selectedDrawingID: $selectedDrawingID,
                newLabel: tab.newItemLabel,
                // A switch, like newItemLabel: a future case is a build error
                // instead of silently inheriting `false`.
                newDisabled: {
                    switch tab {
                    case .prompts: store.session == nil
                    case .drawings, .dope: false
                    }
                }(),
                onNew: {
                    switch tab {
                    case .prompts:
                        showCreatePrompt = true
                    case .drawings:
                        // No sheet: CreatePromptView exists for the daemon
                        // round trip; a drawing has none — create and select.
                        selectedDrawingID = book.create().id
                    case .dope:
                        break   // unreachable: newItemLabel is nil, button hidden
                    }
                },
                onSearchSession: {
                    nav.go(.search(SearchSeed(sessionUuid: windowID.sessionUUID.wireString)))
                }
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            // The active tab's filter writer (prompts by name/content,
            // drawings by displayTitle).
            .searchable(text: $promptQuery, placement: .sidebar,
                        prompt: "Filter this session")
        } content: {
            detailContent
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: $showCreatePrompt) {
            CreatePromptView(
                store: store,
                sessionBackstory: store.session?.backstory ?? ""
            )
        }
        // Event-driven refresh: SESSION_GET on session invalidations. The
        // stream is hoisted BEFORE the first refresh so an invalidation that
        // fires during the initial (prefetch-heavy) load isn't lost.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .session(store.sessionUuid))
            if !catalog.hasLoaded { await catalog.refresh() }
            await store.refresh()
            scope.registerPrompts(Set(store.prompts.map(\.uuid)), daemon: daemon)
            for await _ in stream {
                await store.refresh()
                scope.registerPrompts(Set(store.prompts.map(\.uuid)), daemon: daemon)
            }
        }
        // Keep instance/project identity live on renames.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .topology)
            for await _ in stream {
                await catalog.refresh()
            }
        }
    }

    private func openPrompt(_ uuid: String) {
        guard let target = UUID(uuidString: uuid) else { return }
        var id = windowID
        id.targetPromptUUID = target
        nav.go(.sessionPrompt(id))
    }

    @ViewBuilder
    private var detailContent: some View {
        switch tab {
        case .prompts:
            PromptListPane(
                prompts: filteredPrompts,
                searching: !promptQuery.isEmpty,
                hasLoaded: store.hasLoaded,
                lastError: store.lastError,
                onOpen: { openPrompt($0.uuid) }
            )
        case .drawings:
            if let drawing = selectedDrawing {
                DrawingPane(drawing: drawing)
                    // Resets the pane's ephemeral state (tool, in-flight
                    // gesture) per selection; elements live on the Drawing
                    // in the window-root store and survive.
                    .id(drawing.id)
            } else {
                ContentUnavailableView(
                    "No Drawing Selected",
                    systemImage: "scribble.variable",
                    description: Text("Pick a drawing on the left, or create one with +.")
                )
            }
        case .dope:
            // Session-level read: SESSION_BASE scope (no promptUuid).
            DopePane(scope: scope, promptUuid: nil)
        }
    }
}

// MARK: - Prompt list detail (the "all prompts and their statuses" surface)

private struct PromptListPane: View {
    let prompts: [PromptStub]
    let searching: Bool
    let hasLoaded: Bool
    let lastError: String?
    let onOpen: (PromptStub) -> Void

    var body: some View {
        if prompts.isEmpty {
            if let lastError, hasLoaded {
                ContentUnavailableView(
                    "Session Unavailable",
                    systemImage: "bolt.slash",
                    description: Text(lastError)
                )
            } else {
                ContentUnavailableView(
                    searching ? "No Matching Prompts" : "No Prompts Yet",
                    systemImage: "doc.text",
                    description: Text(searching
                        ? "No prompt matches the sidebar filter."
                        : "Create a prompt with + in the sidebar.")
                )
            }
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(prompts, id: \.uuid) { stub in
                        Button {
                            onOpen(stub)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(stub.seq)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stub.name).font(.body).lineLimit(1)
                                    Text(stub.updatedAt)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                PromptStatusBadge(status: PromptStatus(rawValue: stub.status))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                    }
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Navigator (tabs + lists)

struct SessionNavigator: View {
    let sessionName: String
    let instanceName: String
    let repositoryName: String?
    let systemPath: String?
    let changeSummary: ChangeSummary?
    let prompts: [PromptStub]
    @Binding var query: String
    /// Activation (click/return), NOT selection: the editor is one route
    /// deeper, so keyboard traversal must not navigate.
    let onOpenPrompt: (PromptStub) -> Void
    @Binding var tab: SessionTab
    let drawings: [Drawing]
    @Binding var selectedDrawingID: UUID?
    let newLabel: String?
    let newDisabled: Bool
    let onNew: () -> Void
    let onSearchSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // One header row: the tab selector with its create/search actions
            // beside it. No in-sidebar search field — the list is short enough
            // to scan, and full-text search has its own screen.
            HStack(spacing: 8) {
                SegmentedPicker(
                    options: SessionTab.allCases,
                    label: { Text($0.title) },
                    selection: $tab,
                    accessibilityLabel: "Sidebar section"
                )
                Spacer(minLength: 4)
                // nil label = tab creates nothing; the button hides entirely.
                if let newLabel {
                    Button(action: onNew) {
                        Label(newLabel, systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(newDisabled)
                    .help(newLabel)
                }
                Button(action: onSearchSession) {
                    Label("Search Session", systemImage: "magnifyingglass")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Full-text search, scoped to this session")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            switch tab {
            // The dope tab REUSES the prompt list: it keeps the session's
            // working set in view, and clicking a prompt from there navigates
            // into its editor (where the prompt-level dope card lives).
            case .prompts, .dope:
                SessionPromptListSidebar(
                    sessionName: sessionName,
                    instanceName: instanceName,
                    repositoryName: repositoryName,
                    systemPath: systemPath,
                    changeSummary: changeSummary,
                    prompts: prompts,
                    searching: !query.isEmpty,
                    selectedUuid: .constant(nil),
                    onOpen: onOpenPrompt
                )
            case .drawings:
                drawingList
            }
        }
    }

    private var drawingList: some View {
        List(selection: $selectedDrawingID) {
            Section {
                if drawings.isEmpty {
                    Text(query.isEmpty ? "No drawings yet. Create one with +." : "No matching drawings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(drawings) { drawing in
                        // No element-count subtitle here: reading `elements`
                        // from the sidebar would subscribe the whole List to
                        // every element write, undoing the observation
                        // isolation the Drawing class was shaped for. The pane
                        // header carries the count, where it's free.
                        HStack(spacing: 8) {
                            Image(systemName: "scribble.variable").foregroundStyle(.secondary)
                            Text(drawing.displayTitle).font(.body).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(drawing.id)   // UUID tag == UUID? binding — types must match
                    }
                }
            } header: {
                Text("Drawings")
                    .textCase(nil)
                    .padding(.bottom, 4)
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Shared prompt-list sidebar (SessionScreen + SessionPromptScreen)

/// The prompt List with the session-identity header. Shared by the session
/// view's navigator and the prompt editor's (prompts-only) sidebar.
struct SessionPromptListSidebar: View {
    let sessionName: String
    let instanceName: String
    let repositoryName: String?
    let systemPath: String?
    let changeSummary: ChangeSummary?
    let prompts: [PromptStub]
    let searching: Bool
    /// In-screen selection mode (the editor screen): the List drives this.
    @Binding var selectedUuid: String?
    /// Activation mode (the session screen): rows are Buttons and clicking
    /// NAVIGATES — no selection binding, so arrow keys/type-select/VoiceOver
    /// focus can never swap the window route.
    var onOpen: ((PromptStub) -> Void)? = nil

    var body: some View {
        List(selection: onOpen == nil ? $selectedUuid : .constant(nil)) {
            Section {
                if prompts.isEmpty {
                    Text(searching ? "No matching prompts." : "No prompts yet. Create one with +.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let onOpen {
                    ForEach(prompts, id: \.uuid) { stub in
                        Button {
                            onOpen(stub)
                        } label: {
                            PromptNavRow(stub: stub)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(prompts, id: \.uuid) { stub in
                        PromptNavRow(stub: stub).tag(stub.uuid)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionName).font(.headline)
                    // RepName · instance · system path → session, with path actions.
                    // Path-open actions live in the toolbar's single "Open in…"
                    // menu — the header is identity only.
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive").font(.caption2)
                        identityText
                        Image(systemName: "arrow.right").font(.caption2)
                        Text(sessionName)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // Session-level change summary (FILE_CHANGE events land here).
                    if let summary = changeSummary, summary.changeCount > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "plusminus").font(.caption2)
                            Text("\(summary.changeCount) changes · \(summary.distinctFiles) files · \(summary.totalLineSpan) lines")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
                .textCase(nil)
                .padding(.bottom, 4)
            }
        }
        .listStyle(.sidebar)
    }

    // RepName · instance name · system path — only the fields that are present.
    @ViewBuilder
    private var identityText: some View {
        if let repo = repositoryName, !repo.isEmpty {
            Text(repo)
            Text("·").foregroundStyle(.tertiary)
        }
        Text(instanceName)
        if let path = systemPath, !path.isEmpty {
            Text("·").foregroundStyle(.tertiary)
            Text(path)
                .monospaced()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct PromptNavRow: View {
    let stub: PromptStub
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(stub.name).font(.body).lineLimit(1)
                Text("id \(stub.seq)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            PromptStatusBadge(status: PromptStatus(rawValue: stub.status))
        }
        .padding(.vertical, 2)
    }
}
