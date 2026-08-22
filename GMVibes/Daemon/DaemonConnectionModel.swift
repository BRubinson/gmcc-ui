import Foundation
import Observation
import GMCCDaemonKit

/// App-wide daemon liveness + the single event subscription.
///
/// Health comes from the probe (STATUS + PING with autostart off), never
/// inferred from the subscription alone — a quiet healthy stream is
/// indistinguishable from a hung one, so while up the event consumption is
/// raced against a 30s status watchdog (the app-wide liveness check that
/// replaced per-view confirming polls). The supervising loop probes, then
/// consumes events until the stream drops, then re-probes; a killed daemon
/// goes red within one iteration and stays red (nothing here autostarts).
/// DAEMON_START is unreceivable while down, so green is re-inferred from the
/// next successful probe.
@Observable @MainActor
final class DaemonConnectionModel {
    enum Health: Equatable {
        case unknown
        case notInstalled
        case down(reason: String, intentional: Bool)
        /// Daemon speaks a newer protocol than our linked kit — rebuild
        /// GMVibes / update the package. Starting the daemon can't fix it.
        case incompatible(daemonVersion: Int?)
        case starting
        case up
    }

    private(set) var health: Health = .unknown
    private(set) var status: StatusResponse?
    private(set) var ping: PingResponse?
    /// Bumped on every down→up transition and on a capped replay (resync barrier).
    private(set) var generation = 0

    let hub = InvalidationHub()

    /// Live session scopes register their prompt uuids so prompt-subject
    /// events route to the owning session only; unknown subjects fan out.
    /// Owner-token guarded: a retired scope's late unregister must not kill
    /// routing for a successor scope on the same session.
    private var sessionPrompts: [String: (owner: ObjectIdentifier, prompts: Set<String>)] = [:]

    private let service = GMCCDaemonService.shared
    private var runTask: Task<Void, Never>?
    private var probeInFlight = false
    /// Sticky across probe failures so an intentional `gm daemon stop` keeps
    /// reading "daemon stopped" instead of a raw socket error from the next
    /// failed probe.
    private var intentionalStop = false

    private static let cursorKey = "gmvibes.daemon.lastEventId"
    private static let cursorStampKey = "gmvibes.daemon.lastEventStamp"
    /// Replay is served on the daemon's single serial queue; a cursor older
    /// than this replays a backlog to learn what one resync refetch tells us.
    private static let cursorMaxAge: TimeInterval = 3600
    /// Stamp-guard: the cursor timestamp advances only when the id actually
    /// moved, so a quiet reconnect can't keep refreshing a dead cursor's age.
    private var lastPersistedCursor: Int64 = 0

