import SwiftUI
import GMCCDaemonKit

// MARK: - Root view
//
// File-explorer tree over the daemon's entity hierarchy: projects are folders,
// instances are folders nested inside them, sessions are leaf rows. The whole
// tree comes from CatalogStore's three Listing calls, refreshed on topology
// events (no polling); clicking a session opens the per-session editor window.
// Selection/expansion is purely local tree state.

struct ProjectsView: View {
    @State private var query: String = ""
    @State private var expanded: Set<String> = []

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
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog

    @Binding var query: String
    @Binding var expanded: Set<String>

    var body: some View {
        List {
            ForEach(visibleProjects, id: \.uuid) { project in
                ProjectFolderRow(project: project,
                                 query: query,
                                 expanded: $expanded,
                                 forceExpanded: forceExpanded)
            }
            if visibleProjects.isEmpty {
                emptyRow
            }
        }
        .listStyle(.sidebar)
        // Event-driven refresh; generation restarts the loop after reconnect.
        // Stream hoisted before the first refresh so an invalidation firing
        // during the initial fetch isn't lost.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .topology)
            await catalog.refresh()
            for await _ in stream {
                await catalog.refresh()
            }
        }
    }

    private var projects: [ProjectRow] { catalog.projects }

    // View-layer filter. With an active query, keep a project only if it matches
    // itself or has any matching instance/session (descendant match).
    private var visibleProjects: [ProjectRow] {
        let q = SearchQuery(query)
        guard q.isActive else { return projects }
        return projects.filter { projectHasMatch($0, q) }
    }

    // Every ancestor uuid of any match, so matching folders auto-open. A matching
    // instance opens its project; a matching session opens its instance + project.
    private var forceExpanded: Set<String> {
        let q = SearchQuery(query)
        guard q.isActive else { return [] }
        var out: Set<String> = []
        for project in projects {
            var projectShouldOpen = false
            for instance in catalog.instances(of: project) {
                let sessionMatch = catalog.sessions(of: instance).contains { $0.matches(q) }
                if instance.matches(q) || sessionMatch { projectShouldOpen = true }
                if sessionMatch { out.insert(instance.uuid) }
            }
            if projectShouldOpen { out.insert(project.uuid) }
        }
        return out
    }

    // A project is relevant when it matches, or any instance matches, or any
    // session under any instance matches.
    private func projectHasMatch(_ project: ProjectRow, _ q: SearchQuery) -> Bool {
        if project.matches(q) { return true }
        return catalog.instances(of: project).contains { instance in
            if instance.matches(q) { return true }
            return catalog.sessions(of: instance).contains { $0.matches(q) }
        }
    }

    private var emptyRow: some View {
        Text(emptyText)
            .foregroundStyle(.secondary)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
    }

    private var emptyText: String {
        if !query.isEmpty { return "No matches." }
        if daemon.health != .up { return "GMCC daemon unavailable." }
        if let error = catalog.lastError { return error }
        return "No projects in the GMCC database yet — start a session in a gmcc-enabled repo (gm context ensure)."
    }
}

// MARK: - Project folder (level 0)

private struct ProjectFolderRow: View {
    let project: ProjectRow
    let query: String
    @Binding var expanded: Set<String>
    let forceExpanded: Set<String>

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            InstanceLevel(project: project,
                          query: query,
                          expanded: $expanded,
                          forceExpanded: forceExpanded)
        } label: {
            FolderLabel(name: project.name, subtitle: project.code,
                        systemImage: "folder")
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(project.uuid) || forceExpanded.contains(project.uuid) },
            set: { open in
                if open { expanded.insert(project.uuid) } else { expanded.remove(project.uuid) }
            }
        )
    }
}

// Instances of a project — read straight from the catalog snapshot.
private struct InstanceLevel: View {
    @Environment(CatalogStore.self) private var catalog
    let project: ProjectRow
    let query: String
    @Binding var expanded: Set<String>
    let forceExpanded: Set<String>

    var body: some View {
        let instances = visibleInstances(catalog.instances(of: project))
        if instances.isEmpty {
            Text(query.isEmpty ? "No instances." : "No matching instances.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(instances, id: \.uuid) { instance in
                InstanceFolderRow(instance: instance,
                                  project: project,
                                  query: query,
                                  expanded: $expanded,
                                  forceExpanded: forceExpanded)
            }
        }
    }

    private func visibleInstances(_ instances: [InstanceRow]) -> [InstanceRow] {
        let q = SearchQuery(query)
        guard q.isActive else { return instances }
        // The whole project matched ⇒ show all its instances; otherwise keep
        // instances that match or have a matching session.
        if project.matches(q) { return instances }
        return instances.filter { instance in
            if instance.matches(q) { return true }
            return catalog.sessions(of: instance).contains { $0.matches(q) }
        }
    }
}

// MARK: - Instance folder (level 1)

private struct InstanceFolderRow: View {
    let instance: InstanceRow
    let project: ProjectRow
    let query: String
    @Binding var expanded: Set<String>
    let forceExpanded: Set<String>

    var body: some View {
        DisclosureGroup(isExpanded: expansionBinding) {
            SessionLevel(instance: instance,
                         project: project,
                         query: query)
        } label: {
            FolderLabel(name: instance.name, subtitle: instance.code,
                        systemImage: "folder")
        }
    }

    private var expansionBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(instance.uuid) || forceExpanded.contains(instance.uuid) },
            set: { open in
                if open { expanded.insert(instance.uuid) } else { expanded.remove(instance.uuid) }
            }
        )
    }
}

// Sessions of an instance — read straight from the catalog snapshot.
private struct SessionLevel: View {
    @Environment(CatalogStore.self) private var catalog
    let instance: InstanceRow
    let project: ProjectRow
    let query: String

    var body: some View {
        let sessions = visibleSessions(catalog.sessions(of: instance))
        if sessions.isEmpty {
            Text(query.isEmpty ? "No sessions." : "No matching sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(sessions, id: \.uuid) { session in
                SessionLeafRow(session: session, instance: instance)
            }
        }
    }

    private func visibleSessions(_ sessions: [SessionStub]) -> [SessionStub] {
        let q = SearchQuery(query)
        guard q.isActive else { return sessions }
        // If an ancestor (project/instance) matched, the whole subtree is relevant;
        // otherwise keep only sessions that match.
        if project.matches(q) || instance.matches(q) { return sessions }
        return sessions.filter { $0.matches(q) }
    }
}

// MARK: - Session leaf (level 2)

private struct SessionLeafRow: View {
    @Environment(WindowNav.self) private var nav
    let session: SessionStub
    let instance: InstanceRow

    var body: some View {
        Button {
            // Navigate this window to the session. A malformed uuid disables
            // the row rather than fabricating an identity for a dead screen.
            guard let sessionUUID = UUID(uuidString: session.uuid),
                  let instanceUUID = UUID(uuidString: instance.uuid) else { return }
            nav.go(.session(SessionWindowID(
                sessionUUID: sessionUUID,
                instanceUUID: instanceUUID,
                sessionName: session.name
            )))
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name).font(.body)
                    HStack(spacing: 6) {
                        // The code IS the session's identity (slugged branch,
                        // forward-only) — rendered verbatim; the raw branch is
                        // a wire fact only for the checked-out session.
                        Text(session.code)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
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
