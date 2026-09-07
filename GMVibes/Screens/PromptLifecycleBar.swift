import SwiftUI
import GMCCDaemonKit

/// The lifecycle affordance: a six-state rail plus exactly TWO controls —
/// Mark Done (enabled only where `PromptStatus.allowedNext` contains `.done`,
/// i.e. implementing/reviewing; disabled elsewhere with the edge reason) and
/// Back to Draft (always disabled: the daemon has no backward status edge —
/// a pending GM feature). The forward edges moved bot-side; `allowedNext`
/// stays the authority, consulted only for `.done`. A daemon
/// `INVALID_TRANSITION` is a lost race — its reason string (preserved by
/// `DaemonError.invalidTransition(reason:)`) surfaces verbatim.
struct PromptLifecycleBar: View {
    let stub: PromptStub
    let phases: PromptPhaseStore
    let store: SessionStore

    @Environment(DaemonConnectionModel.self) private var daemon

    @State private var transitionError: String?
    @State private var inFlight = false

    private var status: PromptStatus? { PromptStatus(rawValue: stub.status) }

    /// Informational ONLY — never consulted by `gate(to:)` (the daemon does
    /// not couple prompt transitions to explore/review). Precedence mirrors
    /// the gate tiers: the LIVE phase store first (it refreshes on every
    /// EXPLORATION_CHANGE/REVIEW_CHANGE), then PROMPT_LIST's with_reports
    /// precomputation. The live tier is load-bearing, not a nicety: report
    /// writes don't emit a session event, so `stub.reports` does not re-list
    /// on a report change and would show stale counts for the pane's life.
    private var reportBadges: [ReportBadgeItem] {
        var items: [ReportBadgeItem] = []
        if case .loaded(let response) = phases.exploration {
            items += ReportBadgeItem.exploration(response)
        } else if let reportStub = stub.reports?.exploration {
            items += ReportBadgeItem.exploration(reportStub)
        }
        if case .loaded(let response) = phases.review {
            items += ReportBadgeItem.review(response)
        } else if let reportStub = stub.reports?.review {
            items += ReportBadgeItem.review(reportStub)
        }
        return items
    }

