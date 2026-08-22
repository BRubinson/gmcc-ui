import Foundation

// Codable wire payloads, one MARK section per message family. All types follow
// the swift.yeet_template.md lowering conventions: let-only structs,
// Codable/Hashable/Sendable floor, snake_case CodingKeys, no force-unwraps.
// Read-side row DTOs live in Rows.swift.

// MARK: - Identity

/// The identity block wrapped into every domain table (the db analogue of the
/// has_serial_id / has_uuid / base mixins in gmcc.yeet.yaml). Defined once
/// here; GRDB records declare these five columns flat because GRDB flattens
/// only top-level Codable properties into columns.
public struct BaseEntity: Codable, Hashable, Sendable {
    /// Serial rowid — internal to the db, nil before insert.
    public let id: Int64?
    /// v4 lowercase — the external join key shared with ckfs yamls and the wire.
    public let uuid: String
    /// Incremented by the daemon on every write (optimistic concurrency —
    /// guarded updates require the caller's expected_version to match).
    public let version: Int64
    public let createdAt: String
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case uuid
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(id: Int64? = nil, uuid: String, version: Int64, createdAt: String, updatedAt: String) {
        self.id = id
        self.uuid = uuid
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Kinds of rows in the append-only daemon_event table. Stored as free text in
/// the db; this enum is the write-path enforcement. On the wire (events,
/// EVENT_LIST) kind travels as a raw string so old clients survive new kinds.
public enum DaemonEventKind: String, Codable, Hashable, CaseIterable, Sendable {
    case createProject = "CREATE_PROJECT"
    case createInstance = "CREATE_INSTANCE"
    case createSession = "CREATE_SESSION"
    case updateSession = "UPDATE_SESSION"
    case createPrompt = "CREATE_PROMPT"
    case updatePrompt = "UPDATE_PROMPT"
    case promptStatusChange = "PROMPT_STATUS_CHANGE"
    case addArtifact = "ADD_ARTIFACT"
    case fileChange = "FILE_CHANGE"
    case backup = "BACKUP"
    case daemonStart = "DAEMON_START"
    case daemonStop = "DAEMON_STOP"
    case addKbite = "ADD_KBITE"
    case removeKbite = "REMOVE_KBITE"
    case kbiteDigest = "KBITE_DIGEST"
    case kbiteKeywordTag = "KBITE_KEYWORD_TAG"
}

/// The four registry levels a kbite can be activated at. rawValue drives the
/// `{scope}_active_kbite` / `{scope}_uuid` table and column names — the only
/// way dynamic SQL identifiers are ever built (enum-bound, no injection).
public enum KbiteScope: String, Codable, Hashable, CaseIterable, Sendable {
    case project
    case instance
    case session
    case prompt
}

/// Where a KBITE_KEYWORD_TAG attach/detach lands: the kbite-level vocabulary
/// junction or the per-resource-file junction.
public enum KeywordTagLevel: String, Codable, Hashable, CaseIterable, Sendable {
    case kbite
    case file
}

public enum ChangeKind: String, Codable, Hashable, CaseIterable, Sendable {
    case edit
    case create
    case delete
    case rename
}

/// Prompt lifecycle. Transitions are forward-only and adjacent-only:
/// draft → clarifying → clarified. Everything else is INVALID_TRANSITION.
public enum PromptStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case draft
    case clarifying
    case clarified

    /// The only legal next state, encoded as a successor function so an
    /// accidentally permissive transition switch is unwritable.
    public var successor: PromptStatus? {
        switch self {
        case .draft: return .clarifying
        case .clarifying: return .clarified
        case .clarified: return nil
        }
    }
}

public enum SessionStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case active
    case closed
}

/// Prompt artifact kinds — pointers to bot-phase memory/ files. `qualified`
/// is the clarified-phase output registered as an artifact going forward.
public enum ArtifactKind: String, Codable, Hashable, CaseIterable, Sendable {
    case explore
    case architecture
    case review
    case qualified
    case other
}

// MARK: - HELLO

public struct Hello: Codable, Hashable, Sendable {
    public let clientName: String
    public let pid: Int32

    private enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case pid
    }

    public init(clientName: String, pid: Int32) {
        self.clientName = clientName
        self.pid = pid
    }
}

public struct HelloAck: Codable, Hashable, Sendable {
    public let daemonPid: Int32
    public let protocolVersion: Int

    private enum CodingKeys: String, CodingKey {
        case daemonPid = "daemon_pid"
        case protocolVersion = "protocol_version"
    }

    public init(daemonPid: Int32, protocolVersion: Int) {
        self.daemonPid = daemonPid
        self.protocolVersion = protocolVersion
    }
}

