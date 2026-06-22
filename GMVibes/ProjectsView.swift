import SwiftUI

// MARK: - Root view
//
// File-explorer tree over the ckfs entity hierarchy: projects are folders,
// instances are folders nested inside them, sessions are leaf rows. Expanding a
// folder streams its children in via the existing 1s polled refresh; clicking a
// session opens the per-session editor window. There is NO push navigation — the
// old NavigationStack([AnyHashable]) + InstanceRoute push (which crashed on
// instance selection) is gone; selection/expansion is purely local tree state.

struct ProjectsView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(GMCCFileSystemEmulation.self) private var fs

    @State private var query: String = ""
    @State private var expanded: Set<UUID> = []

    var body: some View {
        // NavigationStack hosts only the title + searchable chrome (no path).
        NavigationStack {
            ProjectTreeView(query: $query, expanded: $expanded)
                .navigationTitle("Projects")
                .searchable(text: $query, placement: .toolbar,
                            prompt: "Search projects, instances & sessions")
        }
    }
}

// MARK: - Project tree (the whole screen)

private struct ProjectTreeView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(GMCCFileSystemEmulation.self) private var fs

    @Binding var query: String
    @Binding var expanded: Set<UUID>

    var body: some View {
        List {
            ForEach(visibleProjects, id: \.id) { project in
                ProjectRow(project: project,
                           query: query,
                           expanded: $expanded,
                           forceExpanded: forceExpanded)
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

    // View-layer filter. With an active query, keep a project only if it matches
    // itself or has any matching instance/session (descendant match).
    private var visibleProjects: [GMCCProjectEntry] {
        let q = SearchQuery(query)
        guard q.isActive else { return projects }
        return projects.filter { projectHasMatch($0, q) }
    }

    // Every ancestor uuid of any match, so matching folders auto-open. A matching
    // instance opens its project; a matching session opens its instance + project.
    private var forceExpanded: Set<UUID> {
        let q = SearchQuery(query)
        guard q.isActive else { return [] }
        var out: Set<UUID> = []
        for project in projects {
            let instances = fs.projectData[project.id]?.instances ?? []
            var projectShouldOpen = false
            for instance in instances {
                let sessions = fs.instanceData[instance.id]?.sessions ?? []
                let sessionMatch = sessions.contains { $0.matches(q) }
                if instance.matches(q) || sessionMatch { projectShouldOpen = true }
                if sessionMatch { out.insert(instance.id) }
            }
            if projectShouldOpen { out.insert(project.id) }
        }
        return out
    }

    // A project is relevant when it matches, or any instance matches, or any
    // session under any instance matches.
    private func projectHasMatch(_ project: GMCCProjectEntry, _ q: SearchQuery) -> Bool {
        if project.matches(q) { return true }
        let instances = fs.projectData[project.id]?.instances ?? []
        return instances.contains { instance in
            if instance.matches(q) { return true }
            let sessions = fs.instanceData[instance.id]?.sessions ?? []
            return sessions.contains { $0.matches(q) }
        }
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

// MARK: - Search prefetch
//
// One-shot prefetch when the query becomes non-empty: load every project's
// project_data (instances), then every instance's instance_data (sessions), so
// the filter + force-expand can see instance and session names of folders the
// user hasn't manually opened. Trees are small, so the deep walk is cheap.
private struct SearchPrefetchView: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let query: String

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: query.isEmpty) {
                guard !query.isEmpty, let idx = fs.projectIndex else { return }
                for project in idx.projects {
                    if fs.projectData[project.id] == nil {
                        await fs.refreshProjectData(uuid: project.id, at: project.projectDataURL)
                    }
                    let instances = fs.projectData[project.id]?.instances ?? []
                    for instance in instances where fs.instanceData[instance.id] == nil {
                        await fs.refreshInstanceData(uuid: instance.id, at: instance.instanceDataURL)
                    }
                }
            }
    }
}

// MARK: - Project folder (level 0)

private struct ProjectRow: View {
    let project: GMCCProjectEntry
    let query: String
    @Binding var expanded: Set<UUID>
    let forceExpanded: Set<UUID>

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            InstanceLevel(project: project,
                          query: query,
                          expanded: $expanded,
                          forceExpanded: forceExpanded)
        } label: {
            FolderLabel(name: project.base.name, subtitle: project.base.code,
                        systemImage: "folder")
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(project.id) || forceExpanded.contains(project.id) },
            set: { open in
                if open { expanded.insert(project.id) } else { expanded.remove(project.id) }
            }
        )
    }
}

