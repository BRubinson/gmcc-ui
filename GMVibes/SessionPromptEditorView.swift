import SwiftUI
import AppKit
import GMCCDaemonKit

// Per-session prompt-authoring screen. Left: a flat navigator of the session's
// prompts (SESSION_GET / PROMPT_LIST stubs). Right: a three-section code-style
// editor (backstory / goal / detail) over the selected prompt's daemon row, with
// version-threaded autosave, SwiftData-backed undo/redo, per-section copy, and a
// toolbar "Run" button that exports the `/gm_bot {seq}` resume command.

struct SessionPromptEditorView: View {
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    let windowID: SessionWindowID

    @State private var store: SessionStore
    @State private var selectedUuid: String?
    @State private var didDefaultSelect = false
    @State private var showCreatePrompt = false
    // One list filter over both fields: name + content (all sections).
    @State private var promptQuery = ""

    init(windowID: SessionWindowID) {
        self.windowID = windowID
        _store = State(initialValue: SessionStore(sessionUuid: windowID.sessionUUID.wireString))
    }

    // Instance/project identity resolved from the catalog snapshot.
    private var instanceRow: InstanceRow? {
        catalog.instance(uuid: windowID.instanceUUID.wireString)
    }
    private var projectRow: ProjectRow? {
        guard let instance = instanceRow else { return nil }
        return catalog.projects.first { $0.uuid == instance.projectUuid }
    }

    // Newest first — "default newest" selection + natural authoring order.
    private var prompts: [PromptStub] { store.prompts }
    private var selectedStub: PromptStub? { prompts.first { $0.uuid == selectedUuid } }
    // Tokenized list filter: a prompt matches if its name OR prefetched
    // backstory/goal/detail contains ANY space-separated term in the query.
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
        NavigationSplitView {
            PromptNavigator(
                sessionName: windowID.sessionName,
                instanceName: instanceRow?.name ?? "—",
                instanceUUID: windowID.instanceUUID,
                repositoryName: projectRow?.gitRepoName,
                systemPath: instanceRow.map(\.absoluteFileSystemPath),
                changeSummary: store.changeSummary,
                prompts: filteredPrompts,
                query: $promptQuery,
                selectedUuid: $selectedUuid
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .toolbar {
                ToolbarItem {
                    Button { showCreatePrompt = true } label: {
                        Label("New Prompt", systemImage: "plus")
                    }
                    .disabled(store.session == nil)
                    .help("Create a new prompt in this session")
                }
            }
        } detail: {
            if let stub = selectedStub {
                PromptEditorPane(
                    stub: stub,
                    store: store,
                    windowID: windowID
                )
                // Recreate the pane (fresh editor + history controller) per prompt.
                .id(stub.uuid)
            } else if let error = store.lastError, store.hasLoaded {
                ContentUnavailableView(
                    "Session Unavailable",
                    systemImage: "bolt.slash",
                    description: Text(error)
                )
            } else {
                ContentUnavailableView(
                    "No Prompt Selected",
                    systemImage: "doc.text",
                    description: Text("Pick a prompt on the left, or create one with +.")
                )
            }
        }
        .navigationTitle(windowID.sessionName)
        .frame(minWidth: 760, minHeight: 480)
        .sheet(isPresented: $showCreatePrompt) {
            CreatePromptView(
                store: store,
                sessionStub: catalog.sessionsByUuid[store.sessionUuid],
                sessionBackstory: store.session?.backstory ?? ""
            )
        }
        .onChange(of: prompts) { _, new in
            // Default to newest once data arrives; recover if the selection vanishes.
            if let uuid = selectedUuid, !new.contains(where: { $0.uuid == uuid }) {
                selectedUuid = new.first?.uuid
            } else if !didDefaultSelect, selectedUuid == nil, let first = new.first {
                selectedUuid = first.uuid
                didDefaultSelect = true
            }
        }
        // Event-driven refresh: SESSION_GET on session invalidations. The
        // stream is hoisted BEFORE the first refresh so an invalidation that
        // fires during the initial (prefetch-heavy) load isn't lost.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .session(store.sessionUuid))
            if !catalog.hasLoaded { await catalog.refresh() }
            await store.refresh()
            daemon.registerSession(store.sessionUuid, promptUuids: Set(store.prompts.map(\.uuid)))
            for await _ in stream {
                await store.refresh()
                daemon.registerSession(store.sessionUuid, promptUuids: Set(store.prompts.map(\.uuid)))
            }
        }
        // Keep instance/project identity + path derivations live on renames.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .topology)
            for await _ in stream {
                await catalog.refresh()
            }
        }
        .onDisappear {
            daemon.unregisterSession(store.sessionUuid)
        }
    }
}

