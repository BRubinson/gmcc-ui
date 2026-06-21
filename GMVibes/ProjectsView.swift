import SwiftUI

// MARK: - Route values for the NavigationStack

struct InstanceRoute: Hashable {
    let projectUUID: UUID
    let instanceUUID: UUID
    let instanceDataURL: URL
    let instanceName: String
}

struct SessionRoute: Hashable {
    let instanceUUID: UUID
    let sessionUUID: UUID
    let promptsDirURL: URL
    let sessionName: String
}

// MARK: - Root view

struct ProjectsView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(GMCCFileSystemEmulation.self) private var fs

    @State private var path: [AnyHashable] = []
    @State private var query: String = ""
    @State private var expanded: Set<UUID> = []

    var body: some View {
        NavigationStack(path: pathBinding) {
            ProjectTreeView(query: $query, expanded: $expanded, path: pathBinding)
                .navigationTitle("Projects")
                .navigationDestination(for: InstanceRoute.self) { route in
                    InstanceDetailView(route: route)
                }
                .navigationDestination(for: SessionRoute.self) { route in
                    SessionPromptsView(route: route)
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search projects & instances")
        }
        // Selection-drift recovery — applied at the stack root so it works at any
        // depth (a vanished project pops session+instance+root drift in one pass).
        .onChange(of: fs.projectIndex) { _, _ in pruneStaleRoutes() }
        .onChange(of: fs.projectData)  { _, _ in pruneStaleRoutes() }
        .onChange(of: fs.instanceData) { _, _ in pruneStaleRoutes() }
    }

    private var pathBinding: Binding<[AnyHashable]> { $path }

    private func pruneStaleRoutes() {
        var truncated: [AnyHashable] = []
        for entry in path {
            if let r = entry as? InstanceRoute, !isInstanceRouteValid(r) { break }
            if let r = entry as? SessionRoute, !isSessionRouteValid(r) { break }
            truncated.append(entry)
        }
        if truncated.count != path.count {
            path = truncated
        }
    }

    private func isInstanceRouteValid(_ route: InstanceRoute) -> Bool {
        guard let idx = fs.projectIndex else { return true }
        guard idx.projects.contains(where: { $0.id == route.projectUUID }) else { return false }
        // If project_data isn't loaded yet, give it the benefit of the doubt.
        guard let pdata = fs.projectData[route.projectUUID] else { return true }
        return pdata.instances.contains(where: { $0.id == route.instanceUUID })
    }

    private func isSessionRouteValid(_ route: SessionRoute) -> Bool {
        guard let idata = fs.instanceData[route.instanceUUID] else { return true }
        return idata.sessions.contains(where: { $0.id == route.sessionUUID })
    }
}

// MARK: - Project tree (root screen)

