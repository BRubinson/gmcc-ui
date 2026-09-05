import SwiftUI
import AppKit
import GMCCDaemonKit

// Per-session prompt-authoring screen. Left: a flat navigator of the session's
// prompts (SESSION_GET / PROMPT_LIST stubs). Right: a three-section code-style
// editor (backstory / goal / detail) over the selected prompt's daemon row, with
// version-threaded autosave, in-memory undo/redo, per-section copy, and a
// toolbar "Run" button that exports the `/gm_bot {seq}` resume command.

struct SessionPromptEditorView: View {
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    @Environment(WindowNav.self) private var nav
    let windowID: SessionWindowID

    @State private var scope: SessionScope
    @State private var selectedUuid: String?
    @State private var didDefaultSelect = false
    @State private var showCreatePrompt = false
    // One list filter over both fields: name + content (all sections).
    @State private var promptQuery = ""

    private var store: SessionStore { scope.store }

    init(windowID: SessionWindowID) {
        self.windowID = windowID
        // Create-or-get is side-effect-safe in init; the refcount lease lives
        // in onAppear/onDisappear, which SwiftUI balances.
        _scope = State(initialValue: SessionScopeCache.shared.scope(for: windowID.sessionUUID.wireString))
        // Deep-link seed. Seeding in init (not onAppear) beats the newest-prompt
        // default with no visible flash AND covers the grace-revived case, where
        // prompts are already loaded so onChange(of: prompts) never fires.
        // didDefaultSelect is pre-spent so the default rule can't overwrite it.
        let target = windowID.targetPromptUUID?.wireString
        _selectedUuid = State(initialValue: target)
        _didDefaultSelect = State(initialValue: target != nil)
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
                ToolbarItem {
                    Button {
                        nav.go(.search(SearchSeed(sessionUuid: windowID.sessionUUID.wireString)))
                    } label: {
                        Label("Search Session", systemImage: "magnifyingglass")
                    }
                    .help("Full-text search, scoped to this session")
                }
            }
        } detail: {
            if let stub = selectedStub {
                PromptEditorPane(
                    stub: stub,
                    scope: scope,
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
        // Repeat deep-link into this already-open screen: `go`'s route-equality
        // guard means no re-init, so the retarget arrives on the one-shot
        // pending channel instead. Consuming clears it (the nil re-fire is
        // guarded), keeping the channel armed for the next identical hit.
        .onChange(of: nav.pendingPromptTarget) { _, target in
            guard let target else { return }
            selectedUuid = target.wireString
            didDefaultSelect = true
            nav.pendingPromptTarget = nil
        }
        .onAppear {
            // The init path already consumed this screen's own seed — clear it
            // so a later identical hit registers as a fresh change.
            if nav.pendingPromptTarget == windowID.targetPromptUUID {
                nav.pendingPromptTarget = nil
            }
        }
        // Event-driven refresh: SESSION_GET on session invalidations. The
        // stream is hoisted BEFORE the first refresh so an invalidation that
        // fires during the initial (prefetch-heavy) load isn't lost.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .session(store.sessionUuid))
            if !catalog.hasLoaded { await catalog.refresh() }
            await store.refresh()
            // A stale/foreign deep-link target degrades to the newest prompt
            // rather than stranding the detail pane on "No Prompt Selected".
            if selectedUuid == nil || !store.prompts.contains(where: { $0.uuid == selectedUuid }) {
                selectedUuid = store.prompts.first?.uuid
                // Re-arm the newest-prompt default when there was nothing to
                // select — a pre-spent flag would otherwise block auto-select
                // when this (empty) session gains its first prompt.
                didDefaultSelect = selectedUuid != nil
            }
            scope.registerPrompts(Set(store.prompts.map(\.uuid)), daemon: daemon)
            for await _ in stream {
                await store.refresh()
                scope.registerPrompts(Set(store.prompts.map(\.uuid)), daemon: daemon)
            }
        }
        // Keep instance/project identity + path derivations live on renames.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .topology)
            for await _ in stream {
                await catalog.refresh()
            }
        }
        // The scope lease. `.task` is contractually balanced against view
        // lifetime (unlike onAppear/onDisappear), so acquire/release can never
        // go unpaired and retire a scope another window still holds. Keyed on
        // the session uuid — NOT daemon.generation — so a reconnect resync
        // doesn't drop and re-acquire the lease.
        .task(id: scope.sessionUuid) {
            SessionScopeCache.shared.acquire(scope.sessionUuid)
            defer { SessionScopeCache.shared.release(scope.sessionUuid) }
            // Hold until cancellation; the refresh loops live in their own
            // generation-keyed tasks.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }
}

// MARK: - Navigator

private struct PromptNavigator: View {
    let sessionName: String
    let instanceName: String
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
                    // Path-open actions live in the toolbar's single "Open in…"
                    // menu now — the header is identity only.
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


// MARK: - Editor pane

private struct PromptEditorPane: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    let stub: PromptStub
    let scope: SessionScope
    let windowID: SessionWindowID

    private var store: SessionStore { scope.store }

    enum Field: Hashable { case backstory, goal, detail }

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
        /// True when memoryRoot is the exact directory PROMPT_MEMORY_CHANGED
        /// describes (see CkfsPathResolver.ResolvedMemory).
        var memoryIsDaemonWatched = false
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
    // Memories explorer, hosted as a trailing inspector (the top-bar slot's
    // control toggles it) — the old Initial/Memories tab bar is gone.
    @State private var showMemories = false
    @State private var lastSaved = PromptEditHistory.EditState(backstory: "", goal: "", detail: "")
    /// Highest prompt version THIS pane has written or synchronized to — the
    /// echo/external discriminator (the shared actor's watermark can't tell a
    /// peer pane's write from our own echo).
    @State private var localWatermark: Int64 = 0
    @State private var history = PromptEditHistory()
    @State private var saveTask: Task<Void, Never>?
    @State private var selectedTier: BotTier?
    @State private var copiedField: Field?
    @FocusState private var focus: Field?
    // Find-in-page over content; Memories tab state.
    @State private var find = FindController()
    @State private var memoriesModel = MemoriesExplorerModel()
    // Phase document state: the clarification/architecture read model (scope-
    // memoized) + per-section expansion, seeded from the prompt's status.
    @State private var phases: PromptPhaseStore
    @State private var clarifyExpanded = false
    @State private var archExpanded = false
    @State private var exploreExpanded = false
    @State private var reviewExpanded = false
    @Environment(WindowNav.self) private var nav

    init(stub: PromptStub, scope: SessionScope, windowID: SessionWindowID) {
        self.stub = stub
        self.scope = scope
        self.windowID = windowID
        // Create-or-get, same init-safety contract as SessionScopeCache.scope.
        _phases = State(initialValue: scope.phases(forPrompt: stub.uuid))
        // PANE-owned box under a globally-unique key: each pane's unsaved
        // draft is its own registry entry (no shared-key eviction, no clobber
        // between two panes on one prompt — the shared actor version-checks
        // the second flush instead). No side effects here: registration
        // happens in load(), so SwiftUI re-running init is harmless.
        _draftBox = State(initialValue: PromptDraftBox(
            promptKey: "\(stub.uuid)#\(UUID().uuidString)"))
    }

    private var promptKey: String { draftBox.promptKey }

    // The three fields are editable only while the prompt is a draft; a
    // CONTENT_LOCKED save outcome freezes immediately (before the stub's
    // status refresh lands).
    private var editable: Bool {
        PromptStatus(rawValue: stub.status) == .draft && saveIssue != .locked
    }

    /// Clarify/arch ONLY: draft prompts provably have no clarification or
    /// architecture summary — fetching those two would burst guaranteed
    /// NOT_FOUNDs per selection onto the serial queue. Exploration and review
    /// are NEVER gated on this (EXPLORE_OPEN/REVIEW_OPEN are explicit-only
    /// and legally run while the prompt is still draft) — this flag feeds
    /// `refresh(lifecyclePhases:)`, which always fetches those two.
    private var phasesApply: Bool {
        PromptStatus(rawValue: stub.status) != .draft
    }

    // Live-phase-first badge precedence: the loaded response is authoritative
    // (report writes don't re-list the session, so stub.reports goes stale);
    // the PROMPT_LIST stub covers the cold start.
    /// Does anything suggest an exploration/review summary exists for this
    /// (draft) prompt? Loaded phases keep refreshing; otherwise trust the
    /// listing's with_reports stubs.
    private func reportsEvidence(_ fresh: PromptStub) -> Bool {
        if case .loaded = phases.exploration { return true }
        if case .loaded = phases.review { return true }
        return fresh.reports?.exploration != nil || fresh.reports?.review != nil
    }

    private var explorationBadges: [ReportBadgeItem] {
        if case .loaded(let response) = phases.exploration { return ReportBadgeItem.exploration(response) }
        if let reportStub = stub.reports?.exploration { return ReportBadgeItem.exploration(reportStub) }
        return []
    }

    private var reviewBadges: [ReportBadgeItem] {
        if case .loaded(let response) = phases.review { return ReportBadgeItem.review(response) }
        if let reportStub = stub.reports?.review { return ReportBadgeItem.review(reportStub) }
        return []
    }

    /// Post-draft, the clarification's refined goal/detail SUPERSEDE the
    /// frozen originals — they render as primary, originals in a disclosure.
    private var refinedContent: (goal: String, detail: String)? {
        guard !editable, case .loaded(let response) = phases.clarification else { return nil }
        let goal = response.summary.refinedGoal
        let detail = response.summary.refinedDetail
        if goal.isEmpty && detail.isEmpty { return nil }
        return (goal, detail)
    }

    // MARK: Find-in-page

    private var findQuery: SearchQuery { find.searchQuery }

    private var findSegments: [(id: String, text: String)] {
        [("backstory", backstory), ("goal", goal), ("detail", detail)]
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

    // While the memories inspector is open, its reader owns ⌘F/⌘G — the pane
    // publishes nil so the two focused-value publishers never collide.
    private var supportsFind: Bool { !showMemories }

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
                initialTab
                    .inspector(isPresented: $showMemories) {
                        // Column min must exceed the explorer's summed pane
                        // minimums (160 + 240) or AppKit fights the layout.
                        memoriesTab
                            .inspectorColumnWidth(min: 420, ideal: 480, max: 720)
                    }
            } else {
                ProgressView().controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(stub.name)
        .navigationSubtitle(PromptStatus(rawValue: stub.status)?.rawValue.capitalized ?? "")
        .toolbar {
            if editable {
                ToolbarItemGroup {
                    Button { applyUndo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!history.canUndo)
                    Button { applyRedo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!history.canRedo)
                }
            }
            // All external open actions folded into ONE menu (was 5 VS Code
            // buttons + an iTerm button).
            ToolbarItem {
                Menu {
                    Button("iTerm at Repo") { openInITerm(paths.repoFolder) }
                        .disabled(paths.repoFolder == nil)
                    Divider()
                    Button("Repo in VS Code") { openInVSCode(paths.repoFolder) }
                        .disabled(paths.repoFolder == nil)
                    Button("Project in VS Code") { openInVSCode(paths.projectFolder) }
                        .disabled(paths.projectFolder == nil)
                    Button("Instance in VS Code") { openInVSCode(paths.instanceFolder) }
                        .disabled(paths.instanceFolder == nil)
                    Button("Session in VS Code") { openInVSCode(paths.sessionFolder) }
                        .disabled(paths.sessionFolder == nil)
                    Button("Prompt in VS Code") { openInVSCode(paths.promptFolder) }
                        .disabled(paths.promptFolder == nil)
                } label: {
                    Label("Open in…", systemImage: "arrow.up.forward.app")
                }
                .help("Open the repo/project/instance/session/prompt externally")
            }
            // The top bar's trailing slot: memories access + the tier cluster.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if NSEvent.modifierFlags.contains(.command), let root = paths.memoryRoot {
                        // Navigate THIS window to the memories page (route-
                        // switched view, Back returns to the editor) — not a
                        // separate OS window.
                        nav.go(.promptMemories(PromptMemoriesWindowID(
                            memoryRootURL: root,
                            promptName: stub.name,
                            selectedFile: memoriesModel.selectedFile,
                            expanded: Array(memoriesModel.expanded),
                            promptUuid: stub.uuid,
                            isDaemonWatched: paths.memoryIsDaemonWatched
                        )))
                    } else {
                        showMemories.toggle()
                    }
                } label: {
                    Label("Memories", systemImage: "folder")
                }
                .help("Memory file explorer — \u{2318}-click to open as a full page")
                tierCluster
            }
        }
        // Seed once per prompt identity (the pane is recreated per uuid via
        // .id(stub.uuid)); version changes flow through reconcileExternal(),
        // which has the dirty-buffer guard — NEVER through a re-seed. (Keying
        // on the whole stub re-ran load() on every autosave: stub carries
        // `version`.)
        .task(id: stub.uuid) {
            await load()
            seedPhaseExpansion()
            // Memoized store — a re-selection of an already-loaded prompt
            // must not re-issue guaranteed round trips. The event loop below
            // still refreshes on every real mutation. Explore/review always fetch
            // (they legally exist at draft); `lifecyclePhases` only skips
            // the two guaranteed-absent clarify/arch trips at draft.
            if !phases.hasLoaded { await phases.refresh(lifecyclePhases: phasesApply) }
        }
        // Targeted refresh + echo/kbite/path reconciliation on this prompt's
        // events. Stream hoisted before any await so no invalidation is lost.
        // CLARIFICATION_CHANGE/ARCHITECTURE_CHANGE also land here (via the
        // summary registry), so the phase store refreshes on the same domain.
        .task(id: stub.uuid) {
            let stream = daemon.hub.stream(for: .prompt(stub.uuid))
            for await _ in stream {
                // Trailing debounce: clarify/arch events fire PER ROW (a bot
                // clarify phase = 10 events) and this handler is several
                // RPCs; events landing during the sleep buffer (newest-1)
                // into the next iteration.
                try? await Task.sleep(for: .milliseconds(300))
                await store.refreshPrompt(uuid: stub.uuid)
                await reconcileExternal()
                reconcileKbites()
                await resolvePaths()
                // Evidence-gated reports refresh (review finding): a draft
                // autosave fires this loop on every flush, and a draft's
                // reports are almost always absent — skip the two GETs unless
                // the FRESHLY-listed stub (refreshPrompt above re-listed it
                // with_reports; an EXPLORATION_CHANGE therefore surfaces a
                // summary stub before we gate) or an already-loaded phase says
                // a summary exists. The captured `stub` is stale inside this
                // loop — read the live listing from the store.
                let fresh = store.prompts.first { $0.uuid == stub.uuid } ?? stub
                let isDraft = PromptStatus(rawValue: fresh.status) == .draft
                await phases.refresh(
                    lifecyclePhases: !isDraft,
                    reports: !isDraft || reportsEvidence(fresh))
            }
        }
        // Status transitions (draft→clarifying→…→done) flip `editable` via
        // the stub. Store refresh + reconciliation ride the .prompt event arm
        // (PROMPT_STATUS_CHANGE routes there) — this handler only re-seeds
        // emphasis and fetches phases with a FRESH capture: the event loop's
        // captured self can hold a stale pre-transition status, so its
        // `phasesApply` misses the draft → clarifying boundary.
        .onChange(of: stub.status) { _, _ in
            seedPhaseExpansion()
            Task { await phases.refresh(lifecyclePhases: phasesApply) }
        }
        // cmd+F opens the inline find bar over the three sections; nil while
        // the memories inspector is open so its reader owns the shortcut.
        .focusedSceneValue(\.findInPage, showMemories ? nil : {
            find.reset()
            find.isPresented = true
        })
        .onChange(of: showMemories) { _, open in
            if open {
                find.isPresented = false
                find.query = ""
                find.reset()
            }
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
            // Unregister FIRST (a hung flush must not strand a registry entry),
            // then flush through the reference-backed box — no @State reads
            // after teardown. Keys are per-pane-unique, so this can never
            // touch another pane's entry.
            let box = draftBox
            PromptFlushRegistry.shared.unregister(box.promptKey)
            Task { await box.flush() }
        }
    }

    // MARK: Tabs

    private var initialTab: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if find.isPresented && supportsFind {
                    FindBar(find: find, total: findMatches.total,
                            onStep: { stepFind($0, proxy: proxy) })
                }
                ScrollView {
                    VStack(spacing: 16) {
                        PromptLifecycleBar(stub: stub, phases: phases, store: store)
                        saveIssueBanner
                        if !editable {
                            // The initial prompt is read-only once past draft;
                            // memories (the top-bar slot) are the live surface.
                            Label("Initial prompt — read-only", systemImage: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        KBitePillBox(available: availableKbites, selected: $selectedKbites)
                        sectionEditor("Backstory", field: .backstory, text: $backstory,
                                      minHeight: 90, hint: "Narrative context (inherited from the session).")
                        if let refined = refinedContent, !refined.goal.isEmpty {
                            refinedSection("Goal", refined: refined.goal, original: goal)
                        } else {
                            sectionEditor("Goal", field: .goal, text: $goal,
                                          minHeight: 120, hint: "The outcome / acceptance criteria.")
                        }
                        if let refined = refinedContent, !refined.detail.isEmpty {
                            refinedSection("Detail", refined: refined.detail, original: detail)
                        } else {
                            sectionEditor("Detail", field: .detail, text: $detail,
                                          minHeight: 220, hint: "The approach, constraints, specifics.")
                        }
                        phaseCard("Clarification", systemImage: "questionmark.bubble",
                                  expanded: $clarifyExpanded,
                                  accessory: { EmptyView() }) {
                            if phasesApply {
                                ClarificationPane(phase: phases.clarification)
                            } else {
                                notStarted("Clarification begins when the prompt leaves Draft.")
                            }
                        }
                        phaseCard("Architecture", systemImage: "square.stack.3d.up",
                                  expanded: $archExpanded,
                                  accessory: { EmptyView() }) {
                            if phasesApply {
                                ArchitecturePane(phase: phases.architecture)
                            } else {
                                notStarted("Architecture begins after clarification completes.")
                            }
                        }
                        // Exploration/review are UNGATED: their summaries are
                        // explicit-only opens that legally exist at draft.
                        phaseCard("Exploration", systemImage: "binoculars",
                                  expanded: $exploreExpanded,
                                  accessory: { ReportBadgeCluster(items: explorationBadges) }) {
                            ExplorationPane(phase: phases.exploration) {
                                await phases.requestFullExploration()
                            }
                        }
                        phaseCard("Review", systemImage: "checkmark.seal",
                                  expanded: $reviewExpanded,
                                  accessory: { ReportBadgeCluster(items: reviewBadges) }) {
                            ReviewPane(phase: phases.review) {
                                await phases.requestFullReview()
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .focusedSceneValue(\.findNext, readOnlyStep(+1, proxy: proxy))
            .focusedSceneValue(\.findPrevious, readOnlyStep(-1, proxy: proxy))
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
            // No undo-history promise: the Undo toolbar hides with `editable`
            // and a locked prompt can't be written anyway. The buffers are
            // still on screen — offer a copy instead.
            banner(color: .blue, icon: "lock.fill",
                   text: "This prompt left Draft — content is now read-only. Your unsaved text is still shown below.") {
                Button("Copy All") {
                    Clipboard.copy("## Backstory\n\(backstory)\n\n## Goal\n\(goal)\n\n## Detail\n\(detail)")
                }
                .buttonStyle(.bordered).controlSize(.small)
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

    // MARK: Phase document sections

    /// Persistent section card: sections NEVER disappear with status — status
    /// only drives which one is expanded by default (seedPhaseExpansion).
    private func phaseCard(_ title: String, systemImage: String,
                           expanded: Binding<Bool>,
                           @ViewBuilder accessory: () -> some View,
                           @ViewBuilder content: () -> some View) -> some View {
        let built = content()
        let trailing = accessory()
        return DisclosureGroup(isExpanded: expanded) {
            built
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                trailing   // count badges — header signal, never a control
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
    }

    private func notStarted(_ message: String) -> some View {
        Label(message, systemImage: "hourglass")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// Default emphasis by phase: the section the current status makes
    /// relevant opens and the other closes; the user's later toggles are
    /// never overridden except on a status change (which re-seeds
    /// deliberately — emphasis follows the phase, not accumulation).
    private func seedPhaseExpansion() {
        switch PromptStatus(rawValue: stub.status) {
        case .draft:
            // Exploration is the one report that legally runs at draft
            // (explicit-only open) — emphasize it, not clarify/arch.
            exploreExpanded = true
            clarifyExpanded = false
            archExpanded = false
            reviewExpanded = false
        case .clarifying:
            clarifyExpanded = true
            archExpanded = false
            exploreExpanded = false
            reviewExpanded = false
        case .architecting, .implementing:
            archExpanded = true
            clarifyExpanded = false
            exploreExpanded = false
            reviewExpanded = false
        case .reviewing:
            reviewExpanded = true
            clarifyExpanded = false
            archExpanded = false
            exploreExpanded = false
        default:
            break
        }
    }

    /// Refined-by-clarification presentation: the refined text primary, the
    /// frozen original tucked in a disclosure.
    private func refinedSection(_ title: String, refined: String, original: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Label("Refined by clarification", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
            Text(refined)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.blue.opacity(0.06), in: .rect(cornerRadius: 8))
            if !original.isEmpty {
                DisclosureGroup("Original \(title.lowercased())") {
                    Text(original)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var memoriesTab: some View {
        if let root = paths.memoryRoot {
            MemoriesExplorer(
                rootURL: root,
                model: memoriesModel,
                promptUuid: stub.uuid,
                isDaemonWatched: paths.memoryIsDaemonWatched
            )
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
        // Scope-memoized: panes on the same prompt share one actor for WRITE
        // SERIALIZATION only. The version argument seeds a fresh actor; an
        // existing actor's threading is authoritative and is never rewound
        // here (a stale cached snapshot must not clobber a peer's writes).
        let newSaver = scope.saver(forPrompt: prompt.uuid, version: prompt.version)
        saver = newSaver
        draftBox.saver = newSaver
        // Pane-local echo watermark: the highest version THIS pane has written
        // or synchronized to. The shared actor's watermark can't distinguish a
        // peer pane's edit from our own echo — this can.
        localWatermark = prompt.version
        await loadAvailableKbites()
        let s = currentState()
        lastSaved = s
        history.load(promptKey: promptKey, current: s)
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
        let storagePath = stub.ckfsRelativeStoragePath
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
            }
            p.promptFolder = CkfsPathResolver.promptFolder(
                ckfsRoot: root, storagePath: storagePath)
            let memory = CkfsPathResolver.memoryRoot(
                ckfsRoot: root, storagePath: storagePath, artifacts: artifacts)
            p.memoryRoot = memory.root
            p.memoryIsDaemonWatched = memory.isDaemonWatched
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
        case .saved(let version):
            localWatermark = max(localWatermark, version)
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
    // version against the PANE-LOCAL watermark separates this pane's own echo
    // from an edit made anywhere else — including a peer pane sharing the same
    // save actor (whose shared watermark cannot make that distinction).
    // Adopt silently only when the buffer is clean.
    private func reconcileExternal() async {
        guard loaded, let saver,
              let fresh = store.promptDetails[stub.uuid]?.prompt else { return }
        guard fresh.version > localWatermark else { return }   // own echo — drop
        if currentState() == lastSaved {
            backstory = fresh.backstory
            goal = fresh.goal
            detail = fresh.detail
            lastSaved = currentState()
            localWatermark = fresh.version
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
        localWatermark = max(localWatermark, fresh.version)
        Task { await saver?.adoptVersion(fresh.version) }
    }

    // MARK: KBites

    // Every kbite the daemon knows (KBITE_LIST all:true), unioned with the
    // current selection so an already-registered kbite missing from the db
    // still renders (and can be deselected).
    private func loadAvailableKbites() async {
        let refs = (try? await GMCCDaemonService.shared.listKbites(
            scope: .prompt, ownerUuid: stub.uuid, all: true)) ?? []
        availableKbites = Set(refs.map(\.code)).union(selectedKbites).sorted()
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