// MARK: - Navigator

private struct PromptNavigator: View {
    let sessionName: String
    let instanceName: String
    let instanceUUID: UUID
    let repositoryName: String?
    let systemPath: String?
    let changeSummary: ChangeSummary?
    let prompts: [PromptStub]
    @Binding var query: String
    @Binding var selectedUuid: String?

    var body: some View {
        List(selection: $selectedUuid) {
            Section {
                if prompts.isEmpty {
                    Text(query.isEmpty ? "No prompts yet. Create one with +." : "No matching prompts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prompts, id: \.uuid) { stub in
                        PromptNavRow(stub: stub).tag(stub.uuid)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(sessionName).font(.headline)
                    // RepName · instance · system path → session, with path actions.
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive").font(.caption2)
                        identityText
                        Image(systemName: "arrow.right").font(.caption2)
                        Text(sessionName)
                        Spacer(minLength: 6)
                        InstancePathActions(systemPath: systemPath,
                                            instanceUUID: instanceUUID,
                                            instanceName: instanceName)
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
        .searchable(text: $query, placement: .sidebar, prompt: "Search name & content")
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

private struct PromptNavRow: View {
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

private struct PromptStatusBadge: View {
    let status: PromptStatus?
    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
    private var label: String { status?.rawValue.capitalized ?? "—" }
    private var color: Color {
        switch status {
        case .draft:      return .orange
        case .clarifying: return .blue
        case .clarified:  return .green
        case .none:       return .gray
        }
    }
}

// MARK: - Editor pane

private struct PromptEditorPane: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    let stub: PromptStub
    let store: SessionStore
    let windowID: SessionWindowID

    enum Field: Hashable { case backstory, goal, detail }
    enum Tab: Hashable { case initial, memories }

    enum SaveIssue: Equatable {
        case conflict
        case locked
        case failed(String)
    }

    /// Filesystem locations resolved OFF the main actor once per prompt/event
    /// (never during body — the resolver does FileManager probes).
    struct ResolvedPaths: Equatable, Sendable {
        var sessionFolder: URL?
        var instanceFolder: URL?
        var projectFolder: URL?
        var repoFolder: URL?
        var promptFolder: URL?
        var memoryRoot: URL?
    }

    @State private var backstory = ""
    @State private var goal = ""
    @State private var detail = ""
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var saver: PromptSaveActor?
    @State private var draftBox: PromptDraftBox
    @State private var saveIssue: SaveIssue?
    @State private var externalChange: PromptRow?
    @State private var paths = ResolvedPaths()
    // KBite registry pill box: the prompt's daemon-registered kbite codes plus
    // installed-kbite options; toggles issue KBITE_ADD/REMOVE at prompt scope.
    @State private var selectedKbites: [String] = []
    @State private var availableKbites: [String] = []
    @State private var kbiteSuppress = false
    @State private var tab: Tab = .initial
    @State private var lastSaved = PromptEditHistory.EditState(backstory: "", goal: "", detail: "")
    @State private var history = PromptEditHistory()
    @State private var saveTask: Task<Void, Never>?
    @State private var selectedTier: BotTier?
    @State private var copiedField: Field?
    @FocusState private var focus: Field?
    // Find-in-page over content; Memories tab state.
    @State private var find = FindController()
    @State private var memoriesModel = MemoriesExplorerModel()
    @Environment(\.openWindow) private var openWindow

    init(stub: PromptStub, store: SessionStore, windowID: SessionWindowID) {
        self.stub = stub
        self.store = store
        self.windowID = windowID
        _draftBox = State(initialValue: PromptDraftBox(
            promptKey: "\(windowID.sessionUUID.uuidString)/\(stub.seq)"))
    }

    private var promptKey: String { draftBox.promptKey }

    // The three fields are editable only while the prompt is a draft; a
    // CONTENT_LOCKED save outcome freezes immediately (before the stub's
    // status refresh lands).
    private var editable: Bool {
        PromptStatus(rawValue: stub.status) == .draft && saveIssue != .locked
    }

    // MARK: Find-in-page

    private var findQuery: SearchQuery { find.searchQuery }

    private var findSegments: [(id: String, text: String)] {
        switch tab {
        case .initial:
            return [("backstory", backstory), ("goal", goal), ("detail", detail)]
        case .memories:
            return []
        }
    }

    private var findMatches: FindMatches {
        FindMatches(segments: findSegments, query: findQuery)
    }

    private func activeLocal(_ id: String) -> Int? {
        findMatches.activeLocalOccurrence(in: id, active: find.activeIndex)
    }

    private func stepFind(_ delta: Int, proxy: ScrollViewProxy) {
        guard findMatches.total > 0 else { return }
        find.activeIndex = findMatches.clampedActive(find.activeIndex + delta)
        if let hit = findMatches.activeHit(find.activeIndex) {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(hit.segmentID, anchor: .center) }
        }
    }

    private var supportsFind: Bool { tab == .initial }

    private func segmentID(_ field: Field) -> String {
        switch field {
        case .backstory: "backstory"
        case .goal:      "goal"
        case .detail:    "detail"
        }
    }

    var body: some View {
        Group {
            if loadFailed {
                ContentUnavailableView {
                    Label("Prompt Unavailable", systemImage: "bolt.slash")
                } description: {
                    Text("The prompt couldn't be loaded from the daemon.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else if loaded {
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    switch tab {
                    case .initial:  initialTab
                    case .memories: memoriesTab
                    }
                }
            } else {
                ProgressView().controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(stub.name)
        .navigationSubtitle(PromptStatus(rawValue: stub.status)?.rawValue.capitalized ?? "")
        .toolbar {
            if tab == .initial && editable {
                ToolbarItemGroup {
                    Button { applyUndo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!history.canUndo)
                    Button { applyRedo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!history.canRedo)
                }
            }
            ToolbarItem {
                DaemonStatusIndicator()
            }
            // iTerm: open a terminal rooted at the instance's target repo. Uses a
            // per-instance Dynamic Profile so spawned windows/tabs inherit the repo dir.
            ToolbarItemGroup {
                Button { openInITerm(paths.repoFolder) } label: {
                    Label("Open in iTerm", systemImage: "terminal")
                }
                .disabled(paths.repoFolder == nil)
                .help("Open an iTerm2 window in the instance's target repo (window cwd = repo, via a per-instance dynamic profile)")
            }
            ToolbarItemGroup {
                Button { openInVSCode(paths.repoFolder) } label: {
                    Label("Open Repo", systemImage: "hammer")
                }
                .disabled(paths.repoFolder == nil)
                .help("Open the instance's target repo (implementation checkout) in VS Code")
                Button { openInVSCode(paths.projectFolder) } label: {
                    Label("Open Project", systemImage: "folder")
                }
                .disabled(paths.projectFolder == nil)
                .help("Open the project folder in VS Code")
                Button { openInVSCode(paths.instanceFolder) } label: {
                    Label("Open Instance", systemImage: "internaldrive")
                }
                .disabled(paths.instanceFolder == nil)
                .help("Open the instance folder in VS Code")
                Button { openInVSCode(paths.sessionFolder) } label: {
                    Label("Open Session", systemImage: "arrow.triangle.branch")
                }
                .disabled(paths.sessionFolder == nil)
                .help("Open the session folder in VS Code")
                Button { openInVSCode(paths.promptFolder) } label: {
                    Label("Open Prompt", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .disabled(paths.promptFolder == nil)
                .help("Open the prompt folder in VS Code")
            }
            // A connected cluster of the bot fidelity tiers. Each button copies
            // that tier's resume command and stays highlighted as last-clicked.
            ToolbarItem(placement: .primaryAction) {
                tierCluster
            }
        }
        // Seed once per prompt identity (the pane is recreated per uuid via
        // .id(stub.uuid)); version changes flow through reconcileExternal(),
        // which has the dirty-buffer guard — NEVER through a re-seed. (Keying
        // on the whole stub re-ran load() on every autosave: stub carries
        // `version`.)
        .task(id: stub.uuid) { await load() }
        // Targeted refresh + echo/kbite/path reconciliation on this prompt's
        // events. Stream hoisted before any await so no invalidation is lost.
        .task(id: stub.uuid) {
            let stream = daemon.hub.stream(for: .prompt(stub.uuid))
            for await _ in stream {
                await store.refreshPrompt(uuid: stub.uuid)
                await reconcileExternal()
                reconcileKbites()
                await resolvePaths()
            }
        }
        // Status transitions (draft→clarifying→clarified) flip `editable` via
        // the stub; adopt the frozen server content only when the buffer is clean.
        .onChange(of: stub.status) { _, _ in
            Task {
                await store.refreshPrompt(uuid: stub.uuid)
                await reconcileExternal()
            }
        }
        // cmd+F: the Initial tab opens the inline find bar. On the Memories tab,
        // publish nil so the reader's own find handler owns cmd+F.
        .focusedSceneValue(\.yeetFind, tab == .memories ? nil : {
            if supportsFind {
                find.reset()
                find.isPresented = true
            }
        })
        .onChange(of: tab) { _, _ in
            find.isPresented = false
            find.query = ""
            find.reset()
        }
        .onChange(of: focus) { old, new in
            // Flush when leaving a field (only meaningful while editable).
            if editable, old != nil, old != new { flushSoon() }
        }
        // KBite registry edits persist immediately, in any prompt status. The
        // `loaded` guard ignores the seed assignment in load(); the suppress
        // flag ignores reconciliation assignments.
        .onChange(of: selectedKbites) { old, new in
            guard !kbiteSuppress else { return }
            syncKbites(old: old, new: new)
        }
        .onDisappear {
            saveTask?.cancel()
            // Unregister FIRST (a hung flush must not strand a registry entry
            // that later shadows a re-registered pane), then flush through the
            // reference-backed box — no @State reads after teardown.
            let box = draftBox
            PromptFlushRegistry.shared.unregister(box.promptKey)
            Task { await box.flush() }
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 12) {
            Button {
                tab = .initial
            } label: {
                Label("Initial", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .tint(tab == .initial ? .accentColor : nil)
            // Memories tab. Plain click switches inline; ⌘-click pops it out into
            // its own window, handing off the current selection + expansion.
            Button {
                if NSEvent.modifierFlags.contains(.command), let root = paths.memoryRoot {
                    openWindow(value: PromptMemoriesWindowID(
                        memoryRootURL: root,
                        promptName: stub.name,
                        selectedFile: memoriesModel.selectedFile,
                        expanded: Array(memoriesModel.expanded)
                    ))
                } else {
                    tab = .memories
                }
            } label: {
                Label("Memories", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .tint(tab == .memories ? .accentColor : nil)
            .help("Memory file explorer — \u{2318}-click to open in a separate window")
            statusAdvanceMenu
            if tab == .initial && !editable {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let summary = store.promptDetails[stub.uuid]?.changeSummary, summary.changeCount > 0 {
                Text("\(summary.changeCount) changes · \(summary.distinctFiles) files · \(summary.totalLineSpan) lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("File changes attributed to this prompt")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // Forward-only, adjacent-only status advance (PROMPT_SET_STATUS).
    @ViewBuilder
    private var statusAdvanceMenu: some View {
        if let status = PromptStatus(rawValue: stub.status), let next = status.successor {
            Menu {
                Button("Advance to \(next.rawValue.capitalized)") {
                    advanceStatus(to: next)
                }
            } label: {
                Label(status.rawValue.capitalized, systemImage: "arrow.forward.circle")
                    .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Advance the prompt status (forward-only)")
        }
    }

    private var initialTab: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if find.isPresented && supportsFind {
                    FindBar(find: find, total: findMatches.total,
                            onStep: { stepFind($0, proxy: proxy) })
                }
                ScrollView {
                    VStack(spacing: 16) {
                        saveIssueBanner
                        KBitePillBox(available: availableKbites, selected: $selectedKbites)
                        sectionEditor("Backstory", field: .backstory, text: $backstory,
                                      minHeight: 90, hint: "Narrative context (inherited from the session).")
                        sectionEditor("Goal", field: .goal, text: $goal,
                                      minHeight: 120, hint: "The outcome / acceptance criteria.")
                        sectionEditor("Detail", field: .detail, text: $detail,
                                      minHeight: 220, hint: "The approach, constraints, specifics.")
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .focusedSceneValue(\.yeetFindNext, readOnlyStep(+1, proxy: proxy))
            .focusedSceneValue(\.yeetFindPrev, readOnlyStep(-1, proxy: proxy))
        }
    }

    // Typed save-state surface: conflict / locked / transport failures render as
    // a banner, never silent loss and never message-text matching.
    @ViewBuilder
    private var saveIssueBanner: some View {
        if externalChange != nil || saveIssue == .conflict {
            banner(color: .orange, icon: "exclamationmark.triangle.fill",
                   text: "This prompt changed elsewhere.") {
                Button("Reload") { acceptExternal() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        } else if saveIssue == .locked {
            banner(color: .blue, icon: "lock.fill",
                   text: "This prompt left Draft — content is now read-only. Your unsaved edits were kept in undo history.") {
                EmptyView()
            }
        } else if case .failed(let message) = saveIssue {
            banner(color: .red, icon: "xmark.octagon.fill",
                   text: "Save failed: \(message)") {
                Button("Retry") {
                    saveIssue = nil
                    flushSoon()
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
    }

    private func banner(color: Color, icon: String, text: String,
                        @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer()
            action()
        }
        .padding(12)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 10))
    }

    // cmd+G / cmd+shift+G for the find bar — nil (menu greyed) unless the bar
    // is open with at least one match.
    private func readOnlyStep(_ delta: Int, proxy: ScrollViewProxy) -> (() -> Void)? {
        guard find.isPresented, supportsFind, findMatches.total > 0 else { return nil }
        return { stepFind(delta, proxy: proxy) }
    }

    @ViewBuilder
    private var memoriesTab: some View {
        if let root = paths.memoryRoot {
            MemoriesExplorer(rootURL: root, model: memoriesModel)
        } else {
            ContentUnavailableView(
                "No Memory Folder",
                systemImage: "folder",
                description: Text("This prompt has no memory folder on disk yet (and no registered artifacts).")
            )
        }
    }

    // MARK: Section (initial)

    @ViewBuilder
    private func sectionEditor(_ title: String, field: Field, text: Binding<String>,
                              minHeight: CGFloat, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The title doubles as a quick-copy control.
                Button { copy(field: field, text: text.wrappedValue) } label: {
                    HStack(spacing: 5) {
                        Text(title).font(.headline)
                        Image(systemName: copiedField == field ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copiedField == field ? .green : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy \(title.lowercased())")
                Spacer()
                Text("\(text.wrappedValue.count)")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            if editable {
                // AppKit-backed editor with live markdown header highlighting + a
                // line-number gutter. cmd+F routes to the inline find-in-page bar.
                MarkdownSourceEditor(text: text, minHeight: minHeight,
                                     query: findQuery,
                                     activeOccurrence: activeLocal(segmentID(field)))
                    .background(.black.opacity(0.04), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .id(segmentID(field))
                    .onChange(of: text.wrappedValue) { _, _ in
                        draftBox.markDirty(currentState())
                        scheduleSave()
                    }
            } else {
                HighlightedText(source: text.wrappedValue.isEmpty ? "—" : text.wrappedValue,
                                query: findQuery,
                                activeLocalOccurrence: activeLocal(segmentID(field)))
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                    .background(.black.opacity(0.04), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .id(segmentID(field))
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: Load / save

    private func load() async {
        loaded = false
        loadFailed = false
        saveIssue = nil
        externalChange = nil
        if store.promptDetails[stub.uuid] == nil {
            await store.refreshPrompt(uuid: stub.uuid)
        }
        guard let response = store.promptDetails[stub.uuid] else {
            loadFailed = true
            return
        }
        let prompt = response.prompt
        backstory = prompt.backstory
        goal = prompt.goal
        detail = prompt.detail
        kbiteSuppress = true
        selectedKbites = response.kbiteCodes
        kbiteSuppress = false
        let newSaver = PromptSaveActor(promptUuid: prompt.uuid, version: prompt.version)
        saver = newSaver
        draftBox.saver = newSaver
        loadAvailableKbites()
        let s = currentState()
        lastSaved = s
        history.load(promptKey: promptKey, current: s)
        tab = .initial
        // Register with the quit-flush registry (bounded drain on termination).
        PromptFlushRegistry.shared.register(draftBox)
        loaded = true
        await resolvePaths()
    }

    /// Resolve filesystem locations off-main (the resolver does FileManager
    /// probes; body must never trigger them).
    private func resolvePaths() async {
        let root = gmcc[.ckfsRoot]
        let sessionStub = catalog.sessionsByUuid[store.sessionUuid]
        let instance = catalog.instance(uuid: windowID.instanceUUID.wireString)
        let project = instance.flatMap { inst in catalog.projects.first { $0.uuid == inst.projectUuid } }
        let artifacts = store.promptDetails[stub.uuid]?.artifacts ?? []
        let seq = stub.seq
        let code = stub.code
        let name = stub.name
        let resolved: ResolvedPaths = await Task.detached(priority: .userInitiated) {
            var p = ResolvedPaths()
            if let path = instance?.absoluteFileSystemPath, !path.isEmpty {
                p.repoFolder = URL(fileURLWithPath: path, isDirectory: true)
            }
            // No $GMCC_CKFS_ROOT → every ckfs-derived location is nil (buttons
            // disable; Memories explains) instead of resolving against cwd.
            guard let root, !root.isEmpty else { return p }
            if let sessionStub {
                p.sessionFolder = CkfsPathResolver.resolve(
                    relative: sessionStub.ckfsRelativeStoragePath, ckfsRoot: root)
                p.promptFolder = CkfsPathResolver.promptFolder(
                    ckfsRoot: root, session: sessionStub, seq: seq, code: code, name: name)
                p.memoryRoot = CkfsPathResolver.memoryRoot(
                    ckfsRoot: root, session: sessionStub, seq: seq, code: code, name: name,
                    artifacts: artifacts)
            }
            if let instance {
                p.instanceFolder = CkfsPathResolver.resolve(
                    relative: instance.ckfsRelativeStoragePath, ckfsRoot: root)
            }
            if let project {
                p.projectFolder = CkfsPathResolver.resolve(
                    relative: project.ckfsRelativeStoragePath, ckfsRoot: root)
            }
            return p
        }.value
        if paths != resolved { paths = resolved }
    }

    private func openInVSCode(_ url: URL?) {
        guard let url else { return }
        VSCode.open(url)
    }

    private func openInITerm(_ url: URL?) {
        guard let url else { return }
        ITerm.open(dir: url, instanceUUID: windowID.instanceUUID,
                   instanceName: catalog.instance(uuid: windowID.instanceUUID.wireString)?.name ?? "—")
    }

    private func currentState() -> PromptEditHistory.EditState {
        .init(backstory: backstory, goal: goal, detail: detail)
    }

    // Debounced autosave (~2s after typing stops — daemon writes are cheap
    // socket round trips, so a short window shrinks worst-case loss).
    private func scheduleSave() {
        // Paused while a conflict awaits resolution or the prompt locked
        // (repeat CONTENT_LOCKED failures are pointless).
        guard saveIssue != .conflict, saveIssue != .locked else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await flush(record: true)
        }
    }

    private func flushSoon() {
        saveTask?.cancel()
        saveTask = Task { await flush(record: true) }
    }

    // Version-threaded save through the per-prompt actor. Typed outcomes drive
    // the banner; a conflict pauses autosave until the user reloads.
    private func flush(record: Bool) async {
        guard loaded, let saver else { return }
        let s = currentState()
        if s == lastSaved {
            if record { history.record(s) }   // no-op if cursor already matches
            return
        }
        let outcome = await saver.save(backstory: s.backstory, goal: s.goal, detail: s.detail)
        switch outcome {
        case .saved:
            lastSaved = s
            draftBox.markSaved(s)
            if record { history.record(s) }
            if saveIssue != nil { saveIssue = nil }
        case .conflict:
            await store.refreshPrompt(uuid: stub.uuid)
            externalChange = store.promptDetails[stub.uuid]?.prompt
            saveIssue = .conflict
            history.record(s)   // keep the local text reachable via undo
        case .locked:
            saveIssue = .locked
            history.record(s)   // preserve unsaved edits as an orphaned draft
            draftBox.markSaved(s)   // don't retry a locked draft at quit
            await store.refreshPrompt(uuid: stub.uuid)
        case .failed(let message):
            saveIssue = .failed(message)
        }
    }

    // An UPDATE_PROMPT event arrived for this prompt: the refetched row's
    // version against the save actor's watermark separates our own echo from a
    // genuine external edit. Adopt silently only when the buffer is clean.
    private func reconcileExternal() async {
        guard loaded, let saver,
              let fresh = store.promptDetails[stub.uuid]?.prompt else { return }
        let watermark = await saver.lastWrittenVersion
        guard fresh.version > watermark else { return }   // own echo — drop
        if currentState() == lastSaved {
            backstory = fresh.backstory
            goal = fresh.goal
            detail = fresh.detail
            lastSaved = currentState()
            await saver.adoptVersion(fresh.version)
        } else {
            externalChange = fresh   // never clobber in-flight typing
        }
    }

    private func acceptExternal() {
        guard let fresh = externalChange ?? store.promptDetails[stub.uuid]?.prompt else { return }
        backstory = fresh.backstory
        goal = fresh.goal
        detail = fresh.detail
        lastSaved = currentState()
        draftBox.markSaved(lastSaved)
        externalChange = nil
        if saveIssue == .conflict { saveIssue = nil }
        history.record(lastSaved)
        Task { await saver?.adoptVersion(fresh.version) }
    }

    // MARK: Status transitions

    private func advanceStatus(to next: PromptStatus) {
        let expected = store.promptDetails[stub.uuid]?.prompt.version ?? stub.version
        Task {
            do {
                _ = try await GMCCDaemonService.shared.setPromptStatus(PromptSetStatusRequest(
                    promptUuid: stub.uuid,
                    expectedVersion: expected,
                    status: next
                ))
                await store.refresh()
            } catch let error as DaemonError {
                switch error {
                case .invalidTransition:
                    saveIssue = .failed("Status transitions are forward-only and adjacent-only.")
                case .versionConflict:
                    await store.refreshPrompt(uuid: stub.uuid)
                    externalChange = store.promptDetails[stub.uuid]?.prompt
                    saveIssue = .conflict
                default:
                    saveIssue = .failed(String(describing: error))
                }
            } catch {
                saveIssue = .failed(String(describing: error))
            }
        }
    }

    // MARK: KBites

    // Installed kbites under $GMCC_KBITE_DIGESTED, unioned with the current
    // selection so an already-registered kbite missing from disk still renders
    // (and can be deselected).
    private func loadAvailableKbites() {
        var names: [String] = []
        if let digested = gmcc[.kbiteDigested] {
            let dir = URL(fileURLWithPath: digested, isDirectory: true)
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            names = contents.compactMap { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                return isDir ? url.lastPathComponent : nil
            }
        }
        availableKbites = Set(names).union(selectedKbites).sorted()
    }

    // Persist a pill toggle as registry deltas at prompt scope. KBITE_ADD
    // upserts the kbite row, so this works against an empty kbite table. On
    // failure the pills reconcile back to the db state and a banner shows.
    private func syncKbites(old: [String], new: [String]) {
        guard loaded else { return }
        let added = Set(new).subtracting(old)
        let removed = Set(old).subtracting(new)
        guard !added.isEmpty || !removed.isEmpty else { return }
        let uuid = stub.uuid
        Task {
            let service = GMCCDaemonService.shared
            var failed = false
            for code in added.sorted() {
                if (try? await service.addKbite(scope: .prompt, ownerUuid: uuid, code: code)) == nil {
                    failed = true
                }
            }
            for code in removed.sorted() {
                if (try? await service.removeKbite(scope: .prompt, ownerUuid: uuid, code: code)) == nil {
                    failed = true
                }
            }
            await store.refreshPrompt(uuid: uuid)
            if failed {
                reconcileKbites()
                saveIssue = .failed("KBite registry update failed — pills reset to the daemon's state.")
            }
        }
    }

    // Converge the pill box back to the db registry (terminal-side edits,
    // failed toggles). Suppressed from re-triggering syncKbites.
    private func reconcileKbites() {
        guard loaded, let codes = store.promptDetails[stub.uuid]?.kbiteCodes else { return }
        if Set(codes) != Set(selectedKbites) {
            kbiteSuppress = true
            selectedKbites = codes
            availableKbites = Set(availableKbites).union(codes).sorted()
            kbiteSuppress = false
        }
    }

    // MARK: Undo / redo

    private func applyUndo() {
        guard let s = history.undo() else { return }
        apply(s)
    }

    private func applyRedo() {
        guard let s = history.redo() else { return }
        apply(s)
    }

    // Apply a history state to the fields WITHOUT recording a new snapshot, then
    // persist through the version-threaded save path (never a blind write).
    private func apply(_ s: PromptEditHistory.EditState) {
        backstory = s.backstory
        goal = s.goal
        detail = s.detail
        draftBox.markDirty(s)
        saveTask?.cancel()
        saveTask = Task { await flush(record: false) }
    }

    // MARK: Clipboard

    private func copy(field: Field, text: String) {
        Clipboard.copy(text)
        copiedField = field
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedField == field { copiedField = nil }
        }
    }

    // A connected cluster of bot-fidelity tier buttons (1/2/3-person icons).
    // Each button copies that tier's resume command (`/{command} {seq}`) to the
    // clipboard and becomes the highlighted "last-clicked" tier.
    private var tierCluster: some View {
        ControlGroup {
            ForEach(BotTier.allCases) { tier in
                let isSelected = selectedTier == tier
                Button { copyResume(tier) } label: {
                    Label(tier.command, systemImage: tierSymbol(tier, selected: isSelected))
                }
                .tint(isSelected ? .accentColor : nil)
                .help("Copy \(tier.command(for: Int(stub.seq))) to the clipboard")
            }
        } label: {
            Label("Resume Command", systemImage: "person.fill")
        }
    }

    private func tierSymbol(_ tier: BotTier, selected: Bool) -> String {
        selected ? tier.symbol : tier.symbol.replacingOccurrences(of: ".fill", with: "")
    }

    private func copyResume(_ tier: BotTier) {
        // Bot commands resolve prompts by their daemon-allocated per-session seq.
        Clipboard.copy(tier.command(for: Int(stub.seq)))
        selectedTier = tier
    }
}

// MARK: - Bot fidelity tiers

// The three GMCC bot fidelity tiers. Each maps to a resume command that the
// editor copies to the clipboard for the user to paste into Claude Code.
enum BotTier: String, CaseIterable, Identifiable {
    case gmBot     = "/gm_bot"
    case gmBotRPI  = "/gm_bot_rpi"
    case gmBotTeam = "/gm_bot_team"

    var id: String { rawValue }
    var command: String { rawValue }

    // 1 / 2 / 3-person icons — increasing crew size by fidelity tier.
    var symbol: String {
        switch self {
        case .gmBot:     return "person.fill"
        case .gmBotRPI:  return "person.2.fill"
        case .gmBotTeam: return "person.3.fill"
        }
    }

    func command(for id: Int) -> String { "\(command) \(id)" }
}

// MARK: - Clipboard helper

enum Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - VS Code launcher

enum VSCode {
    // Opens a folder as a VS Code workspace. Prefers launching the app bundle
    // directly (no dependency on the `code` CLI being on PATH); falls back to
    // revealing the folder in Finder if VS Code isn't installed.
    static func open(_ url: URL) {
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            let config = NSWorkspace.OpenConfiguration()
            ws.open([url], withApplicationAt: app, configuration: config)
        } else {
            ws.activateFileViewerSelecting([url])
        }
    }
}

// MARK: - iTerm2 launcher

// Opens an iTerm2 window rooted at `dir` via a PER-INSTANCE Dynamic Profile, so
// windows/tabs spawned from it default to the same repo dir. The profile JSON is
// rewritten in place (deterministic Guid) on every open; a single malformed file
// disables ALL dynamic profiles, so we serialize/validate, then write atomically.
// Falls back to NSWorkspace open-at-dir, then a Finder reveal — mirroring VSCode.
enum ITerm {
    // Writes the per-instance Dynamic Profile OFF the main thread, then opens the
    // window ON the main thread. Both the file write and a cold-iTerm AppleScript
    // launch are slow enough to hitch the UI if run inline from the button action.
    static func open(dir: URL, instanceUUID: UUID, instanceName: String) {
        let guid = "gmvibes-\(instanceUUID.uuidString)"
        let name = "GMVibes — \(instanceName)"
        Task.detached(priority: .userInitiated) {
            let wrote = writeProfile(guid: guid, name: name, workingDir: dir.path)
            await MainActor.run { launch(dir: dir, profileName: name, profileWritten: wrote) }
        }
    }

    // Open a window for the per-instance profile, falling back to NSWorkspace
    // open-at-dir, then a Finder reveal — mirroring VSCode. NSAppleScript must run
    // on the main thread (TN2097), so this whole step is MainActor-isolated.
    @MainActor
    private static func launch(dir: URL, profileName: String, profileWritten: Bool) {
        if profileWritten, runAppleScript(profileName: profileName) { return }
        let ws = NSWorkspace.shared
        if let term = ws.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") {
            ws.open([dir], withApplicationAt: term, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.activateFileViewerSelecting([dir])
        }
    }

    // ~/Library/Application Support/iTerm2/DynamicProfiles, created if absent.
    // `nonisolated` so the profile write can run off the main actor.
    private nonisolated static func dynamicProfilesDir() -> URL? {
        guard let appSup = FileManager.default.urls(for: .applicationSupportDirectory,
                                                    in: .userDomainMask).first else { return nil }
        let dir = appSup.appendingPathComponent("iTerm2/DynamicProfiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Idempotent per-instance profile file: gmvibes-<UUID>.json with one profile.
    // JSONSerialization both validates the shape and renders the bytes we write.
    // `nonisolated` so it can run off the main actor (pure FileManager/JSON work).
    private nonisolated static func writeProfile(guid: String, name: String, workingDir: String) -> Bool {
        guard let dir = dynamicProfilesDir() else { return false }
        let payload: [String: Any] = ["Profiles": [[
            "Guid": guid,
            "Name": name,
            "Custom Directory": "Yes",
            "Working Directory": workingDir,
        ]]]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted]) else { return false }
        let url = dir.appendingPathComponent("\(guid).json")
        let tmp = dir.appendingPathComponent(".\(guid).json.tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    // Open a window for the named profile (NSWorkspace can't select a profile).
    // The AppleScript API is deprecated but functional; NSAppleScript drives it.
    @MainActor
    private static func runAppleScript(profileName: String) -> Bool {
        // AppleScript string literals don't support backslash escaping — splice any
        // embedded double quote in via the `quote` constant instead.
        let escaped = profileName.replacingOccurrences(of: "\"", with: "\" & quote & \"")
        let source = """
        tell application "iTerm2"
            create window with profile "\(escaped)"
            activate
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var err: NSDictionary?
        script.executeAndReturnError(&err)
        return err == nil
    }
}