// MARK: - PING

public struct PingRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct PingResponse: Codable, Hashable, Sendable {
    public let daemonPid: Int32
    public let protocolVersion: Int
    public let buildSha: String
    public let buildDate: String
    public let startedAt: String
    public let uptimeSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case daemonPid = "daemon_pid"
        case protocolVersion = "protocol_version"
        case buildSha = "build_sha"
        case buildDate = "build_date"
        case startedAt = "started_at"
        case uptimeSeconds = "uptime_seconds"
    }

    public init(
        daemonPid: Int32,
        protocolVersion: Int,
        buildSha: String,
        buildDate: String,
        startedAt: String,
        uptimeSeconds: Int
    ) {
        self.daemonPid = daemonPid
        self.protocolVersion = protocolVersion
        self.buildSha = buildSha
        self.buildDate = buildDate
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
    }
}

// MARK: - STATUS

public struct StatusRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct StatusResponse: Codable, Hashable, Sendable {
    public let daemonPid: Int32
    public let protocolVersion: Int
    public let socketPath: String
    public let dbPath: String
    public let schemaVersion: Int
    public let tableCounts: [String: Int]
    public let startedAt: String
    public let uptimeSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case daemonPid = "daemon_pid"
        case protocolVersion = "protocol_version"
        case socketPath = "socket_path"
        case dbPath = "db_path"
        case schemaVersion = "schema_version"
        case tableCounts = "table_counts"
        case startedAt = "started_at"
        case uptimeSeconds = "uptime_seconds"
    }

    public init(
        daemonPid: Int32,
        protocolVersion: Int,
        socketPath: String,
        dbPath: String,
        schemaVersion: Int,
        tableCounts: [String: Int],
        startedAt: String,
        uptimeSeconds: Int
    ) {
        self.daemonPid = daemonPid
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
        self.dbPath = dbPath
        self.schemaVersion = schemaVersion
        self.tableCounts = tableCounts
        self.startedAt = startedAt
        self.uptimeSeconds = uptimeSeconds
    }
}

// MARK: - SHUTDOWN

public struct ShutdownRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct ShutdownResponse: Codable, Hashable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: - SUBSCRIBE / EVENT

public struct Subscribe: Codable, Hashable, Sendable {
    /// Replay cursor: daemon_event.id of the last event the subscriber has
    /// seen. Events with id > since_id are replayed before live streaming
    /// begins. nil = live-only from now.
    public let sinceId: Int64?

    private enum CodingKeys: String, CodingKey {
        case sinceId = "since_id"
    }

    public init(sinceId: Int64? = nil) {
        self.sinceId = sinceId
    }
}

public struct SubscribeAck: Codable, Hashable, Sendable {
    /// The replay horizon: highest daemon_event.id at subscribe time. Replayed
    /// EVENT lines (ids ≤ this) follow the ack, then live events stream.
    public let lastEventId: Int64
    public let replayCount: Int

    private enum CodingKeys: String, CodingKey {
        case lastEventId = "last_event_id"
        case replayCount = "replay_count"
    }

    public init(lastEventId: Int64, replayCount: Int) {
        self.lastEventId = lastEventId
        self.replayCount = replayCount
    }
}

/// Unsolicited daemon → subscriber notification mirroring a daemon_event row.
/// `id` is the durable reconnect cursor (created_at is seconds-precision and
/// ties — display/coarse filter only, never a cursor). `kind` is a raw string
/// so rows with kinds added later never break older clients.
public struct EventNotification: Codable, Hashable, Sendable {
    public let id: Int64
    public let kind: String
    public let subjectUuid: String?
    public let payload: String?
    public let createdAt: String

    public var eventKind: DaemonEventKind? { DaemonEventKind(rawValue: kind) }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case subjectUuid = "subject_uuid"
        case payload
        case createdAt = "created_at"
    }

    public init(id: Int64, kind: String, subjectUuid: String? = nil, payload: String? = nil, createdAt: String) {
        self.id = id
        self.kind = kind
        self.subjectUuid = subjectUuid
        self.payload = payload
        self.createdAt = createdAt
    }
}

// MARK: - BACKUP

public struct BackupRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BackupResponse: Codable, Hashable, Sendable {
    public let backupPath: String
    public let sizeBytes: Int64

    private enum CodingKeys: String, CodingKey {
        case backupPath = "backup_path"
        case sizeBytes = "size_bytes"
    }

    public init(backupPath: String, sizeBytes: Int64) {
        self.backupPath = backupPath
        self.sizeBytes = sizeBytes
    }
}

// MARK: - Context blocks

