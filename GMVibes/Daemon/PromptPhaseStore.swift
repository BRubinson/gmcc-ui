import Foundation
import Observation
import GMCCDaemonKit

/// Per-prompt read model over CLARIFY_GET + ARCH_GET + EXPLORE_GET +
/// REVIEW_GET — the app's only surface onto the db-native report subsystem
/// (read-only by clarified scope; every write verb stays bot/CLI-side).
///
/// Memoized on `SessionScope` beside the save actors so N panes on one prompt
/// cost one fetch. SUMMARY_ABSENT is a NORMAL state (the summary was never
/// opened) — it publishes `.absent`, never an error banner. Plain NOT_FOUND
/// means the prompt uuid itself is unknown — a real failure, never absence.
///
/// Live refresh needs no registration: as of wire v8 every phase-change
/// payload (CLARIFICATION/ARCHITECTURE/EXPLORATION/REVIEW_CHANGE) carries
/// prompt_uuid, so the connection model routes them to the `.prompt` domain
/// directly.
@Observable
@MainActor
final class PromptPhaseStore {
    enum Phase<T: Equatable>: Equatable {
        case idle
        /// No summary row exists (SUMMARY_ABSENT) — the summary was simply
        /// never opened.
        case absent
        case loaded(T)
        case failed(String)
    }

    let promptUuid: String
    private(set) var clarification: Phase<ClarifyGetResponse> = .idle
    private(set) var architecture: Phase<ArchGetResponse> = .idle
    private(set) var exploration: Phase<ExploreGetResponse> = .idle
    private(set) var review: Phase<ReviewGetResponse> = .idle
    private(set) var hasLoaded = false

    /// USER INTENT, not payload state: while true every refresh re-fetches
    /// that report with full:true. A pane's "show all findings" control sets
    /// it; it survives change events so an expanded pane isn't silently
    /// truncated by the next EXPLORATION_CHANGE — still exactly ONE full
    /// fetch per change generation, never a burst.
    private(set) var wantsFullExploration = false
    private(set) var wantsFullReview = false

    private let service = GMCCDaemonService.shared
    // Scope-aware single flight: a narrower in-flight pass cannot satisfy a
    // wider request — wider requests CHAIN after it (never race it), and the
    // slot is cleared by token so a finished predecessor can't clobber a
    // chained successor's bookkeeping.
    private var inFlight: (task: Task<Void, Never>, lifecyclePhases: Bool, reports: Bool, token: UUID)?

    init(promptUuid: String) {
        self.promptUuid = promptUuid
    }

    // MARK: - Derived

    var clarificationStatus: ClarificationStatus? {
        if case .loaded(let response) = clarification {
            return response.summary.clarificationStatus
        }
        return nil
    }

    var architectureStatus: ArchitectureStatus? {
        if case .loaded(let response) = architecture {
            return response.summary.architectureStatus
        }
        return nil
    }

    // MARK: - Refresh

    /// Coalesced single-flight (house idiom) — the pane's event loop and the
    /// section's first render must share one round trip set.
    ///
    /// `lifecyclePhases: false` skips CLARIFY_GET/ARCH_GET — draft prompts
    /// provably have neither (the two-guaranteed-absent round trips the old
    /// all-or-nothing gate existed to prevent). `reports: false` skips
    /// EXPLORE_GET/REVIEW_GET — legal ONLY for evidence-gated event-loop
    /// wakes on a draft whose freshly-listed stub shows no report summaries
    /// (an EXPLORATION_CHANGE re-lists the stub first, so the evidence is
    /// never stale); the first load and every status change fetch reports
    /// unconditionally because EXPLORE_OPEN is explicit-only and legally
    /// runs while the prompt is still draft.
    func refresh(lifecyclePhases: Bool = true, reports: Bool = true) async {
        // Coalesce only with a run at least as wide on both axes.
        if let running = inFlight,
           running.lifecyclePhases || !lifecyclePhases,
           running.reports || !reports {
            await running.task.value
            return
        }
        await chainedRun(lifecyclePhases: lifecyclePhases, reports: reports)
    }

    /// One-shot widen from a pane's stub-expansion control. Idempotent — a
    /// second call while already full issues no request. Runs THROUGH the
    /// single flight, chained after any in-flight pass: a narrow fetch that
    /// captured full:false before the flag flipped publishes first, and the
    /// full payload always publishes last — never clobbered by a stale
    /// window.
    func requestFullExploration() async {
        guard !wantsFullExploration else { return }
        wantsFullExploration = true
        await chainedRun(lifecyclePhases: false, reports: true)
    }

    func requestFullReview() async {
        guard !wantsFullReview else { return }
        wantsFullReview = true
        await chainedRun(lifecyclePhases: false, reports: true)
    }

    /// Start a new pass AFTER whatever is in flight (chain, never race — the
    /// prior task's writes land first, ours land last). Ownership of the
    /// `inFlight` slot is token-checked on exit: a predecessor resuming after
    /// a chained successor replaced the slot must not nil it out (that would
    /// let a third caller start a redundant racing pass).
    private func chainedRun(lifecyclePhases: Bool, reports: Bool) async {
        let prior = inFlight?.task
        let token = UUID()
        let task = Task {
            await prior?.value
            await self.performRefresh(lifecyclePhases: lifecyclePhases, reports: reports)
        }
        inFlight = (task, lifecyclePhases, reports, token)
        await task.value
        if inFlight?.token == token { inFlight = nil }
    }

    private func performRefresh(lifecyclePhases: Bool, reports: Bool) async {
        if lifecyclePhases {
            let newClarification = await fetchClarification()
            if clarification != newClarification { clarification = newClarification }
            let newArchitecture = await fetchArchitecture()
            if architecture != newArchitecture { architecture = newArchitecture }
        }
        if reports {
            // Sequential, never concurrent: the daemon has one serial queue.
            // Fullness is read HERE, not captured at schedule time, so a pass
            // chained behind a widen request fetches at the new intent.
            let newExploration = await fetchExploration(full: wantsFullExploration)
            if exploration != newExploration { exploration = newExploration }
            let newReview = await fetchReview(full: wantsFullReview)
            if review != newReview { review = newReview }
        }
        hasLoaded = true
    }

    private func fetchClarification() async -> Phase<ClarifyGetResponse> {
        do {
            return .loaded(try await service.clarification(promptUuid: promptUuid))
        } catch DaemonError.summaryAbsent {
            return .absent
        } catch let error as DaemonError {
            return .failed(error.userMessage)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func fetchArchitecture() async -> Phase<ArchGetResponse> {
        do {
            return .loaded(try await service.architecture(promptUuid: promptUuid))
        } catch DaemonError.summaryAbsent {
            return .absent
        } catch let error as DaemonError {
            return .failed(error.userMessage)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func fetchExploration(full: Bool) async -> Phase<ExploreGetResponse> {
        do {
            return .loaded(try await service.exploration(promptUuid: promptUuid, full: full))
        } catch DaemonError.summaryAbsent {
            return .absent
        } catch let error as DaemonError {
            return .failed(error.userMessage)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func fetchReview(full: Bool) async -> Phase<ReviewGetResponse> {
        do {
            return .loaded(try await service.review(promptUuid: promptUuid, full: full))
        } catch DaemonError.summaryAbsent {
            return .absent
        } catch let error as DaemonError {
            return .failed(error.userMessage)
        } catch {
            return .failed(String(describing: error))
        }
    }
}
