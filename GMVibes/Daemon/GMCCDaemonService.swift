import Foundation
import GMCCDaemonKit

/// The single off-main boundary for all daemon socket I/O.
///
/// `DaemonClient` is blocking POSIX I/O, so calls are trampolined onto a
/// dedicated serial DispatchQueue rather than run on a cooperative-pool
/// thread. The probe client has autostart OFF so health checks report true
/// daemon state instead of resurrecting a daemon the user killed;
/// `startDaemon()` is the only autostart path in the app.
actor GMCCDaemonService {
    static let shared = GMCCDaemonService()

    private let client = DaemonClient(clientName: "gmvibes", autostart: false)
    private let queue = DispatchQueue(label: "gmvibes.daemon.client", qos: .userInitiated)

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.binDaemon.path)
    }

    private func perform<T: Sendable>(
        _ body: @escaping @Sendable (DaemonClient) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [client] in
                do {
                    continuation.resume(returning: try body(client))
                } catch {
                    // A transport-level failure leaves a dead fd cached inside
                    // DaemonClient (nothing closes it on a thrown roundTrip),
                    // and the next call would skip redialing forever. Force a
                    // fresh dial; a server-reported domain error means the
                    // connection itself is healthy.
                    if let clientError = error as? DaemonClientError {
                        switch clientError {
                        case .wire, .unreachable, .protocolMismatch: client.close()
                        case .server: break
                        }
                    }
                    continuation.resume(throwing: DaemonError(error))
                }
            }
        }
    }

    // MARK: - Infra

    func ping() async throws -> PingResponse { try await perform { try $0.ping() } }
    func status() async throws -> StatusResponse { try await perform { try $0.status() } }

    /// The ONLY call site permitted to spawn the daemon: a throwaway
    /// autostart-enabled client, reached exclusively from the explicit
    /// "Start daemon" affordance.
    func startDaemon() async throws -> PingResponse {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let launcher = DaemonClient(clientName: "gmvibes-launch", autostart: true)
                do {
                    continuation.resume(returning: try launcher.ping())
                } catch {
                    continuation.resume(throwing: DaemonError(error))
                }
                launcher.close()
            }
        }
    }

    // MARK: - Listing

    func listProjects() async throws -> [ProjectRow] {
        try await perform { try $0.listProjects().projects }
    }

    func listInstances(projectUuid: String? = nil) async throws -> [InstanceRow] {
        let uuid = Self.normalized(projectUuid)
        return try await perform { try $0.listInstances(InstanceListRequest(projectUuid: uuid)).instances }
    }

    func listSessions(instanceUuid: String? = nil) async throws -> [SessionStub] {
        let uuid = Self.normalized(instanceUuid)
        return try await perform { try $0.listSessions(SessionListRequest(instanceUuid: uuid)).sessions }
    }

    // MARK: - Catalog search

    func searchCatalog(query: String, projectUuid: String? = nil, limit: Int? = nil) async throws -> CatalogSearchResponse {
        let uuid = Self.normalized(projectUuid)
        return try await perform { try $0.searchCatalog(CatalogSearchRequest(query: query, projectUuid: uuid, limit: limit)) }
    }

    // MARK: - Session

    func getSession(sessionUuid: String) async throws -> SessionGetResponse {
        let uuid = Self.normalized(sessionUuid)
        return try await perform { try $0.getSession(SessionGetRequest(sessionUuid: uuid)) }
    }

    func updateSession(_ request: SessionUpdateRequest) async throws -> SessionRow {
        let req = SessionUpdateRequest(
            sessionUuid: Self.normalized(request.sessionUuid),
            expectedVersion: request.expectedVersion,
            name: request.name,
            backstory: request.backstory,
            goal: request.goal
        )
        return try await perform { try $0.updateSession(req) }
    }

    // MARK: - Prompt

    func listPrompts(sessionUuid: String) async throws -> [PromptStub] {
        let uuid = Self.normalized(sessionUuid)
        return try await perform { try $0.listPrompts(PromptListRequest(sessionUuid: uuid)).prompts }
    }

    func getPrompt(promptUuid: String) async throws -> PromptGetResponse {
        let uuid = Self.normalized(promptUuid)
        return try await perform { try $0.getPrompt(PromptGetRequest(promptUuid: uuid)) }
    }

    // Request-taking wrappers rebuild the request with normalized uuids — the
    // service boundary is the SINGLE place the uppercase-uuid trap is fixed,
    // and the mutation paths are exactly where a silent NOT_FOUND costs most.

    func createPrompt(_ request: PromptCreateRequest) async throws -> PromptRow {
        let req = PromptCreateRequest(
            sessionUuid: Self.normalized(request.sessionUuid),
            uuid: Self.normalized(request.uuid),
            code: request.code,
            name: request.name,
            backstory: request.backstory,
            goal: request.goal,
            detail: request.detail,
            command: request.command,
            ckfsRelativeStoragePath: request.ckfsRelativeStoragePath
        )
        return try await perform { try $0.createPrompt(req) }
    }

    func updatePromptContent(_ request: PromptUpdateContentRequest) async throws -> PromptRow {
        let req = PromptUpdateContentRequest(
            promptUuid: Self.normalized(request.promptUuid),
            expectedVersion: request.expectedVersion,
            backstory: request.backstory,
            goal: request.goal,
            detail: request.detail
        )
        return try await perform { try $0.updatePromptContent(req) }
    }

    func setPromptStatus(_ request: PromptSetStatusRequest) async throws -> PromptRow {
        let req = PromptSetStatusRequest(
            promptUuid: Self.normalized(request.promptUuid),
            expectedVersion: request.expectedVersion,
            status: request.status
        )
        return try await perform { try $0.setPromptStatus(req) }
    }

    // MARK: - Clarification / architecture (v7, read-only)

    func clarification(promptUuid: String) async throws -> ClarifyGetResponse {
        let uuid = Self.normalized(promptUuid)
        return try await perform { try $0.clarifyGet(ClarifyGetRequest(promptUuid: uuid)) }
    }

    func architecture(promptUuid: String) async throws -> ArchGetResponse {
        let uuid = Self.normalized(promptUuid)
        return try await perform { try $0.archGet(ArchGetRequest(promptUuid: uuid)) }
    }

    // MARK: - Git state / paths (v7)

    func instanceCurrentSession(instanceUuid: String) async throws -> InstanceCurrentSessionResponse {
        let uuid = Self.normalized(instanceUuid)
        return try await perform { try $0.instanceCurrentSession(InstanceCurrentSessionRequest(instanceUuid: uuid)) }
    }

    func paths() async throws -> PathsGetResponse {
        try await perform { try $0.pathsGet() }
    }

    // MARK: - File change / artifact

    // Retained for session prompt 2 (annotated diffs) even though SESSION_GET's
    // summaries cover today's rendering — the clarified goal lands this
    // plumbing deliberately.
    func listFileChanges(_ request: FileChangeListRequest) async throws -> [FileChangeRow] {
        let req = FileChangeListRequest(
            sessionUuid: Self.normalized(request.sessionUuid),
            promptUuid: Self.normalized(request.promptUuid),
            relativePath: request.relativePath,
            limit: request.limit
        )
        return try await perform { try $0.listFileChanges(req).changes }
    }

    func listArtifacts(promptUuid: String) async throws -> [ArtifactRow] {
        let uuid = Self.normalized(promptUuid)
        return try await perform { try $0.listArtifacts(ArtifactListRequest(promptUuid: uuid)).artifacts }
    }

    // MARK: - Kbite

    func listKbites(scope: KbiteScope, ownerUuid: String, all: Bool = false) async throws -> [KbiteRef] {
        let uuid = Self.normalized(ownerUuid)
        // Server short-circuits scope resolution when all == true, so the
        // owner uuid is ignored in that mode.
        return try await perform { try $0.listKbites(KbiteListRequest(scope: scope, ownerUuid: uuid, all: all ? true : nil)).kbites }
    }

    func addKbite(scope: KbiteScope, ownerUuid: String, code: String) async throws -> KbiteAddResponse {
        let uuid = Self.normalized(ownerUuid)
        return try await perform { try $0.addKbite(KbiteAddRequest(scope: scope, ownerUuid: uuid, code: code)) }
    }

    func removeKbite(scope: KbiteScope, ownerUuid: String, code: String) async throws -> KbiteRemoveResponse {
        let uuid = Self.normalized(ownerUuid)
        return try await perform { try $0.removeKbite(KbiteRemoveRequest(scope: scope, ownerUuid: uuid, code: code)) }
    }

    func searchKbites(query: String, kbiteUuids: [String]? = nil, limit: Int? = nil) async throws -> [KbiteSearchHit] {
        let uuids = kbiteUuids.map { $0.map(Self.normalized) }
        return try await perform { try $0.searchKbites(KbiteSearchRequest(query: query, kbiteUuids: uuids, limit: limit)).hits }
    }

    func getKbiteFile(fileUuid: String) async throws -> KbiteResourceFileRow {
        let uuid = Self.normalized(fileUuid)
        return try await perform { try $0.getKbiteFile(KbiteFileGetRequest(fileUuid: uuid)).file }
    }

    // MARK: - Helpers

    private nonisolated static func normalized(_ uuid: String?) -> String? {
        uuid.map(normalized)
    }

    // Non-fatal guard: flag the drift in debug, but always self-correct — a
    // trapped assert on a path that lowercases one line later helps nobody.
    private nonisolated static func normalized(_ uuid: String) -> String {
        let lower = uuid.lowercased()
        if lower != uuid {
            assertionFailure("uuid crossed the service boundary uppercased: \(uuid)")
        }
        return lower
    }
}