/// Context blocks let the daemon lazily ensure the project → instance →
/// session chain exists. Where the ckfs already carries a uuid, the caller
/// passes it so the db row reuses it (trivial db ↔ ckfs joins). Optional
/// kbite_codes seed that level's active-kbite registry at CREATE time only —
/// mirroring detect_repo.sh's inherit_kbite (existing rows are never
/// re-seeded; a child created without codes copies its parent's junctions).

public struct ProjectContext: Codable, Hashable, Sendable {
    public let gitRepoName: String
    public let code: String
    public let name: String
    public let ckfsRelativeStoragePath: String
    public let uuid: String?
    public let kbiteCodes: [String]?

    private enum CodingKeys: String, CodingKey {
        case gitRepoName = "git_repo_name"
        case code
        case name
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
        case uuid
        case kbiteCodes = "kbite_codes"
    }

    public init(
        gitRepoName: String,
        code: String,
        name: String,
        ckfsRelativeStoragePath: String,
        uuid: String? = nil,
        kbiteCodes: [String]? = nil
    ) {
        self.gitRepoName = gitRepoName
        self.code = code
        self.name = name
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.uuid = uuid
        self.kbiteCodes = kbiteCodes
    }
}

public struct InstanceContext: Codable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let absoluteFileSystemPath: String
    public let ckfsRelativeStoragePath: String
    public let uuid: String?
    public let kbiteCodes: [String]?

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case absoluteFileSystemPath = "absolute_file_system_path"
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
        case uuid
        case kbiteCodes = "kbite_codes"
    }

    public init(
        code: String,
        name: String,
        absoluteFileSystemPath: String,
        ckfsRelativeStoragePath: String,
        uuid: String? = nil,
        kbiteCodes: [String]? = nil
    ) {
        self.code = code
        self.name = name
        self.absoluteFileSystemPath = absoluteFileSystemPath
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.uuid = uuid
        self.kbiteCodes = kbiteCodes
    }
}

public struct SessionContext: Codable, Hashable, Sendable {
    public let code: String
    public let name: String
    public let backstory: String
    public let goal: String
    public let ckfsRelativeStoragePath: String
    public let uuid: String?
    public let kbiteCodes: [String]?

    private enum CodingKeys: String, CodingKey {
        case code
        case name
        case backstory
        case goal
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
        case uuid
        case kbiteCodes = "kbite_codes"
    }

    public init(
        code: String,
        name: String,
        backstory: String = "",
        goal: String = "",
        ckfsRelativeStoragePath: String,
        uuid: String? = nil,
        kbiteCodes: [String]? = nil
    ) {
        self.code = code
        self.name = name
        self.backstory = backstory
        self.goal = goal
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.uuid = uuid
        self.kbiteCodes = kbiteCodes
    }
}

// MARK: - CONTEXT_ENSURE / CONTEXT_GET

public struct ContextEnsureRequest: Codable, Hashable, Sendable {
    public let project: ProjectContext
    public let instance: InstanceContext
    public let session: SessionContext

    public init(project: ProjectContext, instance: InstanceContext, session: SessionContext) {
        self.project = project
        self.instance = instance
        self.session = session
    }
}

public struct ContextEnsureResponse: Codable, Hashable, Sendable {
    public let projectUuid: String
    public let instanceUuid: String
    public let sessionUuid: String
    public let createdProject: Bool
    public let createdInstance: Bool
    public let createdSession: Bool

    private enum CodingKeys: String, CodingKey {
        case projectUuid = "project_uuid"
        case instanceUuid = "instance_uuid"
        case sessionUuid = "session_uuid"
        case createdProject = "created_project"
        case createdInstance = "created_instance"
        case createdSession = "created_session"
    }

    public init(
        projectUuid: String,
        instanceUuid: String,
        sessionUuid: String,
        createdProject: Bool,
        createdInstance: Bool,
        createdSession: Bool
    ) {
        self.projectUuid = projectUuid
        self.instanceUuid = instanceUuid
        self.sessionUuid = sessionUuid
        self.createdProject = createdProject
        self.createdInstance = createdInstance
        self.createdSession = createdSession
    }
}

/// Read-only resolution of the current gmcc environment — never creates rows.
public struct ContextGetRequest: Codable, Hashable, Sendable {
    public let projectCode: String
    public let instanceName: String
    public let sessionCode: String

    private enum CodingKeys: String, CodingKey {
        case projectCode = "project_code"
        case instanceName = "instance_name"
        case sessionCode = "session_code"
    }

    public init(projectCode: String, instanceName: String, sessionCode: String) {
        self.projectCode = projectCode
        self.instanceName = instanceName
        self.sessionCode = sessionCode
    }
}

