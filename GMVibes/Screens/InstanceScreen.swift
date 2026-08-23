import SwiftUI
import GMCCDaemonKit

/// The instance page. Loads the checked-out ("active") session by default.
/// If the checked-out branch changes while a session is open, the page flags
/// it with a yellow banner but NEVER auto-switches — a button loads into the
/// new active session. When no session row matches the checked-out branch,
/// an explicit empty state offers the inactive-sessions browser.
struct InstanceScreen: View {
    let instanceUuid: String

    @Environment(DaemonConnectionModel.self) private var daemon
    @Environment(CatalogStore.self) private var catalog
    @Environment(CheckoutWatcher.self) private var checkout
    @Environment(WindowNav.self) private var nav

    @State private var loadedWindowID: SessionWindowID?
    @State private var didAutoLoad = false
    @State private var showInactive = false

    private var instance: InstanceRow? { catalog.instancesByUuid[instanceUuid] }

    /// The session row matching the checked-out branch, resolved daemon-side
    /// (INSTANCE_CURRENT_SESSION) — no client-side catalog scan.
    private var activeStub: SessionStub? {
        checkout.currentSession(instanceUuid: instanceUuid)
    }

    /// The loaded session is no longer the checked-out one.
    private var drifted: Bool {
        guard let loaded = loadedWindowID else { return false }
        return activeStub?.uuid != loaded.sessionUUID.wireString
    }

    var body: some View {
        VStack(spacing: 0) {
            // In-page identity strip: the hosted session screen declares its
            // own navigationTitle/subtitle, which would shadow any declared
            // here — so the instance identity lives in the page, not the bar.
            identityStrip
            if drifted {
                driftBanner
            }
            if let loaded = loadedWindowID {
                SessionPromptEditorView(windowID: loaded)
                    .id(loaded)
            } else {
                emptyState
                    .todoTrailingSlot()
                    .navigationTitle(instance?.name ?? "Instance")
            }
        }
        // House idiom: catalog stays fresh on topology invalidations.
        .task(id: daemon.generation) {
            let stream = daemon.hub.stream(for: .topology)
            if !catalog.hasLoaded { await catalog.refresh() }
            ensureWatchingAndAutoLoad()
            for await _ in stream {
                await catalog.refresh()
                ensureWatchingAndAutoLoad()
            }
        }
        // Auto-load once when checkout state arrives after the catalog.
        .onChange(of: checkout.stateByInstance[instanceUuid]) { _, _ in
            ensureWatchingAndAutoLoad()
        }
        .sheet(isPresented: $showInactive) {
            // Project-level scope (per the brief): all of THIS project's
            // instances, not just this one.
            InactiveSessionsSheet(projectUuid: instance?.projectUuid)
        }
    }

    private func ensureWatchingAndAutoLoad() {
        if let row = instance, !row.absoluteFileSystemPath.isEmpty {
            checkout.ensureWatching(
                instanceUuid: instanceUuid,
                repoPath: row.absoluteFileSystemPath
            )
        }
        // Default-load the active session ONCE; later drift only flags.
        if !didAutoLoad, loadedWindowID == nil, let stub = activeStub {
            loadActive(stub)
            didAutoLoad = true
        }
    }

    private func loadActive(_ stub: SessionStub) {
        guard let sessionUUID = UUID(uuidString: stub.uuid),
              let instanceUUID = UUID(uuidString: instanceUuid) else { return }
        loadedWindowID = SessionWindowID(
            sessionUUID: sessionUUID,
            instanceUUID: instanceUUID,
            sessionName: stub.name
        )
    }

    private var identityStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(instance?.name ?? "Instance")
                .font(.caption.weight(.semibold))
            if let path = instance?.absoluteFileSystemPath, !path.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35))
    }

    private var driftBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(activeStub.map { "The active session changed to “\($0.name)”." }
                ?? "The checked-out branch no longer matches an open session.")
                .font(.callout)
            Spacer()
            if let stub = activeStub {
                Button {
                    loadActive(stub)
                } label: {
                    Label("Load active session", systemImage: "arrow.uturn.right")
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No active session")
                .font(.title2.weight(.semibold))
            Text(noActiveMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button {
                showInactive = true
            } label: {
                Label("Browse inactive sessions", systemImage: "archivebox")
            }
            .buttonStyle(.glass)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop())
    }

    private var noActiveMessage: String {
        switch checkout.stateByInstance[instanceUuid] {
        case .some(let state) where state.headState == .branch:
            let display = state.currentSessionCode.map(CkfsPathResolver.unslugBranch) ?? "?"
            return "The checked-out branch “\(display)” has no matching session row on this instance."
        case .some(let state) where state.headState == .detached:
            return "This repo is on a detached HEAD — no branch is checked out."
        case .some:
            return "The instance's repo path is missing or unreadable."
        case .none:
            return "The checked-out branch hasn't been resolved yet (is the daemon running?)."
        }
    }
}