// Instances of a project. The .task here only runs while the project folder is
// expanded (this body is built only then), so we poll project_data exactly while
// it's on screen — matching the app's "active page polls" convention.
private struct InstanceLevel: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let project: GMCCProjectEntry
    let query: String
    @Binding var expanded: Set<UUID>
    let forceExpanded: Set<UUID>

    var body: some View {
        Group {
            if let cached = fs.projectData[project.id] {
                let instances = visibleInstances(cached.instances)
                if instances.isEmpty {
                    Text(query.isEmpty ? "No instances." : "No matching instances.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(instances, id: \.id) { instance in
                        InstanceRow(instance: instance,
                                    project: project,
                                    query: query,
                                    expanded: $expanded,
                                    forceExpanded: forceExpanded)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: project.id) {
            while !Task.isCancelled {
                await fs.refreshProjectData(uuid: project.id, at: project.projectDataURL)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func visibleInstances(_ instances: [GMCCInstanceEntry]) -> [GMCCInstanceEntry] {
        let q = SearchQuery(query)
        // Newest-first by last-updated (ISO 8601 sorts chronologically as a string).
        let sorted = instances.sorted { $0.base.updatedTime > $1.base.updatedTime }
        guard q.isActive else { return sorted }
        // The whole project matched ⇒ show all its instances; otherwise keep
        // instances that match or have a matching session.
        if project.matches(q) { return sorted }
        return sorted.filter { instance in
            if instance.matches(q) { return true }
            let sessions = fs.instanceData[instance.id]?.sessions ?? []
            return sessions.contains { $0.matches(q) }
        }
    }
}

// MARK: - Instance folder (level 1)

private struct InstanceRow: View {
    let instance: GMCCInstanceEntry
    let project: GMCCProjectEntry
    let query: String
    @Binding var expanded: Set<UUID>
    let forceExpanded: Set<UUID>

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            SessionLevel(instance: instance,
                         project: project,
                         query: query)
        } label: {
            FolderLabel(name: instance.base.name, subtitle: instance.base.code,
                        systemImage: "folder")
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(instance.id) || forceExpanded.contains(instance.id) },
            set: { open in
                if open { expanded.insert(instance.id) } else { expanded.remove(instance.id) }
            }
        )
    }
}

// Sessions of an instance. Polls instance_data while the instance folder is open.
private struct SessionLevel: View {
    @Environment(GMCCFileSystemEmulation.self) private var fs
    let instance: GMCCInstanceEntry
    let project: GMCCProjectEntry
    let query: String

    var body: some View {
        Group {
            if let cached = fs.instanceData[instance.id] {
                let sessions = visibleSessions(cached.sessions)
                if sessions.isEmpty {
                    Text(query.isEmpty ? "No sessions." : "No matching sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions, id: \.id) { session in
                        SessionRow(session: session, instanceUUID: instance.id)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: instance.id) {
            while !Task.isCancelled {
                await fs.refreshInstanceData(uuid: instance.id, at: instance.instanceDataURL)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func visibleSessions(_ sessions: [GMCCSessionEntry]) -> [GMCCSessionEntry] {
        let q = SearchQuery(query)
        // Newest-first by last-updated (ISO 8601 sorts chronologically as a string).
        let sorted = sessions.sorted { $0.base.updatedTime > $1.base.updatedTime }
        guard q.isActive else { return sorted }
        // If an ancestor (project/instance) matched, the whole subtree is relevant;
        // otherwise keep only sessions that match.
        if project.matches(q) || instance.matches(q) { return sorted }
        return sorted.filter { $0.matches(q) }
    }
}

// MARK: - Session leaf (level 2)

private struct SessionRow: View {
    @Environment(\.openWindow) private var openWindow
    let session: GMCCSessionEntry
    let instanceUUID: UUID

    var body: some View {
        Button {
            // Opening a session spawns/focuses its own window (one per session UUID).
            openWindow(value: SessionWindowID(
                sessionUUID: session.id,
                instanceUUID: instanceUUID,
                sessionName: session.base.name,
                promptsDirURL: session.promptsDirectoryURL
            ))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.base.name).font(.body)
                    HStack(spacing: 6) {
                        if let branch = session.branch, !branch.isEmpty {
                            Text(branch).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(session.base.code).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared folder label

private struct FolderLabel: View {
    let name: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}