public struct ContextGetResponse: Codable, Hashable, Sendable {
    public let projectUuid: String?
    public let instanceUuid: String?
    public let sessionUuid: String?
    /// Session-level active kbite codes, resolved from the junction table.
    public let kbiteCodes: [String]

    private enum CodingKeys: String, CodingKey {
        case projectUuid = "project_uuid"
        case instanceUuid = "instance_uuid"
        case sessionUuid = "session_uuid"
        case kbiteCodes = "kbite_codes"
    }

    public init(projectUuid: String?, instanceUuid: String?, sessionUuid: String?, kbiteCodes: [String]) {
        self.projectUuid = projectUuid
        self.instanceUuid = instanceUuid
        self.sessionUuid = sessionUuid
        self.kbiteCodes = kbiteCodes
    }
}

// MARK: - PROJECT_LIST / INSTANCE_LIST / SESSION_LIST

/// Enumerate all projects — the entry point of the Landing browse chain.
public struct ProjectListRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct ProjectListResponse: Codable, Hashable, Sendable {
    public let projects: [ProjectRow]

    public init(projects: [ProjectRow]) {
        self.projects = projects
    }
}

/// Enumerate instances. `projectUuid` is an optional filter — nil lists every
/// instance (rows carry their parent uuid); a supplied-but-unknown uuid is
/// NOT_FOUND, never a silent empty list.
public struct InstanceListRequest: Codable, Hashable, Sendable {
    public let projectUuid: String?

    private enum CodingKeys: String, CodingKey {
        case projectUuid = "project_uuid"
    }

    public init(projectUuid: String? = nil) {
        self.projectUuid = projectUuid
    }
}

public struct InstanceListResponse: Codable, Hashable, Sendable {
    public let instances: [InstanceRow]

    public init(instances: [InstanceRow]) {
        self.instances = instances
    }
}

/// Enumerate sessions. Same optional-filter contract as INSTANCE_LIST.
public struct SessionListRequest: Codable, Hashable, Sendable {
    public let instanceUuid: String?

    private enum CodingKeys: String, CodingKey {
        case instanceUuid = "instance_uuid"
    }

    public init(instanceUuid: String? = nil) {
        self.instanceUuid = instanceUuid
    }
}

public struct SessionListResponse: Codable, Hashable, Sendable {
    public let sessions: [SessionStub]

    public init(sessions: [SessionStub]) {
        self.sessions = sessions
    }
}

// MARK: - SESSION_GET / SESSION_UPDATE

public struct SessionGetRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String

    private enum CodingKeys: String, CodingKey {
        case sessionUuid = "session_uuid"
    }

    public init(sessionUuid: String) {
        self.sessionUuid = sessionUuid
    }
}

public struct SessionGetResponse: Codable, Hashable, Sendable {
    public let session: SessionRow
    public let prompts: [PromptStub]
    public let changeSummary: ChangeSummary
    /// Per-prompt change summaries (promptUuid nil = unattributed changes).
    /// Empty until file changes carry prompt attribution — run context is
    /// deferred from MVP, so entries may only appear via --prompt-uuid.
    public let promptChanges: [PromptChangeSummary]

    private enum CodingKeys: String, CodingKey {
        case session
        case prompts
        case changeSummary = "change_summary"
        case promptChanges = "prompt_changes"
    }

    public init(
        session: SessionRow,
        prompts: [PromptStub],
        changeSummary: ChangeSummary,
        promptChanges: [PromptChangeSummary]
    ) {
        self.session = session
        self.prompts = prompts
        self.changeSummary = changeSummary
        self.promptChanges = promptChanges
    }
}

/// Optimistic-concurrency guarded partial update of session-owned scalars.
/// nil fields are left unchanged.
public struct SessionUpdateRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String
    public let expectedVersion: Int64
    public let name: String?
    public let backstory: String?
    public let goal: String?
    public let status: SessionStatus?

    private enum CodingKeys: String, CodingKey {
        case sessionUuid = "session_uuid"
        case expectedVersion = "expected_version"
        case name
        case backstory
        case goal
        case status
    }

    public init(
        sessionUuid: String,
        expectedVersion: Int64,
        name: String? = nil,
        backstory: String? = nil,
        goal: String? = nil,
        status: SessionStatus? = nil
    ) {
        self.sessionUuid = sessionUuid
        self.expectedVersion = expectedVersion
        self.name = name
        self.backstory = backstory
        self.goal = goal
        self.status = status
    }
}

// MARK: - PROMPT_CREATE / PROMPT_LIST / PROMPT_GET

