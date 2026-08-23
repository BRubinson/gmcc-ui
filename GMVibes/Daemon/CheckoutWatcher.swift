import Foundation
import Observation
import GMCCDaemonKit

/// Locates the real `.git` directory for a repo root, resolving worktree /
/// submodule indirection (`.git` may be a FILE reading `gitdir: <path>`).
/// The DispatchSource must open an fd on the RESOLVED directory — the kit's
/// `GitHead` does this indirection internally but exposes no gitdir URL, so
/// this stays app-side even though branch reading moved daemon-side.
enum GitDirLocator {
    static func gitDirURL(forRepoRoot root: String) -> URL {
        // isDirectory: true — a file-typed base drops its last component
        // during relative resolution, sending submodule gitdirs one level up.
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let dotGit = rootURL.appendingPathComponent(".git")
        if let marker = try? String(contentsOf: dotGit, encoding: .utf8),
           marker.hasPrefix("gitdir:") {
            let path = String(marker.dropFirst("gitdir:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: path, relativeTo: rootURL)
            return url.standardizedFileURL
        }
        return dotGit
    }
}

/// Per-instance checked-out-session cache. The push edge is unchanged — a
/// DispatchSource watches each instance's `.git` directory (there is no
/// branch-change event on the wire, so the file watcher is irreplaceable) —
/// but resolution moved daemon-side: a fire schedules a debounced
/// INSTANCE_CURRENT_SESSION, which returns the resolved session stub plus a
/// typed head state. `GitSlug`/`GitHeadFileReader` (the app's duplicate of the
/// daemon's derivation) are gone.
@Observable
@MainActor
final class CheckoutWatcher {
    /// Mirrors the wire's `head_state` string. `unavailable` (path gone / not
    /// a repo) is NOT `detached` (a real checkout with no branch) — the
    /// instance page says different things about them. Unknown wire values
    /// degrade to `.unavailable` rather than fabricating state.
    enum HeadState: Equatable, Sendable {
        case branch
        case detached
        case unavailable

        init(wire: String) {
            switch wire {
            case "branch": self = .branch
            case "detached": self = .detached
            default: self = .unavailable
            }
        }
    }

    struct CheckoutState: Equatable, Sendable {
        let headState: HeadState
        /// Slugged session code (forward-only rule, daemon-derived). Display
        /// via `CkfsPathResolver.unslugBranch` only — never compare unslugged.
        let currentSessionCode: String?
        let session: SessionStub?
    }

    /// Last-known state per instance uuid. Kept on RPC failure — checked-out
    /// state is a display signal, and a daemon restart must not blank every
    /// green ring. Absent entry = never resolved.
    private(set) var stateByInstance: [String: CheckoutState] = [:]

    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var watchedPaths: [String: String] = [:]   // instanceUuid → repo root (watcher armed)
    /// instanceUuid → repo root we last TRIED, regardless of open() outcome.
    /// Keyed separately from watchedPaths so a failed open (missing volume,
    /// clone in progress) still suppresses re-resolution on every catalog
    /// refresh — watchedPaths only records successes so the watcher itself
    /// keeps retrying.
    private var attemptedPaths: [String: String] = [:]
    /// Per-instance trailing coalesce: a `git checkout` writes `.git` several
    /// times, and each fire is now a round trip on the fairness-free serial
    /// queue — the burst must collapse to ONE resolve.
    private var resolveTasks: [String: Task<Void, Never>] = [:]

    private let service = GMCCDaemonService.shared

    // MARK: - Reads

    /// Is this session the checked-out one on its instance?
    /// `session.code` IS the slugged branch; the daemon's code is authoritative.
    func isCheckedOut(sessionCode: String, instanceUuid: String) -> Bool {
        stateByInstance[instanceUuid]?.currentSessionCode == sessionCode
    }

    /// The slugged code of the checked-out branch on an instance, or nil.
    func checkedOutCode(instanceUuid: String) -> String? {
        stateByInstance[instanceUuid]?.currentSessionCode
    }

    /// The resolved session row for the checked-out branch, or nil (detached,
    /// unavailable, or no matching session row).
    func currentSession(instanceUuid: String) -> SessionStub? {
        stateByInstance[instanceUuid]?.session
    }

    // MARK: - Watch management

    /// (Re)target the watcher set. Instances whose repo path vanished are
    /// dropped. Resolution fires only for NEW/changed instances — this is
    /// called after every catalog refresh and must not burst N RPCs.
    func watch(instances: [(uuid: String, repoPath: String)]) {
        let wanted = Dictionary(instances.map { ($0.uuid, $0.repoPath) },
                                uniquingKeysWith: { first, _ in first })

        // Iterate attemptedPaths, not watchedPaths: an instance whose open()
        // failed still has resolve state to clear when it leaves the catalog.
        for uuid in attemptedPaths.keys where wanted[uuid] == nil {
            dropWatcher(instanceUuid: uuid)
        }

        for (uuid, path) in wanted {
            ensureWatching(instanceUuid: uuid, repoPath: path)
        }
    }

    /// Add one instance to the watch set without dropping the others.
    /// A failed `open()` is NOT recorded, so a repo that appears later (clone
    /// in progress, unmounted volume) gets retried on the next call.
    func ensureWatching(instanceUuid: String, repoPath: String) {
        let isNewAttempt = attemptedPaths[instanceUuid] != repoPath
        attemptedPaths[instanceUuid] = repoPath
        if watchedPaths[instanceUuid] != repoPath {
            watchers[instanceUuid]?.cancel()
            watchers[instanceUuid] = nil
            watchedPaths[instanceUuid] = nil
            if let watcher = makeWatcher(instanceUuid: instanceUuid, repoPath: repoPath) {
                watchers[instanceUuid] = watcher
                watchedPaths[instanceUuid] = repoPath
            }
        }
        // Resolve when the instance is new/changed or has never resolved
        // successfully — NOT unconditionally (see watch(instances:)). A
        // failed open() no longer counts as "new" forever: attemptedPaths
        // records the try, so a bot's .changes-driven catalog refreshes can't
        // re-fire this RPC every 750ms for an unmounted repo.
        if isNewAttempt || stateByInstance[instanceUuid] == nil {
            scheduleResolve(instanceUuid: instanceUuid)
        }
    }

    private func dropWatcher(instanceUuid: String) {
        watchers[instanceUuid]?.cancel()
        watchers[instanceUuid] = nil
        watchedPaths[instanceUuid] = nil
        attemptedPaths[instanceUuid] = nil
        resolveTasks[instanceUuid]?.cancel()
        resolveTasks[instanceUuid] = nil
        if stateByInstance[instanceUuid] != nil {
            stateByInstance[instanceUuid] = nil
        }
    }

    // MARK: - Resolution (daemon-side)

    private func scheduleResolve(instanceUuid: String) {
        resolveTasks[instanceUuid]?.cancel()
        // The slot is NOT cleared from inside the task: a task past its sleep
        // can't be stopped, and clearing unconditionally after the RPC would
        // erase a SUCCESSOR's registration (letting a third fire run
        // concurrently and a superseded response publish stale state). The
        // entry is overwritten by the next schedule and cleared by
        // dropWatcher; a completed task's handle is inert.
        resolveTasks[instanceUuid] = Task { [weak self] in
            // Coalesce git's multi-write checkout burst into one RPC.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.resolve(instanceUuid: instanceUuid)
        }
    }

    private func resolve(instanceUuid: String) async {
        do {
            let response = try await service.instanceCurrentSession(instanceUuid: instanceUuid)
            // Superseded mid-RPC (a newer fire cancelled us) or dropped —
            // never publish a stale response over a newer one.
            guard !Task.isCancelled else { return }
            let new = CheckoutState(
                headState: HeadState(wire: response.headState),
                currentSessionCode: response.currentSessionCode,
                session: response.session
            )
            if stateByInstance[instanceUuid] != new {
                stateByInstance[instanceUuid] = new
            }
        } catch {
            // Keep the last known state — a down daemon must not clear the
            // checked-out ring. The next watcher fire (or a new-instance
            // ensureWatching) retries.
        }
    }

    private func makeWatcher(instanceUuid: String, repoPath: String) -> DispatchSourceFileSystemObject? {
        let gitDir = GitDirLocator.gitDirURL(forRepoRoot: repoPath)
        let fd = open(gitDir.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = self.watchers[instanceUuid]?.data ?? []
            if mask.contains(.delete) || mask.contains(.rename) {
                // The watched inode was replaced (re-clone, worktree remove) —
                // the source is dead. Drop and re-arm against the new .git.
                self.watchers[instanceUuid]?.cancel()
                self.watchers[instanceUuid] = nil
                self.watchedPaths[instanceUuid] = nil
                self.ensureWatching(instanceUuid: instanceUuid, repoPath: repoPath)
            } else {
                self.scheduleResolve(instanceUuid: instanceUuid)
            }
        }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        return watcher
    }
}