    // App-lifetime singleton — the supervising task runs until process exit.
    // Weak capture so a discarded instance (SwiftUI can re-evaluate app @State)
    // doesn't leak a probe loop + socket forever.
    init(autorun: Bool = true) {
        if autorun {
            runTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.iterate()
                }
            }
        }
    }

    // MARK: - Session routing registry

    func registerSession(_ sessionUuid: String, promptUuids: Set<String>, owner: ObjectIdentifier) {
        let current = sessionPrompts[sessionUuid]
        if current?.owner != owner || current?.prompts != promptUuids {
            sessionPrompts[sessionUuid] = (owner, promptUuids)
        }
    }

    func unregisterSession(_ sessionUuid: String, ifOwnedBy owner: ObjectIdentifier) {
        if sessionPrompts[sessionUuid]?.owner == owner {
            sessionPrompts[sessionUuid] = nil
        }
    }

    private func owningSession(ofPrompt uuid: String) -> String? {
        sessionPrompts.first { $0.value.prompts.contains(uuid) }?.key
    }

    // MARK: - Supervising loop

    /// One loop turn: gate on installed, probe, and while up consume events
    /// raced against the 30s liveness watchdog. Backs off when the subscribe
    /// path fails fast (probe ok but SUBSCRIBE rejected) so a broken daemon
    /// isn't hammered at CPU speed.
    private var fastFailureBackoff: Duration = .seconds(1)

    private func iterate() async {
        guard GMCCDaemonService.isInstalled else {
            setHealth(.notInstalled)
            try? await Task.sleep(for: .seconds(5))
            return
        }
        await probe()
        guard health == .up else {
            try? await Task.sleep(for: .seconds(2))
            return
        }
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.consumeEvents() }
            group.addTask {
                // App-wide 30s liveness watchdog (replaces per-view confirming
                // polls): a wedged-but-connected daemon fails this probe and
                // goes red even though the stream never drops.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled { break }
                    await self.probe()
                }
            }
            await group.next()   // consumeEvents ended; the watchdog never returns
            group.cancelAll()
        }
        if ContinuousClock.now - started < .seconds(2) {
            try? await Task.sleep(for: fastFailureBackoff)
            fastFailureBackoff = min(fastFailureBackoff * 2, .seconds(10))
        } else {
            fastFailureBackoff = .seconds(1)
        }
    }

    /// Single-flight STATUS+PING probe. Publishes change-gated; bumps the
    /// resync generation only on a genuine down→up transition.
    func probe() async {
        if probeInFlight { return }
        probeInFlight = true
        defer { probeInFlight = false }
        do {
            let newStatus = try await service.status()
            let newPing = try await service.ping()
            if status != newStatus { status = newStatus }
            if ping != newPing { ping = newPing }
            intentionalStop = false
            let wasUp = health == .up
            setHealth(.up)
            if !wasUp {
                generation += 1
                hub.invalidateAll()
            }
        } catch let error as DaemonError {
            switch error {
            case .notInstalled:
                setHealth(.notInstalled)
            case .clientTooOld(let daemonVersion):
                setHealth(.incompatible(daemonVersion: daemonVersion))
            default:
                setHealth(.down(
                    reason: intentionalStop ? "Daemon stopped" : error.userMessage,
                    intentional: intentionalStop))
            }
        } catch {
            setHealth(.down(
                reason: intentionalStop ? "Daemon stopped" : String(describing: error),
                intentional: intentionalStop))
        }
    }

    /// Alias for the probe — refreshes status/ping/health (and, on a genuine
    /// down→up transition, fires the resync barrier).
    func refreshStatus() async {
        await probe()
    }

    func startDaemon() async {
        setHealth(.starting)
        intentionalStop = false
        do {
            _ = try await service.startDaemon()
            await probe()
        } catch let error as DaemonError {
            switch error {
            case .notInstalled:
                setHealth(.notInstalled)
            case .clientTooOld(let daemonVersion):
                setHealth(.incompatible(daemonVersion: daemonVersion))
            default:
                setHealth(.down(reason: error.userMessage, intentional: false))
            }
        } catch {
            setHealth(.down(reason: String(describing: error), intentional: false))
        }
    }

    // MARK: - Event consumption

    private func consumeEvents() async {
        // Cursor policy: bounded replay. Resume from the persisted cursor only
        // when it is fresh AND not ahead of the daemon's event log (a db
        // re-baseline restarts event ids at 1 — replaying above the log head
        // would silently match nothing forever). Otherwise subscribe live;
        // the up-transition's invalidateAll() already resynced surfaces.
        var sinceId: Int64? = nil
        let defaults = UserDefaults.standard
        if let stored = (defaults.object(forKey: Self.cursorKey) as? NSNumber)?.int64Value, stored > 0 {
            lastPersistedCursor = max(lastPersistedCursor, stored)
            let stamp = defaults.object(forKey: Self.cursorStampKey) as? Date ?? .distantPast
            let logHead = Int64(status?.tableCounts.first(where: { $0.name == "daemon_event" })?.count ?? 0)
            if Date().timeIntervalSince(stamp) < Self.cursorMaxAge, stored <= logHead {
                sinceId = stored
            }
        }

        // The subscription's autostart parameter DEFAULTS TO TRUE; left at the
        // default, the reconnect loop would resurrect a daemon the user killed
        // and the red indicator would silently self-heal.
        let subscription = DaemonEventSubscription(
            sinceId: sinceId,
            clientName: "gmvibes-events",
            autostart: false
        )
        var trailingStop = false
        var checkedReplayCap = false
        var eventsSincePersist = 0
        do {
            for try await event in subscription.events() {
                if Task.isCancelled { break }
                if !checkedReplayCap {
                    checkedReplayCap = true
                    if subscription.replayCapped {
                        // Events between the replayed prefix and the ack horizon
                        // were dropped by the cap — resync rather than trusting a
                        // gapped stream.
                        generation += 1
                        hub.invalidateAll()
                    }
                }
                // Only a DAEMON_STOP immediately before the stream ends means an
                // intentional shutdown; a replayed historical one must not stick.
                trailingStop = (event.kind == DaemonEventKind.daemonStop.rawValue)
                route(event)
                eventsSincePersist += 1
                if eventsSincePersist >= 50 {
                    persistCursor(subscription.lastEventId)
                    eventsSincePersist = 0
                }
            }
        } catch {
            // Stream drop — the supervising loop re-probes and reports health.
        }
        persistCursor(subscription.lastEventId)
        if trailingStop {
            intentionalStop = true
            setHealth(.down(reason: "Daemon stopped", intentional: true))
        } else if !Task.isCancelled && health == .up {
            setHealth(.down(reason: "Event stream ended", intentional: false))
        }
    }

    private func route(_ event: EventNotification) {
        guard let kind = DaemonEventKind(rawValue: event.kind) else {
            return // forward compat: unknown kinds bump nothing
        }
        switch kind {
        case .createProject, .createInstance, .createSession:
            hub.invalidate(.topology)
        case .updateSession:
            hub.invalidate(.topology)
            if let uuid = event.subjectUuid { hub.invalidate(.session(uuid)) }
        case .createPrompt:
            // No session uuid on the wire — fan out.
            hub.invalidateAllSessions()
        case .updatePrompt, .promptStatusChange, .addArtifact:
            // Subject IS the prompt uuid: route to the owning open session when
            // known (avoids a SESSION_GET storm across windows on every save);
            // fan out only for prompts no open window has registered.
            if let uuid = event.subjectUuid {
                hub.invalidate(.prompt(uuid))
                if let session = owningSession(ofPrompt: uuid) {
                    hub.invalidate(.session(session))
                } else {
                    hub.invalidateAllSessions()
                }
            } else {
                hub.invalidateAllSessions()
            }
        case .fileChange:
            hub.invalidate(.changes)
            hub.invalidateAllSessions()
        case .addKbite, .removeKbite:
            // At prompt scope the subject is the owner (prompt) uuid — refresh
            // the open editor's pills for terminal-side registry edits.
            if let uuid = event.subjectUuid { hub.invalidate(.prompt(uuid)) }
        case .kbiteDigest, .kbiteKeywordTag:
            // No subscriber surface: the KBites browser reads the filesystem
            // and its search hits the daemon on demand.
            break
        case .clarificationChange, .architectureChange, .promptMemoryChange:
            // No subscriber surface yet: the subjects are clarification /
            // architecture summary uuids and memory/ directories, none of
            // which any open window renders from the daemon.
            break
        case .configSet:
            // Config (ckfs roots) is read from the environment at boot, not
            // live from the daemon.
            break
        case .backup, .daemonStart:
            Task { await refreshStatus() }
        case .daemonStop:
            // No probe here: the stream is about to end and a racing probe
            // against a dying daemon would clobber the intentional flag.
            break
        }
    }

    // MARK: - Helpers

    private func persistCursor(_ id: Int64) {
        guard id > 0, id > lastPersistedCursor else { return }
        lastPersistedCursor = id
        let defaults = UserDefaults.standard
        defaults.set(id, forKey: Self.cursorKey)
        defaults.set(Date(), forKey: Self.cursorStampKey)
    }

    private func setHealth(_ new: Health) {
        if health != new { health = new }
    }

}