public struct PromptCreateRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String
    /// Optional ckfs uuid pass-through (db ↔ ckfs join bridge).
    public let uuid: String?
    /// Defaults to "p{seq}" when nil.
    public let code: String?
    public let name: String
    public let backstory: String
    public let goal: String
    public let detail: String
    public let command: String?
    public let ckfsRelativeStoragePath: String?

    private enum CodingKeys: String, CodingKey {
        case sessionUuid = "session_uuid"
        case uuid
        case code
        case name
        case backstory
        case goal
        case detail
        case command
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
    }

    public init(
        sessionUuid: String,
        uuid: String? = nil,
        code: String? = nil,
        name: String,
        backstory: String = "",
        goal: String = "",
        detail: String = "",
        command: String? = nil,
        ckfsRelativeStoragePath: String? = nil
    ) {
        self.sessionUuid = sessionUuid
        self.uuid = uuid
        self.code = code
        self.name = name
        self.backstory = backstory
        self.goal = goal
        self.detail = detail
        self.command = command
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
    }
}

public struct PromptListRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String

    private enum CodingKeys: String, CodingKey {
        case sessionUuid = "session_uuid"
    }

    public init(sessionUuid: String) {
        self.sessionUuid = sessionUuid
    }
}

public struct PromptListResponse: Codable, Hashable, Sendable {
    public let prompts: [PromptStub]

    public init(prompts: [PromptStub]) {
        self.prompts = prompts
    }
}

public struct PromptGetRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

    private enum CodingKeys: String, CodingKey {
        case promptUuid = "prompt_uuid"
    }

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

public struct PromptGetResponse: Codable, Hashable, Sendable {
    public let prompt: PromptRow
    public let artifacts: [ArtifactRow]
    public let kbiteCodes: [String]
    public let changeSummary: ChangeSummary

    private enum CodingKeys: String, CodingKey {
        case prompt
        case artifacts
        case kbiteCodes = "kbite_codes"
        case changeSummary = "change_summary"
    }

    public init(prompt: PromptRow, artifacts: [ArtifactRow], kbiteCodes: [String], changeSummary: ChangeSummary) {
        self.prompt = prompt
        self.artifacts = artifacts
        self.kbiteCodes = kbiteCodes
        self.changeSummary = changeSummary
    }
}

// MARK: - PROMPT_UPDATE_CONTENT / PROMPT_SET_STATUS

/// Draft-only edit of exactly the STAY TRUE triple (backstory/goal/detail).
/// The daemon rejects with CONTENT_LOCKED once the prompt leaves draft.
public struct PromptUpdateContentRequest: Codable, Hashable, Sendable {
    public let promptUuid: String
    public let expectedVersion: Int64
    public let backstory: String?
    public let goal: String?
    public let detail: String?

    private enum CodingKeys: String, CodingKey {
        case promptUuid = "prompt_uuid"
        case expectedVersion = "expected_version"
        case backstory
        case goal
        case detail
    }

    public init(
        promptUuid: String,
        expectedVersion: Int64,
        backstory: String? = nil,
        goal: String? = nil,
        detail: String? = nil
    ) {
        self.promptUuid = promptUuid
        self.expectedVersion = expectedVersion
        self.backstory = backstory
        self.goal = goal
        self.detail = detail
    }
}

public struct PromptSetStatusRequest: Codable, Hashable, Sendable {
    public let promptUuid: String
    public let expectedVersion: Int64
    public let status: PromptStatus

    private enum CodingKeys: String, CodingKey {
        case promptUuid = "prompt_uuid"
        case expectedVersion = "expected_version"
        case status
    }

    public init(promptUuid: String, expectedVersion: Int64, status: PromptStatus) {
        self.promptUuid = promptUuid
        self.expectedVersion = expectedVersion
        self.status = status
    }
}

// MARK: - ARTIFACT_ADD / ARTIFACT_LIST

/// Register a file pointer for a bot-phase memory/ file. Content stays in the
/// file; the daemon stores only the pointer.
public struct ArtifactAddRequest: Codable, Hashable, Sendable {
    public let promptUuid: String
    public let filePath: String
    public let kind: ArtifactKind
    public let note: String?

    private enum CodingKeys: String, CodingKey {
        case promptUuid = "prompt_uuid"
        case filePath = "file_path"
        case kind
        case note
    }

    public init(promptUuid: String, filePath: String, kind: ArtifactKind, note: String? = nil) {
        self.promptUuid = promptUuid
        self.filePath = filePath
        self.kind = kind
        self.note = note
    }
}

public struct ArtifactListRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

    private enum CodingKeys: String, CodingKey {
        case promptUuid = "prompt_uuid"
    }

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

public struct ArtifactListResponse: Codable, Hashable, Sendable {
    public let artifacts: [ArtifactRow]

