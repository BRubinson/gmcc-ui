import Foundation

// Typed one-method-per-message facade — the entire integration surface for
// gm and GMVibes. Wraps the generic request plumbing; callers never touch
// MessageType or responseType.

extension DaemonClient {
    // MARK: - Infra

    public func ping() throws -> PingResponse {
        try request(type: .ping, payload: PingRequest(), responseType: PingResponse.self)
    }

    public func status() throws -> StatusResponse {
        try request(type: .status, payload: StatusRequest(), responseType: StatusResponse.self)
    }

    public func shutdown() throws -> ShutdownResponse {
        try request(type: .shutdown, payload: ShutdownRequest(), responseType: ShutdownResponse.self)
    }

    public func backup() throws -> BackupResponse {
        try request(type: .backup, payload: BackupRequest(), responseType: BackupResponse.self)
    }

    // MARK: - Context

    public func ensureContext(_ req: ContextEnsureRequest) throws -> ContextEnsureResponse {
        try request(type: .contextEnsure, payload: req, responseType: ContextEnsureResponse.self)
    }

    public func getContext(_ req: ContextGetRequest) throws -> ContextGetResponse {
        try request(type: .contextGet, payload: req, responseType: ContextGetResponse.self)
    }

    // MARK: - Listing

    public func listProjects() throws -> ProjectListResponse {
        try request(type: .projectList, payload: ProjectListRequest(), responseType: ProjectListResponse.self)
    }

    public func listInstances(_ req: InstanceListRequest) throws -> InstanceListResponse {
        try request(type: .instanceList, payload: req, responseType: InstanceListResponse.self)
    }

    public func listSessions(_ req: SessionListRequest) throws -> SessionListResponse {
        try request(type: .sessionList, payload: req, responseType: SessionListResponse.self)
    }

    // MARK: - Catalog search

    public func searchCatalog(_ req: CatalogSearchRequest) throws -> CatalogSearchResponse {
        try request(type: .catalogSearch, payload: req, responseType: CatalogSearchResponse.self)
    }

    // MARK: - Session

    public func getSession(_ req: SessionGetRequest) throws -> SessionGetResponse {
        try request(type: .sessionGet, payload: req, responseType: SessionGetResponse.self)
    }

    public func updateSession(_ req: SessionUpdateRequest) throws -> SessionRow {
        try request(type: .sessionUpdate, payload: req, responseType: SessionRow.self)
    }

    // MARK: - Prompt

    public func createPrompt(_ req: PromptCreateRequest) throws -> PromptRow {
        try request(type: .promptCreate, payload: req, responseType: PromptRow.self)
    }

    public func listPrompts(_ req: PromptListRequest) throws -> PromptListResponse {
        try request(type: .promptList, payload: req, responseType: PromptListResponse.self)
    }

    public func getPrompt(_ req: PromptGetRequest) throws -> PromptGetResponse {
        try request(type: .promptGet, payload: req, responseType: PromptGetResponse.self)
    }

    public func updatePromptContent(_ req: PromptUpdateContentRequest) throws -> PromptRow {
        try request(type: .promptUpdateContent, payload: req, responseType: PromptRow.self)
    }

    public func setPromptStatus(_ req: PromptSetStatusRequest) throws -> PromptRow {
        try request(type: .promptSetStatus, payload: req, responseType: PromptRow.self)
    }

    // MARK: - Artifact

    public func addArtifact(_ req: ArtifactAddRequest) throws -> ArtifactRow {
        try request(type: .artifactAdd, payload: req, responseType: ArtifactRow.self)
    }

    public func listArtifacts(_ req: ArtifactListRequest) throws -> ArtifactListResponse {
        try request(type: .artifactList, payload: req, responseType: ArtifactListResponse.self)
    }

    // MARK: - File change

    public func addFileChange(_ req: FileChangeAdd) throws -> FileChangeAddResponse {
        try request(type: .fileChangeAdd, payload: req, responseType: FileChangeAddResponse.self)
    }

    public func listFileChanges(_ req: FileChangeListRequest) throws -> FileChangeListResponse {
        try request(type: .fileChangeList, payload: req, responseType: FileChangeListResponse.self)
    }

    // MARK: - Kbite

    public func listKbites(_ req: KbiteListRequest) throws -> KbiteListResponse {
        try request(type: .kbiteList, payload: req, responseType: KbiteListResponse.self)
    }

    public func addKbite(_ req: KbiteAddRequest) throws -> KbiteAddResponse {
        try request(type: .kbiteAdd, payload: req, responseType: KbiteAddResponse.self)
    }

    public func removeKbite(_ req: KbiteRemoveRequest) throws -> KbiteRemoveResponse {
        try request(type: .kbiteRemove, payload: req, responseType: KbiteRemoveResponse.self)
    }

    public func openKbiteMaw(_ req: KbiteMawOpenRequest) throws -> KbiteMawOpenResponse {
        try request(type: .kbiteMawOpen, payload: req, responseType: KbiteMawOpenResponse.self)
    }

    public func digestKbite(_ req: KbiteDigestRequest) throws -> KbiteDigestResponse {
        try request(type: .kbiteDigest, payload: req, responseType: KbiteDigestResponse.self)
    }

    public func getKbite(_ req: KbiteGetRequest) throws -> KbiteGetResponse {
        try request(type: .kbiteGet, payload: req, responseType: KbiteGetResponse.self)
    }

    public func getKbiteFile(_ req: KbiteFileGetRequest) throws -> KbiteFileGetResponse {
        try request(type: .kbiteFileGet, payload: req, responseType: KbiteFileGetResponse.self)
    }

    public func searchKbites(_ req: KbiteSearchRequest) throws -> KbiteSearchResponse {
        try request(type: .kbiteSearch, payload: req, responseType: KbiteSearchResponse.self)
    }

    public func tagKbiteKeyword(_ req: KbiteKeywordTagRequest) throws -> KbiteKeywordTagResponse {
        try request(type: .kbiteKeywordTag, payload: req, responseType: KbiteKeywordTagResponse.self)
    }

    // MARK: - Audit

    public func listEvents(_ req: EventListRequest) throws -> EventListResponse {
        try request(type: .eventList, payload: req, responseType: EventListResponse.self)
    }
}
