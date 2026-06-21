import SwiftUI
import AppKit

// Per-session prompt-authoring screen. Left: a flat navigator of the session's
// prompts (driven by session_data.gmcc.yaml's prompts[] index). Right: a three-
// section code-style editor (backstory / goal / detail) over the selected prompt's
// initial.yaml, with autosave, SwiftData-backed undo/redo, per-section copy, and a
// toolbar "Run" button that exports the `/gm_bot {id}` resume command.

struct SessionPromptEditorView: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let windowID: SessionWindowID

    @State private var selectedID: Int?
    @State private var didDefaultSelect = false
    @State private var showCreatePrompt = false

    private var promptsDirURL: URL { windowID.promptsDirURL }
    private var sessionDirURL: URL { promptsDirURL.deletingLastPathComponent() }
    private var sessionDataURL: URL { sessionDirURL.appendingPathComponent("session_data.gmcc.yaml") }
    // .../instances/{instance}/sessions/{slug}/prompts  →  up to the instance dir.
    private var instanceDataURL: URL {
        sessionDirURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("instance_data.gmcc.yaml")
    }
    // …/instances/{instance}/sessions/{slug}  →  up to the project dir (drop {slug},
    // "sessions", {instance}, "instances") for the parent project_data.gmcc.yaml.
    private var projectDataURL: URL {
        sessionDirURL
            .deletingLastPathComponent().deletingLastPathComponent()   // → instance dir
            .deletingLastPathComponent().deletingLastPathComponent()   // → project dir
            .appendingPathComponent("project_data.gmcc.yaml")
    }

    private var session: GMCCSessionDataFile? { fs.sessionData[sessionDataURL] }
    // Newest first — "default newest" selection + natural authoring order.
    private var prompts: [GMCCPromptFilesEntry] {
        (session?.prompts ?? []).sorted { $0.promptID > $1.promptID }
    }
    private var selectedEntry: GMCCPromptFilesEntry? {
        prompts.first { $0.promptID == selectedID }
    }
    private var instanceName: String {
        fs.instanceData[windowID.instanceUUID]?.base.name ?? "—"
    }
    // The instance's on-disk checkout (instance_data's system_path).
    private var systemPath: String? {
        fs.instanceData[windowID.instanceUUID]?.systemPath
    }
    // RepName from the parent project_data (looked up via the instance's projectUUID).
    private var repositoryName: String? {
        guard let pid = fs.instanceData[windowID.instanceUUID]?.projectUUID else { return nil }
        return fs.projectData[pid]?.repositoryName
    }

    var body: some View {
        NavigationSplitView {
            PromptNavigator(
                sessionName: windowID.sessionName,
                instanceName: instanceName,
                instanceUUID: windowID.instanceUUID,
                repositoryName: repositoryName,
                systemPath: systemPath,
                prompts: prompts,
                selectedID: $selectedID
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .toolbar {
                ToolbarItem {
                    Button { showCreatePrompt = true } label: {
                        Label("New Prompt", systemImage: "plus")
                    }
                    .disabled(session == nil)
                    .help("Create a new prompt in this session")
                }
            }
        } detail: {
            if let entry = selectedEntry {
                PromptEditorPane(
                    entry: entry,
                    sessionDirURL: sessionDirURL,
                    sessionUUID: windowID.sessionUUID,
                    instanceUUID: windowID.instanceUUID
                )
                // Recreate the pane (fresh editor + history controller) per prompt.
                .id(entry.promptID)
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
            if let session {
                CreatePromptView(
                    sessionDirURL: sessionDirURL,
                    sessionRelPath: session.paths.relativePath,
                    sessionDataURL: sessionDataURL,
                    promptsDirURL: promptsDirURL,
                    nextID: (prompts.map(\.promptID).max() ?? 0) + 1,
                    preselectedKbites: session.kbite,
                    sessionBackstory: session.backstory
                )
            } else {
                Color.clear.onAppear { showCreatePrompt = false }
            }
        }
        .onChange(of: prompts) { _, new in
            // Default to newest once data arrives; recover if the selection vanishes.
            if let id = selectedID, !new.contains(where: { $0.promptID == id }) {
                selectedID = new.first?.promptID
            } else if !didDefaultSelect, selectedID == nil, let first = new.first {
                selectedID = first.promptID
                didDefaultSelect = true
            }
        }
        .task(id: windowID.sessionUUID) {
            while !Task.isCancelled {
                await fs.refreshSessionData(at: sessionDataURL)
                await fs.refreshInstanceData(uuid: windowID.instanceUUID, at: instanceDataURL)
                // Warm the parent project_data so RepName resolves in the header.
                if let pid = fs.instanceData[windowID.instanceUUID]?.projectUUID {
                    await fs.refreshProjectData(uuid: pid, at: projectDataURL)
                }
                if !didDefaultSelect, selectedID == nil, let first = prompts.first {
                    selectedID = first.promptID
                    didDefaultSelect = true
                }
                try? await Task.sleep(for: .seconds(1))
            }
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
    let prompts: [GMCCPromptFilesEntry]
    @Binding var selectedID: Int?

    var body: some View {
        List(selection: $selectedID) {
            Section {
                if prompts.isEmpty {
                    Text("No prompts yet. Create one with +.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prompts) { entry in
                        PromptNavRow(entry: entry).tag(entry.promptID)
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

private struct PromptNavRow: View {
    let entry: GMCCPromptFilesEntry
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body).lineLimit(1)
                Text("id \(entry.promptID)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            PromptStatusBadge(status: entry.status)
        }
        .padding(.vertical, 2)
    }
}

private struct PromptStatusBadge: View {
    let status: GMCCPromptStatus?
    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
    }
    private var label: String { status?.rawValue ?? "—" }
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
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let entry: GMCCPromptFilesEntry
    let sessionDirURL: URL
    let sessionUUID: UUID
    let instanceUUID: UUID

    enum Field: Hashable { case backstory, goal, detail }
    enum Tab: Hashable { case initial, clarified }

    @State private var backstory = ""
    @State private var goal = ""
    @State private var detail = ""
    @State private var loaded = false
    @State private var initialURL: URL?
    @State private var promptFolderURL: URL?
    @State private var kbitesLoaded: [String] = []
    @State private var kbiteContextSummary: String?
    @State private var clarified: GMCCClarifiedPromptFile?
    @State private var tab: Tab = .initial
    @State private var lastSaved = PromptEditHistory.EditState(backstory: "", goal: "", detail: "")
    @State private var history = PromptEditHistory()
    @State private var saveTask: Task<Void, Never>?
    @State private var selectedTier: BotTier?
    @State private var copiedField: Field?
    @State private var copiedKey: String?
    @FocusState private var focus: Field?

    private var promptKey: String { "\(sessionUUID.uuidString)/\(entry.promptID)" }

    // ckfs folder hierarchy, derived from the session dir
    // (.../projects/{P}/instances/{I}/sessions/{S}). The prompt folder is only
    // known after load (it depends on the data file's initial_prompt_path).
    private var sessionFolderURL: URL { sessionDirURL }
    private var instanceFolderURL: URL {
        sessionDirURL.deletingLastPathComponent().deletingLastPathComponent()   // drop {S}, drop "sessions"
    }
    private var projectFolderURL: URL {
        instanceFolderURL.deletingLastPathComponent().deletingLastPathComponent()   // drop {I}, drop "instances"
    }
    // The instance's *target repo* on disk (instance_data.gmcc.yaml's system_path)
    // — the actual implementation checkout, distinct from the ckfs instance folder.
    private var repoFolderURL: URL? {
        guard let p = fs.instanceData[instanceUUID]?.systemPath, !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    // Instance display name — used to name the per-instance iTerm Dynamic Profile.
    private var instanceName: String {
        fs.instanceData[instanceUUID]?.base.name ?? "—"
    }

    // The three initial fields are editable only while the prompt is a Draft;
    // once it's Clarifying/Clarified the initial prompt is frozen.
    private var editable: Bool { entry.status == .draft }
    private var clarifiedAvailable: Bool { clarified != nil }

    // Snapshot returned across the actor boundary by `load`.
    private struct Loaded {
        let folderURL: URL
        let initialURL: URL
        let initial: GMCCInitialPromptFile
        let clarified: GMCCClarifiedPromptFile?
    }

    var body: some View {
        Group {
            if loaded {
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    switch tab {
                    case .initial:   initialTab
                    case .clarified: clarifiedTab
                    }
                }
            } else {
                ProgressView().controlSize(.regular)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.name)
        .navigationSubtitle(entry.status?.rawValue ?? "")
        .toolbar {
            if tab == .initial && editable {
                ToolbarItemGroup {
                    Button { applyUndo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!history.canUndo)
                    Button { applyRedo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!history.canRedo)
                }
            }
            // iTerm: open a terminal rooted at the instance's target repo. Uses a
            // per-instance Dynamic Profile so spawned windows/tabs inherit the repo dir.
            ToolbarItemGroup {
                Button { openInITerm(repoFolderURL) } label: {
                    Label("Open in iTerm", systemImage: "terminal")
                }
                .disabled(repoFolderURL == nil)
                .help("Open an iTerm2 window in the instance's target repo (window cwd = repo, via a per-instance dynamic profile)")
            }
            ToolbarItemGroup {
                Button { openInVSCode(repoFolderURL) } label: {
                    Label("Open Repo", systemImage: "hammer")
                }
                .disabled(repoFolderURL == nil)
                .help("Open the instance's target repo (implementation checkout) in VS Code")
                Button { openInVSCode(projectFolderURL) } label: {
                    Label("Open Project", systemImage: "folder")
                }
                .help("Open the project folder in VS Code")
                Button { openInVSCode(instanceFolderURL) } label: {
                    Label("Open Instance", systemImage: "internaldrive")
                }
                .help("Open the instance folder in VS Code")
                Button { openInVSCode(sessionFolderURL) } label: {
                    Label("Open Session", systemImage: "arrow.triangle.branch")
                }
                .help("Open the session folder in VS Code")
                Button { openInVSCode(promptFolderURL) } label: {
                    Label("Open Prompt", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .disabled(promptFolderURL == nil)
                .help("Open the prompt folder in VS Code")
            }
            // A connected cluster of the bot fidelity tiers. Each button copies
            // that tier's resume command to the clipboard and stays highlighted
            // as the last-clicked tier.
            ToolbarItem(placement: .primaryAction) {
                tierCluster
            }
        }
        // Key on the whole entry so a live status change (Draft→Clarifying→Clarified)
        // reloads (refetches the clarified file, re-freezes the initial fields).
        .task(id: entry) { await load() }
        .onChange(of: focus) { old, new in
            // Flush + record when leaving a field (only meaningful while editable).
            if editable, old != nil, old != new { flush(record: true) }
        }
        .onDisappear {
            saveTask?.cancel()
            // Synchronous on the close/switch path: a detached write can be
            // abandoned if the app terminates before it runs (e.g. Cmd+Q while
            // focused). writeInitialPromptFile is nonisolated + fast.
            flush(record: true, sync: true)
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                Text("Initial").tag(Tab.initial)
                if clarifiedAvailable { Text("Clarified").tag(Tab.clarified) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()
            if tab == .initial && !editable {
                Label("Read-only", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var initialTab: some View {
        ScrollView {
            VStack(spacing: 16) {
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

    @ViewBuilder
    private var clarifiedTab: some View {
        if let c = clarified {
            ScrollView {
                VStack(spacing: 16) {
                    if !c.backstory.isEmpty { readOnlyCard("Backstory", c.backstory) }
                    readOnlyCard("Refined Goal", c.refinedGoal)
                    readOnlyCard("Refined Detail", c.refinedDetail)
                    qaCard("Goal Clarifications", c.goalClarifications)
                    qaCard("Detail Clarifications", c.detailClarifications)
                    if !c.constraints.isEmpty { bulletsCard("Constraints", c.constraints) }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("No Clarified Prompt", systemImage: "questionmark.circle",
                                   description: Text("This prompt has not been clarified yet."))
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
                TextEditor(text: text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: minHeight)
                    .background(.black.opacity(0.04), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                    .focused($focus, equals: field)
                    .onChange(of: text.wrappedValue) { _, _ in scheduleSave() }
            } else {
                Text(text.wrappedValue.isEmpty ? "—" : text.wrappedValue)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                    .background(.black.opacity(0.04), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: Read-only cards (clarified)

    private func readOnlyCard(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            copyHeader(title, copyText: body)
            Text(body.isEmpty ? "—" : body)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func copyHeader(_ title: String, copyText: String) -> some View {
        HStack {
            Button { copy(key: title, text: copyText) } label: {
                HStack(spacing: 5) {
                    Text(title).font(.headline)
                    Image(systemName: copiedKey == title ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(copiedKey == title ? .green : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy \(title.lowercased())")
            Spacer()
        }
    }

    @ViewBuilder
    private func qaCard(_ title: String, _ items: [GMCCPromptClarification]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let r = item.rating {
                                Text("\(r)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.blue.opacity(0.18), in: .capsule)
                                    .foregroundStyle(.blue)
                            }
                            Text(item.q).font(.subheadline.weight(.semibold))
                                .textSelection(.enabled)
                        }
                        Text(item.a).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.black.opacity(0.04), in: .rect(cornerRadius: 8))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private func bulletsCard(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    Text(s).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    // MARK: Load / save

    private func load() async {
        // Persist any pending edits before reloading from disk — handles a live
        // status transition that swaps `entry` without recreating the pane.
        flush(record: true, sync: true)
        loaded = false
        let dataURL = sessionDirURL.appendingPathComponent(entry.path)
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let data = try? GMCCRuntimeDecoder.decodePromptData(at: dataURL) else { return nil }
            let folder = dataURL.deletingLastPathComponent()
            let iURL = folder.appendingPathComponent(data.initialPromptPath)
            guard let initial = try? GMCCRuntimeDecoder.decodeInitialPrompt(at: iURL) else { return nil }
            var clar: GMCCClarifiedPromptFile?
            if !data.clarifiedPromptPath.isEmpty {
                let cURL = folder.appendingPathComponent(data.clarifiedPromptPath)
                clar = try? GMCCRuntimeDecoder.decodeClarifiedPrompt(at: cURL)
            }
            return Loaded(folderURL: folder, initialURL: iURL, initial: initial, clarified: clar)
        }.value

        guard let r = result else { return }
        backstory = r.initial.backstory
        goal = r.initial.goal
        detail = r.initial.detail
        kbitesLoaded = r.initial.kbitesLoaded
        kbiteContextSummary = r.initial.kbiteContextSummary
        initialURL = r.initialURL
        promptFolderURL = r.folderURL
        clarified = r.clarified
        let s = currentState()
        lastSaved = s
        history.load(promptKey: promptKey, current: s)
        // Default to the clarified tab once it exists; otherwise the initial tab.
        tab = clarifiedAvailable ? .clarified : .initial
        loaded = true
    }

    private func openInVSCode(_ url: URL?) {
        guard let url else { return }
        VSCode.open(url)
    }

    private func openInITerm(_ url: URL?) {
        guard let url else { return }
        ITerm.open(dir: url, instanceUUID: instanceUUID, instanceName: instanceName)
    }

    private func currentState() -> PromptEditHistory.EditState {
        .init(backstory: backstory, goal: goal, detail: detail)
    }

    // Debounced autosave (~5s after typing stops).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            flush(record: true)
        }
    }

    // Persist current fields to initial.yaml (if changed) and record a history
    // snapshot. `writeAtomicReplace` keeps the 1s read loop from seeing partial files.
    private func flush(record: Bool, sync: Bool = false) {
        guard loaded, let url = initialURL else { return }
        let s = currentState()
        if s == lastSaved {
            if record { history.record(s) }   // no-op if cursor already matches
            return
        }
        lastSaved = s
        if record { history.record(s) }
        writeToDisk(s, url: url, sync: sync)
    }

    private func writeToDisk(_ s: PromptEditHistory.EditState, url: URL, sync: Bool = false) {
        let kb = kbitesLoaded, summary = kbiteContextSummary
        let write = {
            try? GMCCRuntimeEncoder.writeInitialPromptFile(
                at: url, backstory: s.backstory, goal: s.goal, detail: s.detail,
                kbitesLoaded: kb, kbiteContextSummary: summary
            )
        }
        if sync {
            write()   // inline on the calling (main) thread — survives app termination
        } else {
            Task.detached(priority: .userInitiated) { write() }
        }
    }

    // MARK: Undo / redo

    private func applyUndo() {
        saveTask?.cancel()
        guard let s = history.undo() else { return }
        apply(s)
    }

    private func applyRedo() {
        saveTask?.cancel()
        guard let s = history.redo() else { return }
        apply(s)
    }

    // Apply a history state to the fields + disk WITHOUT recording a new snapshot.
    private func apply(_ s: PromptEditHistory.EditState) {
        backstory = s.backstory
        goal = s.goal
        detail = s.detail
        lastSaved = s
        if let url = initialURL { writeToDisk(s, url: url) }
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

    private func copy(key: String, text: String) {
        Clipboard.copy(text)
        copiedKey = key
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedKey == key { copiedKey = nil }
        }
    }

    // A connected cluster of bot-fidelity tier buttons (1/2/3-person icons).
    // Each button copies that tier's resume command (`/{command} {id}`) to the
    // clipboard and becomes the highlighted "last-clicked" tier. Rendered as a
    // ControlGroup so the toolbar draws it as one cohesive, borderless cluster
    // flush with the surrounding toolbar icons. Re-clicking the same tier
    // re-fires the copy (unlike a segmented Picker bound to a selection).
    private var tierCluster: some View {
        ControlGroup {
            ForEach(BotTier.allCases) { tier in
                let isSelected = selectedTier == tier
                Button { copyResume(tier) } label: {
                    Label(tier.command, systemImage: tierSymbol(tier, selected: isSelected))
                }
                .tint(isSelected ? .accentColor : nil)
                .help("Copy \(tier.command(for: entry.promptID)) to the clipboard")
            }
        } label: {
            Label("Resume Command", systemImage: "person.fill")
        }
    }

    // Filled symbol for the last-clicked tier so its highlight is unambiguous
    // even where the accent tint is subtle; unselected tiers use the outline
    // variant. (person / person.2 / person.3 + their .fill counterparts.)
    private func tierSymbol(_ tier: BotTier, selected: Bool) -> String {
        selected ? tier.symbol : tier.symbol.replacingOccurrences(of: ".fill", with: "")
    }

    private func copyResume(_ tier: BotTier) {
        Clipboard.copy(tier.command(for: entry.promptID))
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