    public init(artifacts: [ArtifactRow]) {
        self.artifacts = artifacts
    }
}

// MARK: - FILE_CHANGE_ADD

public struct ChangeRange: Codable, Hashable, Sendable {
    public let lineStart: Int
    public let lineEnd: Int
    public let changedContent: String?

    private enum CodingKeys: String, CodingKey {
        case lineStart = "line_start"
        case lineEnd = "line_end"
        case changedContent = "changed_content"
    }

    public init(lineStart: Int, lineEnd: Int, changedContent: String? = nil) {
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.changedContent = changedContent
    }
}

/// The primary high-frequency message. Carries full context blocks so the
/// ensure chain can run lazily — deliberately NOT slimmed to uuid addressing
/// this prompt (no call-order coupling for gm; revisit when the yamls and
/// their context source go away in prompt 2).
public struct FileChangeAdd: Codable, Hashable, Sendable {
    public let project: ProjectContext
    public let instance: InstanceContext
    public let session: SessionContext
    public let promptUuid: String?
    public let relativePath: String
    public let changeKind: ChangeKind
    public let ranges: [ChangeRange]

    private enum CodingKeys: String, CodingKey {
        case project
        case instance
        case session
        case promptUuid = "prompt_uuid"
        case relativePath = "relative_path"
        case changeKind = "change_kind"
        case ranges
    }

    public init(
        project: ProjectContext,
        instance: InstanceContext,
        session: SessionContext,
        promptUuid: String? = nil,
        relativePath: String,
        changeKind: ChangeKind,
        ranges: [ChangeRange]
    ) {
        self.project = project
        self.instance = instance
        self.session = session
        self.promptUuid = promptUuid
        self.relativePath = relativePath
        self.changeKind = changeKind
        self.ranges = ranges
    }
}

public struct FileChangeAddResponse: Codable, Hashable, Sendable {
    public let sessionFileUuid: String
    public let fileChangeUuid: String
    public let rangeUuids: [String]

    private enum CodingKeys: String, CodingKey {
        case sessionFileUuid = "session_file_uuid"
        case fileChangeUuid = "file_change_uuid"
        case rangeUuids = "range_uuids"
    }

    public init(sessionFileUuid: String, fileChangeUuid: String, rangeUuids: [String]) {
        self.sessionFileUuid = sessionFileUuid
        self.fileChangeUuid = fileChangeUuid
        self.rangeUuids = rangeUuids
    }
}

// MARK: - FILE_CHANGE_LIST

public struct FileChangeListRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String?
    public let promptUuid: String?
    public let relativePath: String?
    public let limit: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionUuid = "session_uuid"
        case promptUuid = "prompt_uuid"
        case relativePath = "relative_path"
        case limit
    }

    public init(sessionUuid: String? = nil, promptUuid: String? = nil, relativePath: String? = nil, limit: Int? = nil) {
        self.sessionUuid = sessionUuid
        self.promptUuid = promptUuid
        self.relativePath = relativePath
        self.limit = limit
    }
}

public struct FileChangeListResponse: Codable, Hashable, Sendable {
    public let changes: [FileChangeRow]

    public init(changes: [FileChangeRow]) {
        self.changes = changes
    }
}

// MARK: - KBITE_LIST / KBITE_ADD / KBITE_REMOVE

/// Registered kbites at a scope, resolved through the inheritance chain at
/// READ time (owner's own junction plus every ancestor's) — correct even for
/// kbites added after the child row was created. `all: true` ignores scope
/// and returns every kbite row in the db (the cleanup drift-check listing).
public struct KbiteListRequest: Codable, Hashable, Sendable {
    public let scope: KbiteScope
    public let ownerUuid: String
    public let all: Bool?

    private enum CodingKeys: String, CodingKey {
        case scope
        case ownerUuid = "owner_uuid"
        case all
    }

    public init(scope: KbiteScope, ownerUuid: String, all: Bool? = nil) {
        self.scope = scope
        self.ownerUuid = ownerUuid
        self.all = all
    }
}

public struct KbiteListResponse: Codable, Hashable, Sendable {
    public let kbites: [KbiteRef]

    public init(kbites: [KbiteRef]) {
        self.kbites = kbites
    }
}

/// Explicit-only registration (v11 inheritance model — never auto-added).
/// Db-only — the db is the sole kbite registry.
/// Idempotent; `added` is false when the junction already existed.
public struct KbiteAddRequest: Codable, Hashable, Sendable {
    public let scope: KbiteScope
    public let ownerUuid: String
    public let code: String

    private enum CodingKeys: String, CodingKey {
        case scope
        case ownerUuid = "owner_uuid"
        case code
    }

