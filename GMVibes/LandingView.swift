import SwiftUI
import AppKit
import GMCCDaemonKit

/// App landing page — ForgeApprentice Liquid Glass composition: brand header,
/// Recent Sessions strip (activity-ranked, checked-out ring), and a
/// project-organized instance search that navigates to the instance page.
/// The gate is daemon reachability: down/not-installed states replace the
/// launcher, and a healthy daemon with an empty db shows the migration state.
struct LandingView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    @Environment(CheckoutWatcher.self) private var checkout
    @Environment(WindowNav.self) private var nav

    @State private var recents = RecentsModel()
    @State private var showInactiveSessions = false

    var body: some View {
        Group {
            switch daemon.health {
            case .up:
                if let error = catalog.lastError, catalog.hasLoaded {
                    // A daemon-up failure (e.g. DB_ERROR after a schema
                    // re-baseline) must never masquerade as an empty app.
                    CatalogErrorState(error: error)
                } else if catalog.hasLoaded && catalog.projects.isEmpty {
                    MigrationGateState()
                } else {
                    launcher
                }
            case .unknown, .starting:
                ProgressView("Connecting to the GMCC daemon…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .notInstalled, .down, .incompatible:
                DaemonGateState()
            }
        }
        .navigationTitle("GM Vibes")
        .background(Backdrop())
        // Re-render reactively when daemon health changes mid-session.
        .animation(.default, value: daemon.health)
        // Event-driven refresh (house idiom: streams hoisted first). Topology
        // reloads the catalog; the .changes domain keeps recency live — file
        // changes advance session.updated_at WITHOUT bumping version, so
        // without this subscriber the strip would freeze until an unrelated
        // topology event. CheckoutWatcher is retargeted after each catalog
        // refresh so its DispatchSources track the instance set.
        .task(id: daemon.generation) {
            let topology = daemon.hub.stream(for: .topology)
            await refreshAll()
            for await _ in topology { await refreshAll() }
        }
        .task(id: daemon.generation) {
            let changes = daemon.hub.stream(for: .changes)
            for await _ in changes {
                // Debounce: .changes fires per FILE_CHANGE event and the
                // catalog refresh is three LIST calls on the fairness-free
                // serial queue — a bot implement burst must coalesce into one
                // refresh, not one per write. Events landing during the sleep
                // buffer (newest-1) into the next iteration.
                try? await Task.sleep(for: .milliseconds(750))
                await catalog.refresh()
                recents.refresh(catalog: catalog)
            }
        }
        .sheet(isPresented: $showInactiveSessions) {
            InactiveSessionsSheet()
        }
    }

    private func refreshAll() async {
        await catalog.refresh()
        recents.refresh(catalog: catalog)
        checkout.watch(
            instances: catalog.instancesByUuid.values.compactMap { row in
                row.absoluteFileSystemPath.isEmpty
                    ? nil
                    : (uuid: row.uuid, repoPath: row.absoluteFileSystemPath)
            }
        )
    }

    private var launcher: some View {
        ScrollView {
            VStack(spacing: 28) {
                // The env vars no longer gate browsing (the daemon does), but
                // the Memories tab and folder-open actions still need them.
                if !gmcc.isLoaded {
                    EnvWarningStrip()
                }

                BrandHeader()

                RecentSessionsStrip(
                    sessions: recents.recentSessions,
                    isCheckedOut: { checkout.isCheckedOut(sessionCode: $0.sessionCode, instanceUuid: $0.instanceUuid) },
                    onOpen: { nav.go(.session($0.windowID)) }
                )
                .frame(maxWidth: 720)

                InstanceSearchSection(
                    groups: recents.projectGroups,
                    onOpenInstance: { nav.go(.instance(instanceUuid: $0)) },
                    onBrowseInactive: { showInactiveSessions = true }
                )
                .frame(maxWidth: 720)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Recent sessions strip

private struct RecentSessionsStrip: View {
    let sessions: [RecentSessionCard]
    let isCheckedOut: (RecentSessionCard) -> Bool
    let onOpen: (RecentSessionCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Sessions")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(sessions) { session in
                            Button { onOpen(session) } label: {
                                RecentSessionCardView(session: session, active: isCheckedOut(session))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct RecentSessionCardView: View {
    let session: RecentSessionCard
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.sessionName)
                .font(.headline)
                .lineLimit(1)
            Text("\(session.projectName) · \(session.instanceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            HStack {
                Text(session.activity.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                // Bottom-right active dot; hidden (not removed) so state
                // changes never shift layout.
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .opacity(active ? 1 : 0)
            }
        }
        .padding(14)
        .frame(width: 180, height: 92, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .stateBorder(.green, active: active, cornerRadius: 16)
        .help(active ? "Checked out on this instance's repo" : session.sessionName)
    }
}

// MARK: - Project-organized instance search

private struct InstanceSearchSection: View {
    let groups: [ProjectInstanceGroup]
    let onOpenInstance: (String) -> Void
    let onBrowseInactive: () -> Void

    @State private var query = ""

    private var filtered: [ProjectInstanceGroup] {
        let q = SearchQuery(query)
        guard q.isActive else { return groups }
        return groups.compactMap { group in
            if q.matchesAny([group.projectName, group.repositoryName ?? ""]) { return group }
            let hits = group.instances.filter {
                q.matchesAny([$0.instanceName, $0.code, $0.systemPath ?? ""])
            }
            guard !hits.isEmpty else { return nil }
            return ProjectInstanceGroup(
                projectUuid: group.projectUuid,
                projectName: group.projectName,
                repositoryName: group.repositoryName,
                instances: hits
            )
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                CapsuleSearchField(prompt: "Search instances by project, name, or path", text: $query)
                Button(action: onBrowseInactive) {
                    Label("Inactive Sessions", systemImage: "archivebox")
                }
                .buttonStyle(.glass)
                .help("Browse non-active sessions across all instances")
            }

            if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No instances" : "No matches",
                    systemImage: query.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(query.isEmpty
                        ? "The daemon catalog has no instances yet."
                        : "No instance matches “\(query)”.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 16) {
                    ForEach(filtered) { group in
                        ProjectGroupCard(group: group, onOpenInstance: onOpenInstance)
                    }
                }
            }
        }
    }
}

private struct ProjectGroupCard: View {
    let group: ProjectInstanceGroup
    let onOpenInstance: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.orange)
                Text(group.projectName)
                    .font(.headline)
                if let repo = group.repositoryName {
                    Text("·").foregroundStyle(.tertiary)
                    Text(repo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(group.instances) { instance in
                    Button { onOpenInstance(instance.instanceUuid) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "internaldrive")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(instance.instanceName)
                                .font(.subheadline.weight(.medium))
                            if let path = instance.systemPath {
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text("\(instance.sessionCount) session\(instance.sessionCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// MARK: - Gate states (daemon down / empty db)

private struct DaemonGateState: View {
    @Environment(DaemonConnectionModel.self) private var daemon

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(iconColor)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            switch daemon.health {
            case .notInstalled:
                CommandCopyRow(command: "cd ~/Dev/gmcc-marketplace && bash plugins/gmcc/scripts/build_daemon.sh")
                    .frame(maxWidth: 480)
            case .down:
                Button {
                    Task { await daemon.startDaemon() }
                } label: {
                    Label("Start daemon", systemImage: "play.fill")
                }
                .buttonStyle(.glass)
            default:
                EmptyView()
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        switch daemon.health {
        case .incompatible: return "arrow.triangle.2.circlepath"
        case .notInstalled: return "questionmark.folder"
        default: return "bolt.slash.fill"
        }
    }

    private var iconColor: Color {
        switch daemon.health {
        case .incompatible: return .orange
        case .notInstalled: return .gray
        default: return .red
        }
    }

    private var title: String {
        switch daemon.health {
        case .incompatible: return "Rebuild GMVibes"
        case .notInstalled: return "GMCC daemon not installed"
        default: return "GMCC daemon is down"
        }
    }

    private var message: String {
        switch daemon.health {
        case .incompatible(let version):
            return "The running daemon speaks protocol v\(version.map(String.init) ?? "?"), newer than this build of GMVibes. Rebuild the app against the updated daemon package."
        case .notInstalled:
            return "No daemon binary at ~/gmcc/bin/gmcc_daemon. Build and install it from the gmcc marketplace repo:"
        case .down(let reason, let intentional):
            return intentional ? "The daemon was stopped." : reason
        default:
            return ""
        }
    }
}

private struct MigrationGateState: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down")
                .font(.largeTitle)
                .foregroundStyle(.blue)
            Text("GMCC database is empty")
                .font(.title2.weight(.semibold))
            Text("The daemon is healthy but holds no projects yet. Import the legacy ckfs yamls from a gmcc marketplace session, then archive them:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            VStack(spacing: 10) {
                CommandCopyRow(command: "/gmcc:import_legacy_yaml_gmcc")
                CommandCopyRow(command: "/gmcc:archive_legacy_yaml_gmcc")
            }
            .frame(maxWidth: 480)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// A daemon-up catalog failure (DB_ERROR etc.) rendered loudly, with the
// documented schema-re-baseline recovery visible.
private struct CatalogErrorState: View {
    let error: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("GMCC database error")
                .font(.title2.weight(.semibold))
            Text(error)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("If this appeared after a daemon rebuild (\"no such column\"), the pre-trust recovery is: stop the daemon, delete ~/gmcc/gmcc.db*, and let the next call recreate the schema.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Thin warning when browsing works (daemon up) but the shell env is unset —
// Memories and folder-open actions degrade without it.
private struct EnvWarningStrip: View {
    @Environment(GMCCEnvironment.self) private var gmcc

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("The ckfs root couldn't be resolved from the daemon or a conventional location — memory files and folder-open actions are unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Re-scan") { gmcc.refresh() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}

struct CommandCopyRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
