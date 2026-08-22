import SwiftUI
import AppKit
import GMCCDaemonKit

/// App entry point — a CodeEdit-style launcher. Left column of action buttons, right
/// column of recent projects (each with its newest sessions), and a bottom brand bar.
/// The gate is daemon reachability: down/not-installed states replace the launcher,
/// and a healthy daemon with an empty db shows the guided migration state.
struct LandingView: View {
    @Environment(GMCCEnvironment.self) private var gmcc
    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    @Environment(\.openWindow) private var openWindow

    @State private var recents = RecentsModel()

    // Global session ordering for the whole landing surface — persisted raw so
    // the choice survives relaunch. Default: create time (per the prompt).
    @AppStorage("landing.sessionSort") private var sessionSortRaw: String = SessionSortKey.created.rawValue

    private var sortKey: SessionSortKey {
        SessionSortKey(rawValue: sessionSortRaw) ?? .created
    }

    var body: some View {
        VStack(spacing: 0) {
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
                case .notInstalled, .down, .incompatible:
                    DaemonGateState()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            BrandBar()
        }
        .frame(minWidth: 760, minHeight: 520)
        // Re-render reactively when daemon health changes mid-session.
        .animation(.default, value: daemon.health)
        // Event-driven refresh: refetch the catalog on topology invalidations;
        // generation restarts the loop after a reconnect resync. Stream hoisted
        // before the first refresh so nothing fired mid-load is lost.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .topology)
            await catalog.refresh()
            recents.refresh(catalog: catalog, gmcc: gmcc, sortKey: sortKey)
            for await _ in stream {
                await catalog.refresh()
                recents.refresh(catalog: catalog, gmcc: gmcc, sortKey: sortKey)
            }
        }
        // The sort toggle re-derives immediately (no daemon round-trip needed).
        .onChange(of: sessionSortRaw) {
            recents.refresh(catalog: catalog, gmcc: gmcc, sortKey: sortKey)
        }
    }

    private var launcher: some View {
        VStack(spacing: 0) {
            // The env vars no longer gate browsing (the daemon does), but the
            // Memories tab, kbite roots, and folder-open actions still need
            // them — warn instead of silently disabling those features.
            if !gmcc.isLoaded {
                EnvWarningStrip()
            }
            HStack(alignment: .top, spacing: 0) {
                actionColumn
                    .frame(width: 300)
                    .padding(20)

                Divider()

                RecentProjectsColumn(recents: recents.recents,
                                     sortKeyRaw: $sessionSortRaw) { windowID in
                    openWindow(value: windowID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    private var actionColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActionButton(title: "Open Yeet Viewer", systemImage: "doc.text.magnifyingglass") {
                openWindow(id: "yeet-viewer")
            }
            ActionButton(title: "Open KBites", systemImage: "lightbulb") {
                openWindow(id: "kbites")
            }
            ActionButton(title: "New Project", systemImage: "plus.square.on.square") { }
                .disabled(true)
            ActionButton(title: "Open Projects", systemImage: "folder") {
                openWindow(id: "projects")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Left column button

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 24)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Right column: recent projects

private struct RecentProjectsColumn: View {
    let recents: [RecentProject]
    @Binding var sortKeyRaw: String
    let openSession: (SessionWindowID) -> Void

    private var sortKey: SessionSortKey {
        SessionSortKey(rawValue: sortKeyRaw) ?? .created
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Projects")
                    .font(.title3.weight(.semibold))
                Spacer()
                Picker("Sort by", selection: $sortKeyRaw) {
                    ForEach(SessionSortKey.allCases, id: \.rawValue) { key in
                        Text(key.label).tag(key.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if recents.isEmpty {
                Text("No recent projects with sessions.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    GlassEffectContainer(spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(recents) { recent in
                                RecentProjectCard(recent: recent,
                                                  sortKey: sortKey,
                                                  openSession: openSession)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct RecentProjectCard: View {
    let recent: RecentProject
    let sortKey: SessionSortKey
    let openSession: (SessionWindowID) -> Void

    // Daemon-backed per-project search: the query is debounced into a
    // CATALOG_SEARCH scoped to this project's uuid; while active, the daemon's
    // results replace the RecentsModel-derived listing (which is capped to
    // nothing — all sessions — but the daemon is still the matching authority).
    @State private var query = ""
    @State private var results: CatalogSearchResponse?
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(recent.name)
                    .font(.headline)
                Spacer()
                searchField
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(recent.instances) { instance in
                    InstanceSection(instance: instance, openSession: openSession)
                }
            } else {
                searchResults
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                results = nil
                searchError = nil
                searching = false
                return
            }
            searching = true
            defer { searching = false }
            // Debounce: a retype cancels this task before the call fires.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let response = try await GMCCDaemonService.shared.searchCatalog(
                    query: trimmed, projectUuid: recent.id.wireString)
                results = response
                searchError = nil
            } catch is CancellationError {
            } catch let error as DaemonError {
                results = nil
                searchError = Self.describe(error)
            } catch {
                results = nil
                searchError = String(describing: error)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .frame(width: 160)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .capsule)
    }

    @ViewBuilder
    private var searchResults: some View {
        if let searchError {
            Text(searchError)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let results {
            let instances = Self.groupedResults(results, recent: recent, sortKey: sortKey)
            if instances.isEmpty {
                Text("No matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(instances) { instance in
                    InstanceSection(instance: instance, openSession: openSession)
                }
            }
        } else if searching {
            ProgressView()
                .controlSize(.small)
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()

    /// Fold a CATALOG_SEARCH response into the card's RecentInstance shape so
    /// search results render with the exact same section UI (incl. pagination).
    private static func groupedResults(
        _ response: CatalogSearchResponse,
        recent: RecentProject,
        sortKey: SessionSortKey
    ) -> [RecentInstance] {
        let repositoryName = recent.instances.first?.repositoryName
        let sessionsByInstance = Dictionary(grouping: response.sessions, by: \.instanceUuid)
        var out: [RecentInstance] = []
        for row in response.instances {
            guard let instanceUUID = UUID(uuidString: row.uuid) else { continue }
            var sessions: [RecentSession] = []
            for stub in sessionsByInstance[row.uuid] ?? [] {
                guard let sessionUUID = UUID(uuidString: stub.uuid) else { continue }
                sessions.append(RecentSession(
                    windowID: SessionWindowID(
                        sessionUUID: sessionUUID,
                        instanceUUID: instanceUUID,
                        sessionName: stub.name
                    ),
                    name: stub.name,
                    code: stub.code,
                    branch: CkfsPathResolver.unslugBranch(stub.code),
                    created: isoFormatter.date(from: stub.createdAt) ?? .distantPast,
                    updated: isoFormatter.date(from: stub.updatedAt) ?? .distantPast
                ))
            }
            guard !sessions.isEmpty else { continue }
            sessions.sort { $0.date(for: sortKey) > $1.date(for: sortKey) }
            out.append(RecentInstance(
                id: instanceUUID,
                instanceName: row.name,
                code: row.code,
                systemPath: row.absoluteFileSystemPath.isEmpty ? nil : row.absoluteFileSystemPath,
                repositoryName: repositoryName,
                sessions: sessions
            ))
        }
        out.sort { ($0.sessions.first?.date(for: sortKey) ?? .distantPast) > ($1.sessions.first?.date(for: sortKey) ?? .distantPast) }
        return out
    }

    private static func describe(_ error: DaemonError) -> String {
        switch error {
        // An old daemon answers CATALOG_SEARCH with UNKNOWN_TYPE (or trips the
        // version gate) — that's "rebuild the daemon", not a search failure.
        case .server(let code, _) where code == "UNKNOWN_TYPE":
            return "Search requires an updated daemon."
        case .daemonTooOld, .clientTooOld:
            return "Search requires an updated daemon."
        case .unreachable, .notInstalled:
            return "GMCC daemon unavailable."
        case .server(_, let message):
            return message
        case .transport(let message):
            return message
        default:
            return String(describing: error)
        }
    }
}

/// One instance's title row (RepName · name · system path + path actions) followed by
/// its newest sessions.
private struct InstanceSection: View {
    let instance: RecentInstance
    let openSession: (SessionWindowID) -> Void

    // Sessions render 5 per page; the pager only appears when there is more
    // than one page. Page index resets whenever the session list changes.
    private static let pageSize = 5
    @State private var page = 0

    private var pageCount: Int {
        max(1, (instance.sessions.count + Self.pageSize - 1) / Self.pageSize)
    }

    private var visibleSessions: ArraySlice<RecentSession> {
        let clamped = min(page, pageCount - 1)
        let start = clamped * Self.pageSize
        let end = min(start + Self.pageSize, instance.sessions.count)
        return instance.sessions[start..<end]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                identityText
                Spacer(minLength: 8)
                InstancePathActions(systemPath: instance.systemPath,
                                    instanceUUID: instance.id,
                                    instanceName: instance.instanceName)
            }

            ForEach(visibleSessions) { session in
                Button {
                    openSession(session.windowID)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(session.name)
                            .font(.body)
                        if let branch = session.branch, !branch.isEmpty {
                            Text(branch)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "macwindow.badge.plus")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .padding(.leading, 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if pageCount > 1 {
                pagerRow
            }
        }
        .onChange(of: instance.sessions) { page = 0 }
    }

    private var pagerRow: some View {
        HStack(spacing: 8) {
            Button {
                page = max(0, page - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(page == 0)

            Text("\(min(page, pageCount - 1) + 1)/\(pageCount)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            Button {
                page = min(pageCount - 1, page + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(page >= pageCount - 1)

            Spacer()
        }
        .controlSize(.small)
        .padding(.leading, 18)
    }

    // RepName · instance name · system path — only the fields that are present.
    @ViewBuilder
    private var identityText: some View {
        HStack(spacing: 6) {
            if let repo = instance.repositoryName, !repo.isEmpty {
                Text(repo).font(.subheadline.weight(.medium))
                Text("·").foregroundStyle(.tertiary)
            }
            Text(instance.instanceName)
                .font(.subheadline.weight(.medium))
            if let path = instance.systemPath, !path.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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
// Memories, kbite roots, and folder-open actions degrade without it.
private struct EnvWarningStrip: View {
    @Environment(GMCCEnvironment.self) private var gmcc

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("$GMCC_CKFS_ROOT is not set in ~/.zshrc — memory files and folder-open actions are unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Re-scan") { gmcc.refresh() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }
}

private struct CommandCopyRow: View {
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

// MARK: - Bottom brand bar

private struct BrandBar: View {
    var body: some View {
        HStack(spacing: 10) {
            appIcon
                .frame(width: 22, height: 22)
            Text("GM Vibes")
                .font(.headline)
            Spacer()
            DaemonStatusIndicator()
            Text("v\(appVersion)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApplication.shared.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "mountain.2.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