    public init(scope: KbiteScope, ownerUuid: String, code: String) {
        self.scope = scope
        self.ownerUuid = ownerUuid
        self.code = code
    }
}

public struct KbiteAddResponse: Codable, Hashable, Sendable {
    public let kbiteUuid: String
    public let code: String
    public let added: Bool

    private enum CodingKeys: String, CodingKey {
        case kbiteUuid = "kbite_uuid"
        case code
        case added
    }

    public init(kbiteUuid: String, code: String, added: Bool) {
        self.kbiteUuid = kbiteUuid
        self.code = code
        self.added = added
    }
}

public struct KbiteRemoveRequest: Codable, Hashable, Sendable {
    public let scope: KbiteScope
    public let ownerUuid: String
    public let code: String

    private enum CodingKeys: String, CodingKey {
        case scope
        case ownerUuid = "owner_uuid"
        case code
    }

    public init(scope: KbiteScope, ownerUuid: String, code: String) {
        self.scope = scope
        self.ownerUuid = ownerUuid
        self.code = code
    }
}

public struct KbiteRemoveResponse: Codable, Hashable, Sendable {
    public let removed: Bool

    public init(removed: Bool) {
        self.removed = removed
    }
}

// MARK: - KBITE_MAW_OPEN

/// Filesystem skeleton only — no db rows (maws are not tracked in the db).
/// The client resolves $GMCC_KBITE_OPEN and passes the absolute maw path; the
/// daemon never reads ckfs environment variables.
public struct KbiteMawOpenRequest: Codable, Hashable, Sendable {
    public let kbiteName: String
    public let mawPath: String

    private enum CodingKeys: String, CodingKey {
        case kbiteName = "kbite_name"
        case mawPath = "maw_path"
    }

    public init(kbiteName: String, mawPath: String) {
        self.kbiteName = kbiteName
        self.mawPath = mawPath
    }
}

public struct KbiteMawOpenResponse: Codable, Hashable, Sendable {
    public let mawPath: String
    public let createdDirs: [String]
    public let createdIndex: Bool

    private enum CodingKeys: String, CodingKey {
        case mawPath = "maw_path"
        case createdDirs = "created_dirs"
        case createdIndex = "created_index"
    }

    public init(mawPath: String, createdDirs: [String], createdIndex: Bool) {
        self.mawPath = mawPath
        self.createdDirs = createdDirs
        self.createdIndex = createdIndex
    }
}

// MARK: - KBITE_DIGEST

/// The one-step import: parse chewed artifacts under the open maw, write
/// kbite_resource / kbite_resource_file / keyword rows (db becomes canonical
/// for digested text), then delete the temporary chewed files — raw sources
/// stay on disk for re-chewing.
public struct KbiteDigestRequest: Codable, Hashable, Sendable {
    public let code: String
    public let kbiteOpenPath: String

    private enum CodingKeys: String, CodingKey {
        case code
        case kbiteOpenPath = "kbite_open_path"
    }

    public init(code: String, kbiteOpenPath: String) {
        self.code = code
        self.kbiteOpenPath = kbiteOpenPath
    }
}

public struct KbiteDigestResponse: Codable, Hashable, Sendable {
    public let kbiteUuid: String
    public let resourceCount: Int
    public let fileCount: Int
    public let keywordCount: Int
    public let deletedChewedFiles: [String]

    private enum CodingKeys: String, CodingKey {
        case kbiteUuid = "kbite_uuid"
        case resourceCount = "resource_count"
        case fileCount = "file_count"
        case keywordCount = "keyword_count"
        case deletedChewedFiles = "deleted_chewed_files"
    }

    public init(
        kbiteUuid: String,
        resourceCount: Int,
        fileCount: Int,
        keywordCount: Int,
        deletedChewedFiles: [String]
    ) {
        self.kbiteUuid = kbiteUuid
        self.resourceCount = resourceCount
        self.fileCount = fileCount
        self.keywordCount = keywordCount
        self.deletedChewedFiles = deletedChewedFiles
    }
}

// MARK: - KBITE_GET / KBITE_FILE_GET

public struct KbiteGetRequest: Codable, Hashable, Sendable {
    public let code: String

    public init(code: String) {
        self.code = code
    }
}

/// One kbite with its resources, file STUBS (names + summaries, never
/// content), and kbite-level keywords. Content loads go through
/// KBITE_FILE_GET one file at a time.
public struct KbiteGetResponse: Codable, Hashable, Sendable {
    public let kbite: KbiteRow
    public let resources: [KbiteResourceRow]
    public let keywords: [String]

