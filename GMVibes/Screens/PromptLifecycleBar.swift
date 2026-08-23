import SwiftUI
import GMCCDaemonKit

/// The lifecycle affordance: a six-state rail plus one button per legal next
/// state (`PromptStatus.allowedNext` — the implementing→done skip edge comes
/// along free). Gates are PRE-COMPUTED from the phase store so a blocked
/// transition renders disabled with the reason and issues no wire call; a
/// daemon `INVALID_TRANSITION` is therefore a lost race — its reason string
/// (preserved by `DaemonError.invalidTransition(reason:)`) surfaces verbatim
/// and the phase store refreshes.
struct PromptLifecycleBar: View {
    let stub: PromptStub
    let phases: PromptPhaseStore
    let store: SessionStore

    @Environment(DaemonConnectionModel.self) private var daemon

    @State private var transitionError: String?
    @State private var inFlight = false
    /// Confirmation for the one content-locking edge (draft → clarifying has
    /// no backward edge — leaving draft is irreversible).
    @State private var pendingLock: PromptStatus?

    private var status: PromptStatus? { PromptStatus(rawValue: stub.status) }

    enum Gate {
        case open
        case blocked(reason: String, fix: String)
        /// The client can't adjudicate — phase state unavailable (loading /
        /// failed), or the summary is ABSENT: absence is ambiguous between
        /// "legacy prompt, daemon bypasses the gate" and "never opened"
        /// (the daemon's legacy rule is a created_at epoch the wire doesn't
        /// carry — a client-side proxy would strand users the day the
        /// storage-path backfill lands). Offer the button; the daemon rules
        /// and invalidTransition(reason:) surfaces the real message.
        case unknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                rail
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
        .confirmationDialog(
            "Leave Draft?",
            isPresented: Binding(
                get: { pendingLock != nil },
                set: { if !$0 { pendingLock = nil } }
            ),
            presenting: pendingLock
        ) { next in
            Button("Begin clarification", role: .destructive) {
                pendingLock = nil
                Task { await transition(to: next) }
            }
            Button("Cancel", role: .cancel) { pendingLock = nil }
        } message: { _ in
            Text("Backstory, Goal, and Detail become permanently read-only. This can't be undone.")
        }
    }

    private var blockedHint: String? {
        guard let status else { return nil }
        for next in nextStates(from: status) {
            if case .blocked(let reason, let fix) = gate(to: next) {
                return "\(reason) — \(fix)."
            }
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

    /// Deterministic button order: the forward edge first, the skip edge last.
    private func nextStates(from status: PromptStatus) -> [PromptStatus] {
        PromptStatus.allCases.filter { status.allowedNext.contains($0) }
    }

    @ViewBuilder
    private func transitionButton(to next: PromptStatus) -> some View {
        let gate = gate(to: next)
        Button {
            if next == .clarifying {
                // The one content-locking, irreversible edge — confirm.
                pendingLock = next
            } else {
                Task { await transition(to: next) }
            }
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
    /// needs the architecture approved. Everything else is edge-only. There
    /// is deliberately NO legacy exemption on a loaded-but-wrong-status
    /// summary — the daemon has none either (bypassWhenAbsent only) — and
    /// `.absent` degrades to `.unknown`, never `.blocked` (see Gate).
    private func gate(to next: PromptStatus) -> Gate {
        switch (status, next) {
        case (.clarifying, .architecting):
            switch phases.clarification {
            case .loaded:
                if phases.clarificationStatus == .complete { return .open }
                return .blocked(
                    reason: "Clarification is \(phases.clarificationStatus?.rawValue ?? "incomplete")",
                    fix: "finalize it first (gm clarify finalize)")
            case .absent, .idle, .failed:
                return .unknown
            }
        case (.architecting, .implementing):
            switch phases.architecture {
            case .loaded:
                if phases.architectureStatus == .approved { return .open }
                return .blocked(
                    reason: "Architecture is \(phases.architectureStatus?.rawValue ?? "incomplete")",
                    fix: "approve it first (gm arch approve)")
            case .absent, .idle, .failed:
                return .unknown
            }
        default:
            return .open
        }
    }

    private func buttonTitle(for next: PromptStatus) -> String {
        switch next {
        case .clarifying: "Begin clarification"
        case .architecting: "Begin architecture"
        case .implementing: "Begin implementation"
        case .reviewing: "Begin review"
        case .done: "Mark done"
        // Unreachable — allowedNext has no backward edge; exhaustiveness only.
        case .draft: "Draft"
        }
    }

    private func buttonIcon(for next: PromptStatus) -> String {
        next == .done ? "checkmark.circle" : "arrow.right.circle"
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
                await phases.refresh(daemon: daemon)
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
