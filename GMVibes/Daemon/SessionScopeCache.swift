import Foundation
import Observation

/// One `SessionScope` per session uuid, shared by every window showing that
/// session and refcounted by the screens that hold it. This restores the
/// invariant the old one-window-per-session `WindowGroup` dedupe provided by
/// accident: the daemon-event routing registry and the per-prompt save actors
/// assume a single owner per session/prompt. With the dedupe gone, that owner
/// is the scope. (Draft boxes are deliberately NOT scope-owned: each pane
/// registers its own uniquely-keyed box, and the shared actor's version check
/// surfaces any cross-pane conflict.)
@MainActor
final class SessionScopeCache {
    static let shared = SessionScopeCache()

    private struct Entry {
        let scope: SessionScope
        var refs: Int
    }

    private var entries: [String: Entry] = [:]
    /// Retired scopes, newest last. Navigate-away-and-back revives the scope
    /// with its prompt cache intact instead of paying a fresh SESSION_GET +
    /// sequential prefetch.
    private var grace: [SessionScope] = []
    private let graceCap = 4

    /// Create-or-return WITHOUT refcounting and WITHOUT promoting a graced
    /// scope — safe to call from a View init (which SwiftUI may run
    /// repeatedly). Only `acquire` moves scopes between states.
    func scope(for sessionUuid: String) -> SessionScope {
        if let entry = entries[sessionUuid] { return entry.scope }
        if let graced = grace.first(where: { $0.sessionUuid == sessionUuid }) {
            return graced
        }
        let fresh = SessionScope(sessionUuid: sessionUuid)
        entries[sessionUuid] = Entry(scope: fresh, refs: 0)
        return fresh
    }

    func acquire(_ sessionUuid: String) {
        if entries[sessionUuid] != nil {
            entries[sessionUuid]?.refs += 1
            return
        }
        if let index = grace.firstIndex(where: { $0.sessionUuid == sessionUuid }) {
            let revived = grace.remove(at: index)
            entries[sessionUuid] = Entry(scope: revived, refs: 1)
            return
        }
        entries[sessionUuid] = Entry(scope: SessionScope(sessionUuid: sessionUuid), refs: 1)
    }

    func release(_ sessionUuid: String) {
        guard var entry = entries[sessionUuid], entry.refs > 0 else {
            assertionFailure("unbalanced SessionScopeCache.release(\(sessionUuid))")
            return
        }
        entry.refs -= 1
        if entry.refs == 0 {
            entries[sessionUuid] = nil
            entry.scope.retire()
            grace.append(entry.scope)
            while grace.count > graceCap { grace.removeFirst() }
        } else {
            entries[sessionUuid] = entry
        }
    }
}

/// Everything one session owns above the wire: the read store plus one save
/// actor PER PROMPT UUID (shared by every pane on that prompt so writes are
/// serialized through one version thread).
@MainActor
final class SessionScope {
    let sessionUuid: String
    let store: SessionStore

    private weak var daemon: DaemonConnectionModel?
    private var savers: [String: PromptSaveActor] = [:]

    init(sessionUuid: String) {
        self.sessionUuid = sessionUuid
        self.store = SessionStore(sessionUuid: sessionUuid)
    }

    /// Idempotent; keeps prompt-update events routing to this session. Owner-
    /// token guarded so a stale unregister (from a retired predecessor) can
    /// never kill a live successor's routing.
    func registerPrompts(_ promptUuids: Set<String>, daemon: DaemonConnectionModel) {
        self.daemon = daemon
        daemon.registerSession(sessionUuid, promptUuids: promptUuids, owner: ObjectIdentifier(self))
    }

    /// Called by the cache when the last holder releases the scope. Routing
    /// stops; panes own their draft boxes and flushed on their own teardown.
    func retire() {
        daemon?.unregisterSession(sessionUuid, ifOwnedBy: ObjectIdentifier(self))
    }

    /// Memoized per prompt uuid so concurrent panes thread one version. The
    /// version argument seeds a NEW actor only; an existing actor's threading
    /// is authoritative (and `adoptVersion` is monotonic besides).
    func saver(forPrompt promptUuid: String, version: Int64) -> PromptSaveActor {
        if let existing = savers[promptUuid] { return existing }
        let fresh = PromptSaveActor(promptUuid: promptUuid, version: version)
        savers[promptUuid] = fresh
        return fresh
    }
}
