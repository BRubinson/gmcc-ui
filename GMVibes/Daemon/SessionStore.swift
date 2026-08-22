import Foundation
import Observation
import GMCCDaemonKit

/// Per-session-window read state: the SessionRow, its prompt stubs, change
/// summaries, and a full PromptGetResponse per stub. The prefetch is
/// deliberately SEQUENTIAL — the daemon serves every request on one serial
/// queue with no fairness, so a burst here would stall the user's terminal
/// `gm` calls. Prefetched bodies serve prose search, the editor's content,
/// and the memory-root derivation in one cache.
@Observable @MainActor
final class SessionStore {
    let sessionUuid: String

    private(set) var session: SessionRow?
    private(set) var prompts: [PromptStub] = []
    private(set) var changeSummary: ChangeSummary?
    private(set) var promptChanges: [PromptChangeSummary] = []
    /// Full prompt payloads by prompt uuid.
    private(set) var promptDetails: [String: PromptGetResponse] = [:]
    private(set) var lastError: String?
    private(set) var hasLoaded = false

    private let service = GMCCDaemonService.shared

    init(sessionUuid: String) {
        self.sessionUuid = sessionUuid
    }

    func refresh() async {
        do {
            let response = try await service.getSession(sessionUuid: sessionUuid)
            if session != response.session { session = response.session }
            let sorted = response.prompts.sorted { $0.seq > $1.seq }
            if prompts != sorted { prompts = sorted }
            if changeSummary != response.changeSummary { changeSummary = response.changeSummary }
            if promptChanges != response.promptChanges { promptChanges = response.promptChanges }
            if lastError != nil { lastError = nil }
            hasLoaded = true

            // Drop details for prompts that no longer exist.
            let live = Set(sorted.map(\.uuid))
            for gone in promptDetails.keys where !live.contains(gone) {
                promptDetails[gone] = nil
            }
            // Sequential prefetch: stale (version drift) or missing details only.
            for stub in sorted {
                if Task.isCancelled { return }
                if promptDetails[stub.uuid]?.prompt.version != stub.version {
                    await refreshPrompt(uuid: stub.uuid)
                }
            }
        } catch let error as DaemonError {
            lastError = Self.describe(error)
            hasLoaded = true
        } catch {
            lastError = String(describing: error)
            hasLoaded = true
        }
    }

    func refreshPrompt(uuid: String) async {
        do {
            let response = try await service.getPrompt(promptUuid: uuid)
            if promptDetails[uuid] != response { promptDetails[uuid] = response }
        } catch {
            // Targeted load failure is non-fatal; the stub row still renders.
        }
    }

    private static func describe(_ error: DaemonError) -> String {
        switch error {
        case .notFound: return "Session not in the GMCC database yet — run /import_legacy_yaml_gmcc."
        case .notInstalled: return "Daemon not installed"
        case .unreachable(let m): return m
        case .server(let code, let message): return "\(code): \(message)"
        case .transport(let m): return m
        default: return String(describing: error)
        }
    }
}
