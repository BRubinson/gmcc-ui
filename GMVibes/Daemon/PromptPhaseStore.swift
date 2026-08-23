import Foundation
import Observation
import GMCCDaemonKit

/// Per-prompt read model over CLARIFY_GET + ARCH_GET — the app's only surface
/// onto the db-native clarification/architecture subsystem (read-only by
/// clarified scope; every write verb stays bot/CLI-side).
///
/// Memoized on `SessionScope` beside the save actors so N panes on one prompt
/// cost one fetch. NOT_FOUND is the NORMAL state for most prompts (89 done +
/// 18 draft legacy rows predate m0002) — it publishes `.absent`, never an
/// error banner.
///
/// On every load the store registers its summary uuids with the connection
/// model: CLARIFICATION_CHANGE / ARCHITECTURE_CHANGE events carry the SUMMARY
/// uuid as subject (only open/summarize/finalize payloads repeat the prompt
/// uuid), so without this registry live phase rendering would silently never
/// refresh.
@Observable
@MainActor
final class PromptPhaseStore {
    enum Phase<T: Equatable>: Equatable {
        case idle
        /// No summary row exists (NOT_FOUND) — expected for legacy prompts
        /// and any prompt that hasn't entered the phase.
        case absent
        case loaded(T)
        case failed(String)
    }

    let promptUuid: String
    private(set) var clarification: Phase<ClarifyGetResponse> = .idle
    private(set) var architecture: Phase<ArchGetResponse> = .idle
    private(set) var hasLoaded = false

    private let service = GMCCDaemonService.shared
    private weak var daemon: DaemonConnectionModel?
    private var inFlight: Task<Void, Never>?

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
    /// section's first render must share one round trip pair.
    func refresh(daemon: DaemonConnectionModel) async {
        self.daemon = daemon
        if let running = inFlight {
            await running.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performRefresh() async {
        var summaries: Set<String> = []

        let newClarification: Phase<ClarifyGetResponse>
        do {
            let response = try await service.clarification(promptUuid: promptUuid)
            summaries.insert(response.summary.uuid.lowercased())
            newClarification = .loaded(response)
        } catch DaemonError.notFound {
            newClarification = .absent
        } catch let error as DaemonError {
            newClarification = .failed(error.userMessage)
        } catch {
            newClarification = .failed(String(describing: error))
        }

        let newArchitecture: Phase<ArchGetResponse>
        do {
            let response = try await service.architecture(promptUuid: promptUuid)
            summaries.insert(response.summary.uuid.lowercased())
            newArchitecture = .loaded(response)
        } catch DaemonError.notFound {
            newArchitecture = .absent
        } catch let error as DaemonError {
            newArchitecture = .failed(error.userMessage)
        } catch {
            newArchitecture = .failed(String(describing: error))
        }

        // Change-gated publication (house idiom).
        if clarification != newClarification { clarification = newClarification }
        if architecture != newArchitecture { architecture = newArchitecture }
        hasLoaded = true

        if !summaries.isEmpty {
            daemon?.registerSummaries(summaries, forPrompt: promptUuid, owner: ObjectIdentifier(self))
        }
    }

    /// Called on scope retirement — stops summary-subject events routing
    /// through a dead store's registration.
    func unregister() {
        daemon?.unregisterSummaries(ifOwnedBy: ObjectIdentifier(self))
    }
}