    public init(kbite: KbiteRow, resources: [KbiteResourceRow], keywords: [String]) {
        self.kbite = kbite
        self.resources = resources
        self.keywords = keywords
    }
}

public struct KbiteFileGetRequest: Codable, Hashable, Sendable {
    public let fileUuid: String

    private enum CodingKeys: String, CodingKey {
        case fileUuid = "file_uuid"
    }

    public init(fileUuid: String) {
        self.fileUuid = fileUuid
    }
}

public struct KbiteFileGetResponse: Codable, Hashable, Sendable {
    public let file: KbiteResourceFileRow

    public init(file: KbiteResourceFileRow) {
        self.file = file
    }
}

// MARK: - KBITE_SEARCH

/// FTS5 full-text query across kbite resource files; ranked stubs, never
/// content. Empty/nil kbite_uuids searches everything.
public struct KbiteSearchRequest: Codable, Hashable, Sendable {
    public let query: String
    public let kbiteUuids: [String]?
    public let limit: Int?

    private enum CodingKeys: String, CodingKey {
        case query
        case kbiteUuids = "kbite_uuids"
        case limit
    }

    public init(query: String, kbiteUuids: [String]? = nil, limit: Int? = nil) {
        self.query = query
        self.kbiteUuids = kbiteUuids
        self.limit = limit
    }
}

public struct KbiteSearchResponse: Codable, Hashable, Sendable {
    public let hits: [KbiteSearchHit]

    public init(hits: [KbiteSearchHit]) {
        self.hits = hits
    }
}

// MARK: - CATALOG_SEARCH

/// Tokenized OR name/code search across instances + sessions, optionally
/// scoped to one project. Returns matched sessions plus every parent
/// instance needed to group them; the client orders by created/updated.
public struct CatalogSearchRequest: Codable, Hashable, Sendable {
    public let query: String
    public let projectUuid: String?
    public let limit: Int?

    private enum CodingKeys: String, CodingKey {
        case query
        case projectUuid = "project_uuid"
        case limit
    }

    public init(query: String, projectUuid: String? = nil, limit: Int? = nil) {
        self.query = query
        self.projectUuid = projectUuid
        self.limit = limit
    }
}

public struct CatalogSearchResponse: Codable, Hashable, Sendable {
    public let instances: [InstanceRow]
    public let sessions: [SessionStub]

    public init(instances: [InstanceRow], sessions: [SessionStub]) {
        self.instances = instances
        self.sessions = sessions
    }
}

// MARK: - KBITE_KEYWORD_TAG

/// Attach or detach normalized keywords at kbite level or resource-file
/// level. Keywords are upserted into the shared vocabulary on attach.
public struct KbiteKeywordTagRequest: Codable, Hashable, Sendable {
    public let level: KeywordTagLevel
    public let targetUuid: String
    public let keywords: [String]
    public let detach: Bool

    private enum CodingKeys: String, CodingKey {
        case level
        case targetUuid = "target_uuid"
        case keywords
        case detach
    }

    public init(level: KeywordTagLevel, targetUuid: String, keywords: [String], detach: Bool = false) {
        self.level = level
        self.targetUuid = targetUuid
        self.keywords = keywords
        self.detach = detach
    }
}

public struct KbiteKeywordTagResponse: Codable, Hashable, Sendable {
    public let attached: Int
    public let detached: Int

    public init(attached: Int, detached: Int) {
        self.attached = attached
        self.detached = detached
    }
}

// MARK: - EVENT_LIST

public struct EventListRequest: Codable, Hashable, Sendable {
    /// Raw kind string (forward compat — filters on the TEXT column).
    public let kind: String?
    public let subjectUuid: String?
    public let sinceId: Int64?
    /// ISO-8601 seconds-precision Z bounds; lexicographic comparison.
    public let sinceTime: String?
    public let untilTime: String?
    public let limit: Int?

    private enum CodingKeys: String, CodingKey {
        case kind
        case subjectUuid = "subject_uuid"
        case sinceId = "since_id"
        case sinceTime = "since_time"
        case untilTime = "until_time"
        case limit
    }

    public init(
        kind: String? = nil,
        subjectUuid: String? = nil,
        sinceId: Int64? = nil,
        sinceTime: String? = nil,
        untilTime: String? = nil,
        limit: Int? = nil
    ) {
        self.kind = kind
        self.subjectUuid = subjectUuid
        self.sinceId = sinceId
        self.sinceTime = sinceTime
        self.untilTime = untilTime
        self.limit = limit
    }
}

public struct EventListResponse: Codable, Hashable, Sendable {
    public let events: [EventNotification]

    public init(events: [EventNotification]) {
        self.events = events
    }
}