private struct ProjectTreeView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(GMCCFileSystemEmulation.self) private var fs

    @Binding var query: String
    @Binding var expanded: Set<UUID>
    @Binding var path: [AnyHashable]

    var body: some View {
        List {
            ForEach(visibleProjects, id: \.id) { project in
                projectRow(project)
            }
            if visibleProjects.isEmpty {
                emptyRow
            }
        }
        .listStyle(.sidebar)
        .overlay(SearchPrefetchView(query: query).allowsHitTesting(false))
        .task(id: gmcc[.projects] ?? "") {
            await refreshLoop()
        }
    }

    private var projects: [GMCCProjectEntry] { fs.projectIndex?.projects ?? [] }

    // View-layer filter: when query is non-empty, hide projects that neither
    // themselves match nor have any matching instance. Force-expand projects
    // with a matching descendant.
    private var visibleProjects: [GMCCProjectEntry] {
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            if project.matches(query: query) { return true }
            let instances = fs.projectData[project.id]?.instances ?? []
            return instances.contains { $0.matches(query: query) }
        }
    }

    private var forceExpanded: Set<UUID> {
        guard !query.isEmpty else { return [] }
        var out: Set<UUID> = []
        for project in projects {
            let instances = fs.projectData[project.id]?.instances ?? []
            if instances.contains(where: { $0.matches(query: query) }) {
                out.insert(project.id)
            }
        }
        return out
    }

    @ViewBuilder
    private func projectRow(_ project: GMCCProjectEntry) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expanded.contains(project.id) || forceExpanded.contains(project.id) },
            set: { newValue in
                if newValue { expanded.insert(project.id) } else { expanded.remove(project.id) }
            }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            InstanceList(
                project: project,
                query: query,
                path: $path
            )
        } label: {
            ProjectLabel(project: project)
        }
        // No .task here — the 1s refresh lives inside InstanceList so it only
        // fires while the project is actually expanded (matches "1 file per page").
    }

    private var emptyRow: some View {
        Text(query.isEmpty ? "No projects found in $GMCC_PROJECTS." : "No matches.")
            .foregroundStyle(.secondary)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
    }

    private func refreshLoop() async {
        guard let rootPath = gmcc[.projects], !rootPath.isEmpty else { return }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        while !Task.isCancelled {
            await fs.refreshProjectIndex(rootDirectory: rootURL)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// One-shot prefetch of every project's project_data — required so the search
// filter can see instance names of projects the user hasn't manually expanded.
// Only kicks in when the query becomes non-empty.
private struct SearchPrefetchView: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let query: String

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: query.isEmpty) {
                guard !query.isEmpty, let idx = fs.projectIndex else { return }
                for project in idx.projects where fs.projectData[project.id] == nil {
                    await fs.refreshProjectData(uuid: project.id, at: project.projectDataURL)
                }
            }
    }
}

