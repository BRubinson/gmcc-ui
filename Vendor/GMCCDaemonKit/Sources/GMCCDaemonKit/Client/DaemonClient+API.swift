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

    // MARK: - Full-text search (v8)

    public func search(_ req: SearchRequest) throws -> SearchResponse {
        try request(type: .search, payload: req, responseType: SearchResponse.self)
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

// MARK: - Clarification (v7)

extension DaemonClient {
    public func clarifyOpen(_ req: ClarifyOpenRequest) throws -> ClarifySummaryResponse {
        try request(type: .clarifyOpen, payload: req, responseType: ClarifySummaryResponse.self)
    }

    public func clarifyAsk(_ req: ClarifyAskRequest) throws -> ClarificationRowResponse {
        try request(type: .clarifyAsk, payload: req, responseType: ClarificationRowResponse.self)
    }

    public func clarifySeal(_ req: ClarifySealRequest) throws -> ClarifySummaryResponse {
        try request(type: .clarifySeal, payload: req, responseType: ClarifySummaryResponse.self)
    }

    public func clarifyAnswer(_ req: ClarifyAnswerRequest) throws -> ClarificationRowResponse {
        try request(type: .clarifyAnswer, payload: req, responseType: ClarificationRowResponse.self)
    }

    public func clarifyReopen(_ req: ClarifyReopenRequest) throws -> ClarifySummaryResponse {
        try request(type: .clarifyReopen, payload: req, responseType: ClarifySummaryResponse.self)
    }

    public func clarifyFinalize(_ req: ClarifyFinalizeRequest) throws -> ClarifyFinalizeResponse {
        try request(type: .clarifyFinalize, payload: req, responseType: ClarifyFinalizeResponse.self)
    }

    public func clarifyGet(_ req: ClarifyGetRequest) throws -> ClarifyGetResponse {
        try request(type: .clarifyGet, payload: req, responseType: ClarifyGetResponse.self)
    }
}

// MARK: - Exploration (v9)

extension DaemonClient {
    public func exploreOpen(_ req: ExploreOpenRequest) throws -> ExploreSummaryResponse {
        try request(type: .exploreOpen, payload: req, responseType: ExploreSummaryResponse.self)
    }

    public func exploreKeyFileAdd(_ req: ExploreKeyFileAddRequest) throws -> ExploreKeyFileAddResponse {
        try request(type: .exploreKeyFileAdd, payload: req, responseType: ExploreKeyFileAddResponse.self)
    }

    public func exploreFindingAdd(_ req: ExploreFindingAddRequest) throws -> ExploreFindingRowResponse {
        try request(type: .exploreFindingAdd, payload: req, responseType: ExploreFindingRowResponse.self)
    }

    public func exploreRank(_ req: ExploreRankRequest) throws -> ExploreRankResponse {
        try request(type: .exploreRank, payload: req, responseType: ExploreRankResponse.self)
    }

    public func exploreComplete(_ req: ExploreCompleteRequest) throws -> ExploreSummaryResponse {
        try request(type: .exploreComplete, payload: req, responseType: ExploreSummaryResponse.self)
    }

    public func exploreReopen(_ req: ExploreReopenRequest) throws -> ExploreSummaryResponse {
        try request(type: .exploreReopen, payload: req, responseType: ExploreSummaryResponse.self)
    }

    public func exploreGet(_ req: ExploreGetRequest) throws -> ExploreGetResponse {
        try request(type: .exploreGet, payload: req, responseType: ExploreGetResponse.self)
    }
}

// MARK: - Review (v9)

extension DaemonClient {
    public func reviewOpen(_ req: ReviewOpenRequest) throws -> ReviewSummaryResponse {
        try request(type: .reviewOpen, payload: req, responseType: ReviewSummaryResponse.self)
    }

    public func reviewFindingAdd(_ req: ReviewFindingAddRequest) throws -> ReviewFindingRowResponse {
        try request(type: .reviewFindingAdd, payload: req, responseType: ReviewFindingRowResponse.self)
    }

    public func reviewRank(_ req: ReviewRankRequest) throws -> ReviewRankResponse {
        try request(type: .reviewRank, payload: req, responseType: ReviewRankResponse.self)
    }

    public func reviewResolve(_ req: ReviewResolveRequest) throws -> ReviewFindingRowResponse {
        try request(type: .reviewResolve, payload: req, responseType: ReviewFindingRowResponse.self)
    }

    public func reviewComplete(_ req: ReviewCompleteRequest) throws -> ReviewSummaryResponse {
        try request(type: .reviewComplete, payload: req, responseType: ReviewSummaryResponse.self)
    }

    public func reviewReopen(_ req: ReviewReopenRequest) throws -> ReviewSummaryResponse {
        try request(type: .reviewReopen, payload: req, responseType: ReviewSummaryResponse.self)
    }

    public func reviewGet(_ req: ReviewGetRequest) throws -> ReviewGetResponse {
        try request(type: .reviewGet, payload: req, responseType: ReviewGetResponse.self)
    }
}

// MARK: - Architecture (v7)

extension DaemonClient {
    public func archOpen(_ req: ArchOpenRequest) throws -> ArchSummaryResponse {
        try request(type: .archOpen, payload: req, responseType: ArchSummaryResponse.self)
    }

    public func archSummarize(_ req: ArchSummarizeRequest) throws -> ArchSummaryResponse {
        try request(type: .archSummarize, payload: req, responseType: ArchSummaryResponse.self)
    }

    public func archPersistAdd(_ req: ArchPersistAddRequest) throws -> ArchPersistAddResponse {
        try request(type: .archPersistAdd, payload: req, responseType: ArchPersistAddResponse.self)
    }

    public func archFieldAdd(_ req: ArchFieldAddRequest) throws -> ArchFieldAddResponse {
        try request(type: .archFieldAdd, payload: req, responseType: ArchFieldAddResponse.self)
    }

    public func archGeneralAdd(_ req: ArchGeneralAddRequest) throws -> ArchGeneralAddResponse {
        try request(type: .archGeneralAdd, payload: req, responseType: ArchGeneralAddResponse.self)
    }

    public func archPropose(_ req: ArchProposeRequest) throws -> ArchSummaryResponse {
        try request(type: .archPropose, payload: req, responseType: ArchSummaryResponse.self)
    }

    public func archApprove(_ req: ArchApproveRequest) throws -> ArchSummaryResponse {
        try request(type: .archApprove, payload: req, responseType: ArchSummaryResponse.self)
    }

    public func archRevise(_ req: ArchReviseRequest) throws -> ArchSummaryResponse {
        try request(type: .archRevise, payload: req, responseType: ArchSummaryResponse.self)
    }

    public func archGet(_ req: ArchGetRequest) throws -> ArchGetResponse {
        try request(type: .archGet, payload: req, responseType: ArchGetResponse.self)
    }
}

// MARK: - Git state + config (v7)

extension DaemonClient {
    public func sessionResolve(_ req: SessionResolveRequest) throws -> SessionResolveResponse {
        try request(type: .sessionResolve, payload: req, responseType: SessionResolveResponse.self)
    }

    public func instanceCurrentSession(
        _ req: InstanceCurrentSessionRequest
    ) throws -> InstanceCurrentSessionResponse {
        try request(
            type: .instanceCurrentSession, payload: req,
            responseType: InstanceCurrentSessionResponse.self)
    }

    public func pathsGet() throws -> PathsGetResponse {
        try request(type: .pathsGet, payload: PathsGetRequest(), responseType: PathsGetResponse.self)
    }

    public func configSet(_ req: ConfigSetRequest) throws -> ConfigSetResponse {
        try request(type: .configSet, payload: req, responseType: ConfigSetResponse.self)
    }
}