    enum Gate {
        case open
        case blocked(reason: String, fix: String)
        /// The client can't adjudicate: neither the live phase store nor the
        /// PROMPT_LIST with_reports precomputation has an answer (occurs
        /// transiently on a `.idle` first render whose stub was listed
        /// without reports). Offer the button; the daemon rules and
        /// invalidTransition(reason:) surfaces the real message.
        case unknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                rail
                // Informational — on a narrow window the badges drop out
                // entirely rather than clipping the rail or the transition
                // buttons (the phaseCard headers still carry the counts).
                ViewThatFits(in: .horizontal) {
                    ReportBadgeCluster(items: reportBadges)
                    Color.clear.frame(width: 0, height: 0)
                }
                Spacer()
                if inFlight {
                    ProgressView().controlSize(.small)
                }
                if let status {
                    ForEach(nextStates(from: status), id: \.rawValue) { next in
                        transitionButton(to: next)
                    }
                }
            }
            if let transitionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(transitionError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { self.transitionError = nil }
                        .controlSize(.mini)
                        .buttonStyle(.borderless)
                }
            } else if let hint = blockedHint {
                // The gate reason is the only explanation for a dead primary
                // affordance — visible text, not just a hover tooltip.
                Label(hint, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
    }

    private var blockedHint: String? {
        // `.done` ONLY: Back to Draft is PERMANENTLY blocked, so consulting
        // every button (the old rule) would render its message forever and
        // mask the Done reason — the one explanation the user actually needs.
        // A done prompt renders no buttons and needs no hint at all.
        guard let status, status != .done else { return nil }
        if case .blocked(let reason, let fix) = gate(to: .done) {
            return "\(reason) — \(fix)."
        }
        return nil
    }

    // MARK: - Rail

    private var rail: some View {
        HStack(spacing: 4) {
            ForEach(PromptStatus.allCases, id: \.rawValue) { state in
                railPill(state)
            }
        }
    }

    @ViewBuilder
    private func railPill(_ state: PromptStatus) -> some View {
        let isCurrent = state == status
        Text(state.rawValue.capitalized)
            .font(.caption2.weight(isCurrent ? .semibold : .regular))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                isCurrent ? PromptStatusBadge.color(for: state).opacity(0.2) : .clear,
                in: .capsule
            )
            .foregroundStyle(isCurrent
                ? AnyShapeStyle(PromptStatusBadge.color(for: state))
                : AnyShapeStyle(.tertiary))
    }

    // MARK: - Transitions

    /// Exactly two controls: Done (edge-gated) and Back to Draft (pending a
    /// daemon-side backward edge — a GM feature request). Every other
    /// forward edge moved bot-side; `allowedNext` is still the authority —
    /// it is just consulted only for `.done` (in `gate(to:)`). A DONE prompt
    /// is terminal: no buttons and no hint — rendering the gated pair there
    /// would produce a self-contradicting "advance the prompt first" on a
    /// prompt that already finished.
    private func nextStates(from status: PromptStatus) -> [PromptStatus] {
        status == .done ? [] : [.done, .draft]
    }

    @ViewBuilder
    private func transitionButton(to next: PromptStatus) -> some View {
        let gate = gate(to: next)
        Button {
            Task { await transition(to: next) }
        } label: {
            Label(buttonTitle(for: next), systemImage: buttonIcon(for: next))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(inFlight || isBlocked(gate))
        .help(helpText(for: next, gate: gate))
    }

    private func isBlocked(_ gate: Gate) -> Bool {
        if case .blocked = gate { return true }
        return false
    }

    private func helpText(for next: PromptStatus, gate: Gate) -> String {
        if case .blocked(let reason, let fix) = gate {
            return "\(reason) — \(fix)"
        }
        return "Advance this prompt to \(next.rawValue)"
    }

    /// Mirrors Store.setPromptStatus's gate coupling: clarifying→architecting
    /// needs the clarification summary complete; architecting→implementing
    /// needs the architecture approved. Everything else is edge-only.
    ///
    /// Precedence (three-tier): the LIVE phase store when it has an answer
    /// (.loaded/.absent — it reflects a bot's just-finalized summary), then
    /// the PROMPT_LIST with_reports precomputation (.idle/.failed — the rail
    /// adjudicates before, or entirely without, the pane's fetch), then
    /// .unknown only when reports were never requested.
    private func gate(to next: PromptStatus) -> Gate {
        switch (status, next) {
        case (_, .done):
            // The EDGE SET rules here, not a phase gate: the daemon couples
            // no summary requirement to →done, but .done has exactly two
            // inbound edges (implementing, reviewing) — server-enforced.
            guard let status else { return .unknown }
            guard status.allowedNext.contains(.done) else {
                return .blocked(
                    reason: "Done is reachable from Implementing or Reviewing (this prompt is \(status.rawValue))",
                    fix: "advance the prompt with the bot first")
            }
            return .open
        case (_, .draft):
            // No backward edge exists daemon-side — filed as a GM feature
            // request; the button ships visible-but-disabled so the intent
            // reads as "coming", not "missing".
            return .blocked(
                reason: "Back to Draft isn't available yet",
                fix: "pending a GM feature (the daemon has no backward edge)")
        // The forward-edge gates below are UNREACHABLE while the bar is
        // two-slot (nextStates never offers these edges) — kept because they
        // document Store.setPromptStatus's gate coupling and return the day
        // a forward affordance does.
        case (.clarifying, .architecting):
            switch phases.clarification {
            case .loaded:
                if phases.clarificationStatus == .complete { return .open }
                return .blocked(
                    reason: "Clarification is \(phases.clarificationStatus?.rawValue ?? "incomplete")",
                    fix: "finalize it first (gm clarify finalize)")
            case .absent:
                // An absent summary always blocks — the daemon has no bypass;
                // the fix is the bot (clarify writes stay bot/CLI-side).
                return .blocked(
                    reason: "No clarification recorded",
                    fix: "run the bot to open clarification")
            case .idle, .failed:
                return precomputedClarificationGate()
            }
        case (.architecting, .implementing):
            switch phases.architecture {
            case .loaded:
                if phases.architectureStatus == .approved { return .open }
                return .blocked(
                    reason: "Architecture is \(phases.architectureStatus?.rawValue ?? "incomplete")",
                    fix: "approve it first (gm arch approve)")
            case .absent:
                return .blocked(
                    reason: "No architecture recorded",
                    fix: "run the bot to open architecture")
            case .idle, .failed:
                return precomputedArchitectureGate()
            }
        default:
            return .open
        }
    }

    /// The with_reports fallback tiers. `stub.reports == nil` means the
    /// listing was fetched without reports (or an older daemon) — exactly
    /// today's `.unknown`. A nil member with a report block present is the
    /// SUMMARY_ABSENT discrimination surfaced in the listing.
    private func precomputedClarificationGate() -> Gate {
        guard let reports = stub.reports else { return .unknown }
        guard let clarification = reports.clarification else {
            return .blocked(
                reason: "No clarification recorded",
                fix: "run the bot to open clarification")
        }
        if ClarificationStatus(rawValue: clarification.status) == .complete { return .open }
        return .blocked(
            reason: "Clarification is \(clarification.status)",
            fix: "finalize it first (gm clarify finalize)")
    }

    private func precomputedArchitectureGate() -> Gate {
        guard let reports = stub.reports else { return .unknown }
        guard let architecture = reports.architecture else {
            return .blocked(
                reason: "No architecture recorded",
                fix: "run the bot to open architecture")
        }
        if ArchitectureStatus(rawValue: architecture.status) == .approved { return .open }
        return .blocked(
            reason: "Architecture is \(architecture.status)",
            fix: "approve it first (gm arch approve)")
    }

    private func buttonTitle(for next: PromptStatus) -> String {
        switch next {
        case .clarifying: "Begin clarification"
        case .architecting: "Begin architecture"
        case .implementing: "Begin implementation"
        case .reviewing: "Begin review"
        case .done: "Mark done"
        case .draft: "Back to Draft"
        }
    }

    private func buttonIcon(for next: PromptStatus) -> String {
        switch next {
        case .done: "checkmark.circle"
        case .draft: "arrow.uturn.backward.circle"
        default: "arrow.right.circle"
        }
    }

    private func transition(to next: PromptStatus) async {
        inFlight = true
        transitionError = nil
        defer { inFlight = false }
        // Land any pending draft FIRST: a click inside the 2s autosave window
        // must not strand the user's last edit against a freshly-locked
        // prompt. The flush may advance the version, so re-read it.
        await PromptFlushRegistry.shared.flushAll()
        await store.refreshPrompt(uuid: stub.uuid)
        let version = store.prompts.first(where: { $0.uuid == stub.uuid })?.version ?? stub.version
        do {
            _ = try await GMCCDaemonService.shared.setPromptStatus(PromptSetStatusRequest(
                promptUuid: stub.uuid,
                expectedVersion: version,
                status: next
            ))
            await store.refreshPrompt(uuid: stub.uuid)
            await store.refresh()
        } catch let error as DaemonError {
            switch error {
            case .invalidTransition:
                // Lost race (a bot advanced between render and click) or a
                // gate we couldn't pre-compute — show the daemon's reason and
                // resync both the prompt and the gates.
                transitionError = error.userMessage
                await store.refreshPrompt(uuid: stub.uuid)
                await phases.refresh()
            case .versionConflict:
                transitionError = "The prompt changed elsewhere — reloaded; try again."
                await store.refreshPrompt(uuid: stub.uuid)
            default:
                transitionError = error.userMessage
            }
        } catch {
            transitionError = String(describing: error)
        }
    }
}