private struct ProjectLabel: View {
    let project: GMCCProjectEntry
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.base.name)
                    .font(.body)
                Text(project.base.code)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InstanceList: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let project: GMCCProjectEntry
    let query: String
    @Binding var path: [AnyHashable]

    var body: some View {
        Group {
            if let cached = fs.projectData[project.id] {
                let instances = cached.instances.filter { instance in
                    query.isEmpty
                        || project.matches(query: query)
                        || instance.matches(query: query)
                }
                if instances.isEmpty {
                    Text("No instances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(instances, id: \.id) { instance in
                        Button {
                            path.append(AnyHashable(InstanceRoute(
                                projectUUID: project.id,
                                instanceUUID: instance.id,
                                instanceDataURL: instance.instanceDataURL,
                                instanceName: instance.base.name
                            )))
                        } label: {
                            InstanceLabel(instance: instance)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        // 1s refresh — runs only while this disclosure is expanded (InstanceList
        // body is only built then). Matches "active page = 1 file at a time".
        .task(id: project.id) {
            while !Task.isCancelled {
                await fs.refreshProjectData(uuid: project.id, at: project.projectDataURL)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct InstanceLabel: View {
    let instance: GMCCInstanceEntry
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.base.name)
                    .font(.body)
                Text(instance.base.code)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Instance detail (push #1)

private struct InstanceDetailView: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let route: InstanceRoute

    @State private var showCreateSession = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let data = fs.instanceData[route.instanceUUID] {
                    InstanceHeaderCard(data: data,
                                       repositoryName: fs.projectData[route.projectUUID]?.repositoryName)
                    SessionListView(instance: data)
                } else {
                    ProgressView().controlSize(.regular)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(route.instanceName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreateSession = true
                } label: {
                    Label("New Session", systemImage: "plus")
                }
                .disabled(fs.instanceData[route.instanceUUID] == nil)
                .help("Create a new session (git branch)")
            }
        }
        .sheet(isPresented: $showCreateSession) {
            if let data = fs.instanceData[route.instanceUUID] {
                CreateSessionView(
                    instanceDirURL: route.instanceDataURL.deletingLastPathComponent(),
                    instanceRelPath: data.paths.relativePath,
                    instanceDataURL: route.instanceDataURL,
                    instanceUUID: route.instanceUUID,
                    projectUUID: route.projectUUID,
                    parentKbite: data.kbite
                )
            } else {
                // Defensive: data vanished between tap and render — never strand
                // the user on a blank sheet with no dismiss control.
                Color.clear.onAppear { showCreateSession = false }
            }
        }
        // Selection drift is handled centrally by ProjectsView.pruneStaleRoutes.
        .task(id: route.instanceUUID) {
            while !Task.isCancelled {
                await fs.refreshInstanceData(uuid: route.instanceUUID, at: route.instanceDataURL)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct InstanceHeaderCard: View {
    let data: GMCCInstanceDataFile
    let repositoryName: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(data.base.name).font(.title2.weight(.semibold))
                Spacer()
                InstancePathActions(systemPath: data.systemPath,
                                    instanceUUID: data.base.uuid,
                                    instanceName: data.base.name)
            }
            if !data.base.description.isEmpty {
                Text(data.base.description).font(.callout).foregroundStyle(.secondary)
            }
            metaRow("code",        data.base.code)
            if let repo = repositoryName, !repo.isEmpty { metaRow("repository", repo) }
            metaRow("uuid",        data.base.uuid.uuidString)
            if let sys = data.systemPath { metaRow("system_path", sys) }
            metaRow("absolute",    data.paths.absolutePath)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private func metaRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

private struct SessionListView: View {
    @Environment(\.openWindow) private var openWindow
    let instance: GMCCInstanceDataFile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions").font(.headline)
            if instance.sessions.isEmpty {
                Text("No sessions.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(instance.sessions, id: \.id) { session in
                    // Opening a session spawns its own window (one per session UUID),
                    // rather than pushing the in-stack prompt list.
                    Button {
                        openWindow(value: SessionWindowID(
                            sessionUUID: session.id,
                            instanceUUID: instance.id,
                            sessionName: session.base.name,
                            promptsDirURL: session.promptsDirectoryURL
                        ))
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

private struct SessionRow: View {
    let session: GMCCSessionEntry
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.base.name).font(.body)
                HStack(spacing: 6) {
                    if let branch = session.branch, !branch.isEmpty {
                        Text(branch).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(session.base.code).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Session prompts list (push #2)

private struct SessionPromptsView: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let route: SessionRoute

    @State private var showCreatePrompt = false

    // session_data.gmcc.yaml sits beside the prompts/ directory.
    private var sessionDirURL: URL { route.promptsDirURL.deletingLastPathComponent() }
    private var sessionDataURL: URL { sessionDirURL.appendingPathComponent("session_data.gmcc.yaml") }

    // Canonical next-prompt id = max of session_data prompts[].id + 1.
    private var nextPromptID: Int {
        let ids = fs.sessionData[sessionDataURL]?.prompts.map(\.promptID) ?? []
        return (ids.max() ?? 0) + 1
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                let stubs = fs.sessionPrompts[route.promptsDirURL] ?? []
                if stubs.isEmpty {
                    Text("No prompts in this session.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(stubs) { stub in
                        PromptRow(stub: stub)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(route.sessionName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreatePrompt = true
                } label: {
                    Label("New Prompt", systemImage: "plus")
                }
                .disabled(fs.sessionData[sessionDataURL] == nil)
                .help("Create a new prompt in this session")
            }
        }
        .sheet(isPresented: $showCreatePrompt) {
            if let session = fs.sessionData[sessionDataURL] {
                CreatePromptView(
                    sessionDirURL: sessionDirURL,
                    sessionRelPath: session.paths.relativePath,
                    sessionDataURL: sessionDataURL,
                    promptsDirURL: route.promptsDirURL,
                    nextID: nextPromptID,
                    preselectedKbites: session.kbite,
                    sessionBackstory: session.backstory
                )
            } else {
                Color.clear.onAppear { showCreatePrompt = false }
            }
        }
        .task(id: route) {
            while !Task.isCancelled {
                await fs.refreshSessionData(at: sessionDataURL)
                await fs.refreshSessionPrompts(at: route.promptsDirURL)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct PromptRow: View {
    let stub: PromptFileStub
    @State private var body_: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(stub.displayName).font(.headline)
                Spacer()
                Text(stub.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(body_.isEmpty ? "(loading…)" : body_)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        // Key on the full stub (which includes modifiedAt) so the body re-reads
        // when the file is rewritten on disk between 1s refreshes.
        .task(id: stub) {
            let text = await Task.detached(priority: .userInitiated) {
                GMCCFileSystemEmulation.readRawFile(at: stub.url)
            }.value
            body_ = text
        }
    }
}
