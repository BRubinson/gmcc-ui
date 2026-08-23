import Foundation

// Codable wire payloads, one MARK section per message family. All types follow
// the swift.yeet_template.md lowering conventions: let-only structs,
// Codable/Hashable/Sendable floor, no force-unwraps. snake_case comes from
// WireCodec's key strategies — types declare NO CodingKeys (the two
// intentional renames live in Envelope.swift; see WireCodec for the rule).
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
    // v7 — new kinds travel as raw strings on the wire, so no version bump is
    // ever needed to add one.
    case clarificationChange = "CLARIFICATION_CHANGE"
    case architectureChange = "ARCHITECTURE_CHANGE"
    case configSet = "CONFIG_SET"
    /// Ephemeral broadcast only (id 0, never a daemon_event row, never a
    /// replay cursor) — emitted by MemoryWatcher when a prompt's memory/
    /// directory changes on disk.
    case promptMemoryChange = "PROMPT_MEMORY_CHANGED"
    /// Ephemeral broadcast only (id 0, never a daemon_event row, never a
    /// replay cursor) — emitted when an instance repo's HEAD changes on disk.
    /// Payload: {"instance_uuid", "head_state", "current_branch"|null,
    ///           "current_session_code"|null}; subject_uuid = the instance
    /// uuid. On reconnect ask INSTANCE_CURRENT_SESSION once rather than
    /// replaying.
    case checkoutChange = "CHECKOUT_CHANGE"
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

/// Prompt lifecycle v2. Transitions are forward-only and adjacent-only, with
/// exactly one skip edge (reviewing is optional):
/// draft → clarifying → architecting → implementing → reviewing → done
///                                          └───────── skip ───────↗
/// Legacy note: the old terminal `clarified` was mapped to `done` by m0002.
public enum PromptStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case draft
    case clarifying
    case architecting
    case implementing
    case reviewing
    case done

    /// The legal next states as an explicit set, so the one skip edge is
    /// stated rather than hidden in a permissive switch. Gate coupling
    /// (backing summary requirements) lives in Store.setPromptStatus.
    public var allowedNext: Set<PromptStatus> {
        switch self {
        case .draft: return [.clarifying]
        case .clarifying: return [.architecting]
        case .architecting: return [.implementing]
        case .implementing: return [.reviewing, .done]
        case .reviewing: return [.done]
        case .done: return []
        }
    }
}

/// Clarification summary lifecycle: building → answering → complete, with one
/// backward revision edge (complete → answering, the `reopen` verb) so an
/// answer discovered wrong during architecting stays fixable db-natively.
public enum ClarificationStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case building
    case answering
    case complete

    public var allowedNext: Set<ClarificationStatus> {
        switch self {
        case .building: return [.answering]
        case .answering: return [.complete]
        case .complete: return [.answering]
        }
    }
}

/// Which qualified-prompt section a clarification row belongs to.
public enum ClarificationCategory: String, Codable, Hashable, CaseIterable, Sendable {
    case goal
    case detail
    case yeetType = "yeet_type"
}

/// Who answered a clarification: the human, or the bot resolving confidently
/// (a yeet_type detection lands pre-answered as bot_inferred).
public enum AnswerSource: String, Codable, Hashable, CaseIterable, Sendable {
    case user
    case botInferred = "bot_inferred"
}

/// One clarification row's answer state.
public enum ClarificationRowStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case open
    case answered
    case skipped
}

/// Architecture summary lifecycle: drafting → proposed → approved, with one
/// backward revision edge (proposed → drafting, the `revise` verb). approved
/// is terminal and unlocks the prompt's architecting → implementing gate.
public enum ArchitectureStatus: String, Codable, Hashable, CaseIterable, Sendable {
    case drafting
    case proposed
    case approved

    public var allowedNext: Set<ArchitectureStatus> {
        switch self {
        case .drafting: return [.proposed]
        case .proposed: return [.approved, .drafting]
        case .approved: return []
        }
    }
}

/// Fidelity of an architecture_general_change's change_code: sketch-level
/// pseudo code, near-code draft, or drop-in actual code.
public enum ChangeDepth: String, Codable, Hashable, CaseIterable, Sendable {
    case pseudo
    case draft
    case actual
}

/// The daemon_config key space is enum-bound — an unknown key is BAD_REQUEST,
/// keeping config a typed subsystem rather than a free-form bag.
public enum ConfigKey: String, Codable, Hashable, CaseIterable, Sendable {
    case ckfsRoot = "ckfs_root"
    case kbiteRoot = "kbite_root"
    case kbiteOpenRoot = "kbite_open_root"
    case kbiteDigestedRoot = "kbite_digested_root"
}

/// Column-only since v7: session.status was retired from the wire (every live
/// row read 'active' forever; checked-out state is git-derived via
/// SESSION_RESOLVE). The enum documents the column's legal values.
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

    public init(clientName: String, pid: Int32) {
        self.clientName = clientName
        self.pid = pid
    }
}

public struct HelloAck: Codable, Hashable, Sendable {
    public let daemonPid: Int32
    public let protocolVersion: Int

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

/// One table's row count. An array of pairs rather than [String: Int] because
/// the coder key strategies rewrite dictionary String keys ("prompt_artifact"
/// would decode as "promptArtifact"); an array is immune and stays sorted.
public struct TableCount: Codable, Hashable, Sendable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct StatusResponse: Codable, Hashable, Sendable {
    public let daemonPid: Int32
    public let protocolVersion: Int
    public let socketPath: String
    public let dbPath: String
    public let schemaVersion: Int
    /// Row census only — MUST NOT be used as an event cursor; use
    /// `lastEventId` for that.
    public let tableCounts: [TableCount]
    /// The real event-log horizon: highest daemon_event.id at status time.
    public let lastEventId: Int64
    public let startedAt: String
    public let uptimeSeconds: Int

    public init(
        daemonPid: Int32,
        protocolVersion: Int,
        socketPath: String,
        dbPath: String,
        schemaVersion: Int,
        tableCounts: [TableCount],
        lastEventId: Int64,
        startedAt: String,
        uptimeSeconds: Int
    ) {
        self.daemonPid = daemonPid
        self.protocolVersion = protocolVersion
        self.socketPath = socketPath
        self.dbPath = dbPath
        self.schemaVersion = schemaVersion
        self.tableCounts = tableCounts
        self.lastEventId = lastEventId
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

    public init(sinceId: Int64? = nil) {
        self.sinceId = sinceId
    }
}

public struct SubscribeAck: Codable, Hashable, Sendable {
    /// The replay horizon: highest daemon_event.id at subscribe time. Replayed
    /// EVENT lines (ids ≤ this) follow the ack, then live events stream.
    public let lastEventId: Int64
    public let replayCount: Int

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

    public init(
        sessionUuid: String,
        expectedVersion: Int64,
        name: String? = nil,
        backstory: String? = nil,
        goal: String? = nil
    ) {
        self.sessionUuid = sessionUuid
        self.expectedVersion = expectedVersion
        self.name = name
        self.backstory = backstory
        self.goal = goal
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

/// `sessionUuid` is an optional filter (same contract as INSTANCE_LIST /
/// SESSION_LIST): nil lists every prompt in the db (stubs carry their parent
/// session uuid); a supplied-but-unknown uuid is NOT_FOUND, never a silent
/// empty list.
public struct PromptListRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String?
    /// When true each stub carries its `reports` enrichment block (one call
    /// replaces the per-prompt CLARIFY_GET/ARCH_GET fan-out). Optional so a
    /// v8 client omitting it decodes as false.
    public let withReports: Bool?

    public init(sessionUuid: String? = nil, withReports: Bool? = nil) {
        self.sessionUuid = sessionUuid
        self.withReports = withReports
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

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

public struct PromptGetResponse: Codable, Hashable, Sendable {
    public let prompt: PromptRow
    public let artifacts: [ArtifactRow]
    public let kbiteCodes: [String]
    public let changeSummary: ChangeSummary

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

    public init(promptUuid: String, filePath: String, kind: ArtifactKind, note: String? = nil) {
        self.promptUuid = promptUuid
        self.filePath = filePath
        self.kind = kind
        self.note = note
    }
}

public struct ArtifactListRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

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

    public init(kbiteName: String, mawPath: String) {
        self.kbiteName = kbiteName
        self.mawPath = mawPath
    }
}

public struct KbiteMawOpenResponse: Codable, Hashable, Sendable {
    public let mawPath: String
    public let createdDirs: [String]
    public let createdIndex: Bool

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

// MARK: - SEARCH

/// The six searchable row kinds. Raw values match the source table names.
public enum SearchKind: String, Codable, Hashable, CaseIterable, Sendable {
    case prompt
    case clarification
    case clarificationSummary = "clarification_summary"
    case architectureSummary = "architecture_summary"
    case architectureGeneralChange = "architecture_general_change"
    case architecturePersistenceChange = "architecture_persistence_change"
}

/// FTS5 full-text search over prompt/clarification/architecture text —
/// ranked stubs with prompt lineage, never full content (the SEARCH
/// counterpart of KBITE_SEARCH). nil sessionUuid = whole db; a
/// supplied-but-unknown uuid is NOT_FOUND, never a silent empty list.
/// A query with no searchable tokens is BAD_REQUEST.
public struct SearchRequest: Codable, Hashable, Sendable {
    public let query: String
    public let sessionUuid: String?
    /// nil/empty = every kind.
    public let kinds: [SearchKind]?
    /// Clamped 1…500, default 50.
    public let limit: Int?

    public init(query: String, sessionUuid: String? = nil, kinds: [SearchKind]? = nil, limit: Int? = nil) {
        self.query = query
        self.sessionUuid = sessionUuid
        self.kinds = kinds
        self.limit = limit
    }
}

public struct SearchResponse: Codable, Hashable, Sendable {
    public let hits: [SearchHit]

    public init(hits: [SearchHit]) {
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

// MARK: - CLARIFY_* (v7)

public struct ClarifyOpenRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

/// Shared response for clarify verbs that return the summary row. `created`
/// is true only when OPEN made the row (open is idempotent create-or-return
/// and never transitions the prompt).
public struct ClarifySummaryResponse: Codable, Hashable, Sendable {
    public let summary: ClarificationSummaryRow
    public let created: Bool

    public init(summary: ClarificationSummaryRow, created: Bool = false) {
        self.summary = summary
        self.created = created
    }
}

/// Insert a question while the summary is `building`. A confidently-resolved
/// detection may land pre-answered by passing answer + source bot_inferred.
public struct ClarifyAskRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let category: ClarificationCategory
    public let question: String
    public let answer: String?
    public let answerSource: AnswerSource?

    public init(
        summaryUuid: String,
        category: ClarificationCategory,
        question: String,
        answer: String? = nil,
        answerSource: AnswerSource? = nil
    ) {
        self.summaryUuid = summaryUuid
        self.category = category
        self.question = question
        self.answer = answer
        self.answerSource = answerSource
    }
}

public struct ClarificationRowResponse: Codable, Hashable, Sendable {
    public let clarification: ClarificationRow

    public init(clarification: ClarificationRow) {
        self.clarification = clarification
    }
}

/// building → answering: locks the question list.
public struct ClarifySealRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64

    public init(summaryUuid: String, expectedVersion: Int64) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
    }
}

/// Answer one clarification row (summary must be `answering`). Revives a
/// skipped row. Pure row update — never touches the summary's version.
/// expectedVersion targets the CLARIFICATION row. skip=true marks the row
/// skipped instead of answered.
public struct ClarifyAnswerRequest: Codable, Hashable, Sendable {
    public let clarificationUuid: String
    public let expectedVersion: Int64
    public let answer: String?
    public let answerSource: AnswerSource?
    public let skip: Bool

    public init(
        clarificationUuid: String,
        expectedVersion: Int64,
        answer: String? = nil,
        answerSource: AnswerSource? = nil,
        skip: Bool = false
    ) {
        self.clarificationUuid = clarificationUuid
        self.expectedVersion = expectedVersion
        self.answer = answer
        self.answerSource = answerSource
        self.skip = skip
    }
}

/// complete → answering: the revision edge, as its own verb so `answer` stays
/// a pure row update (its expected_version targets a child row, not the summary).
public struct ClarifyReopenRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64

    public init(summaryUuid: String, expectedVersion: Int64) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
    }
}

/// answering → complete. Requires every non-skipped question answered and both
/// refined fields non-empty; copies refined_goal into prompt.goal (the one
/// daemon-synthesized write exempt from CONTENT_LOCKED — human edits stay
/// draft-only).
public struct ClarifyFinalizeRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64
    public let refinedGoal: String
    public let refinedDetail: String
    public let backstoryNote: String?

    public init(
        summaryUuid: String,
        expectedVersion: Int64,
        refinedGoal: String,
        refinedDetail: String,
        backstoryNote: String? = nil
    ) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
        self.refinedGoal = refinedGoal
        self.refinedDetail = refinedDetail
        self.backstoryNote = backstoryNote
    }
}

public struct ClarifyFinalizeResponse: Codable, Hashable, Sendable {
    public let summary: ClarificationSummaryRow
    public let prompt: PromptRow

    public init(summary: ClarificationSummaryRow, prompt: PromptRow) {
        self.summary = summary
        self.prompt = prompt
    }
}

public struct ClarifyGetRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

public struct ClarifyGetResponse: Codable, Hashable, Sendable {
    public let summary: ClarificationSummaryRow
    public let clarifications: [ClarificationRow]

    public init(summary: ClarificationSummaryRow, clarifications: [ClarificationRow]) {
        self.summary = summary
        self.clarifications = clarifications
    }
}

// MARK: - ARCH_* (v7)

public struct ArchOpenRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

public struct ArchSummaryResponse: Codable, Hashable, Sendable {
    public let summary: ArchitectureSummaryRow
    public let created: Bool

    public init(summary: ArchitectureSummaryRow, created: Bool = false) {
        self.summary = summary
        self.created = created
    }
}

/// Set the concept-level body (approach, components, data flow, tradeoffs —
/// never specific file changes; those are the normalized change rows).
public struct ArchSummarizeRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64
    public let body: String

    public init(summaryUuid: String, expectedVersion: Int64, body: String) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
        self.body = body
    }
}

public struct ArchPersistAddRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let className: String
    public let filePath: String
    public let reasonBrief: String

    public init(summaryUuid: String, className: String, filePath: String, reasonBrief: String) {
        self.summaryUuid = summaryUuid
        self.className = className
        self.filePath = filePath
        self.reasonBrief = reasonBrief
    }
}

public struct ArchPersistAddResponse: Codable, Hashable, Sendable {
    public let change: ArchPersistenceChangeRow

    public init(change: ArchPersistenceChangeRow) {
        self.change = change
    }
}

public struct ArchFieldAddRequest: Codable, Hashable, Sendable {
    public let persistenceChangeUuid: String
    public let fieldName: String
    public let dataType: String
    public let changeReason: String
    public let changePurpose: String
    public let nullable: Bool
    public let isForeignKey: Bool
    public let fkTarget: String?
    public let isIndexed: Bool

    public init(
        persistenceChangeUuid: String,
        fieldName: String,
        dataType: String,
        changeReason: String,
        changePurpose: String,
        nullable: Bool,
        isForeignKey: Bool = false,
        fkTarget: String? = nil,
        isIndexed: Bool = false
    ) {
        self.persistenceChangeUuid = persistenceChangeUuid
        self.fieldName = fieldName
        self.dataType = dataType
        self.changeReason = changeReason
        self.changePurpose = changePurpose
        self.nullable = nullable
        self.isForeignKey = isForeignKey
        self.fkTarget = fkTarget
        self.isIndexed = isIndexed
    }
}

public struct ArchFieldAddResponse: Codable, Hashable, Sendable {
    public let field: ArchPersistenceFieldChangeRow

    public init(field: ArchPersistenceFieldChangeRow) {
        self.field = field
    }
}

public struct ArchGeneralAddRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let filePath: String
    public let className: String?
    public let reasonBrief: String
    public let changeDepth: ChangeDepth
    public let changeCode: String

    public init(
        summaryUuid: String,
        filePath: String,
        className: String? = nil,
        reasonBrief: String,
        changeDepth: ChangeDepth,
        changeCode: String
    ) {
        self.summaryUuid = summaryUuid
        self.filePath = filePath
        self.className = className
        self.reasonBrief = reasonBrief
        self.changeDepth = changeDepth
        self.changeCode = changeCode
    }
}

public struct ArchGeneralAddResponse: Codable, Hashable, Sendable {
    public let change: ArchGeneralChangeRow

    public init(change: ArchGeneralChangeRow) {
        self.change = change
    }
}

/// drafting → proposed (seals change rows for review).
public struct ArchProposeRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64

    public init(summaryUuid: String, expectedVersion: Int64) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
    }
}

/// proposed → approved (terminal; unlocks architecting → implementing).
public struct ArchApproveRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64

    public init(summaryUuid: String, expectedVersion: Int64) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
    }
}

/// proposed → drafting (the revision edge).
public struct ArchReviseRequest: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let expectedVersion: Int64

    public init(summaryUuid: String, expectedVersion: Int64) {
        self.summaryUuid = summaryUuid
        self.expectedVersion = expectedVersion
    }
}

public struct ArchGetRequest: Codable, Hashable, Sendable {
    public let promptUuid: String

    public init(promptUuid: String) {
        self.promptUuid = promptUuid
    }
}

/// The architecture with derived implementation state: persistence changes
/// always ordered before general changes (the persistence-first contract),
/// each decorated with its file_change join; unplanned_changes is the touched-
/// but-not-planned set. ordering_respected audits persistence-first execution
/// (nil when either side is empty or untouched). Join is path-level on
/// daemon-normalized repo-relative paths; file changes without a prompt_uuid
/// are invisible to it — always pass --prompt-uuid when recording.
public struct ArchGetResponse: Codable, Hashable, Sendable {
    public let summary: ArchitectureSummaryRow
    public let persistenceChanges: [ArchPersistenceChangeRow]
    public let generalChanges: [ArchGeneralChangeRow]
    public let unplannedChanges: [UnplannedChangeRow]
    public let orderingRespected: Bool?

    public init(
        summary: ArchitectureSummaryRow,
        persistenceChanges: [ArchPersistenceChangeRow],
        generalChanges: [ArchGeneralChangeRow],
        unplannedChanges: [UnplannedChangeRow],
        orderingRespected: Bool?
    ) {
        self.summary = summary
        self.persistenceChanges = persistenceChanges
        self.generalChanges = generalChanges
        self.unplannedChanges = unplannedChanges
        self.orderingRespected = orderingRespected
    }
}

// MARK: - SESSION_RESOLVE / INSTANCE_CURRENT_SESSION (v7)

/// Git-derived checked-out state for one session. head_state is one of
/// "branch", "detached", "unavailable" (missing/unreadable instance path —
/// tolerated, never an error).
public struct SessionResolveRequest: Codable, Hashable, Sendable {
    public let sessionUuid: String

    public init(sessionUuid: String) {
        self.sessionUuid = sessionUuid
    }
}

public struct SessionResolveResponse: Codable, Hashable, Sendable {
    public let session: SessionRow
    public let checkedOut: Bool
    public let headState: String
    /// The slugged code of whatever IS checked out (nil when detached or
    /// unavailable). Slugging is forward-only: branch / → __, never unslugged.
    public let currentSessionCode: String?
    /// The RAW branch name (nil whenever head_state != "branch"). The code
    /// stays slugged; the two are never interconverted client-side.
    public let currentBranch: String?

    public init(session: SessionRow, checkedOut: Bool, headState: String, currentSessionCode: String?, currentBranch: String?) {
        self.session = session
        self.checkedOut = checkedOut
        self.headState = headState
        self.currentSessionCode = currentSessionCode
        self.currentBranch = currentBranch
    }
}

public struct InstanceCurrentSessionRequest: Codable, Hashable, Sendable {
    public let instanceUuid: String

    public init(instanceUuid: String) {
        self.instanceUuid = instanceUuid
    }
}

/// session is nil when detached, unavailable, or the checked-out branch has
/// no session row yet.
public struct InstanceCurrentSessionResponse: Codable, Hashable, Sendable {
    public let session: SessionStub?
    public let headState: String
    public let currentSessionCode: String?
    /// The RAW branch name (nil whenever head_state != "branch").
    public let currentBranch: String?

    public init(session: SessionStub?, headState: String, currentSessionCode: String?, currentBranch: String?) {
        self.session = session
        self.headState = headState
        self.currentSessionCode = currentSessionCode
        self.currentBranch = currentBranch
    }
}

// MARK: - PATHS_GET / CONFIG_SET (v7)

public struct PathsGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

/// Typed roots (never a map — dictionary keys and coder key strategies don't
/// mix). gmcc/db/socket/backups come from Paths; the ckfs and kbite roots
/// from daemon_config (seeded defaults, settable via CONFIG_SET). Retires
/// client-side ~/.zshrc scraping.
public struct PathsGetResponse: Codable, Hashable, Sendable {
    public let gmccRoot: String
    public let dbPath: String
    public let socketPath: String
    public let backupsRoot: String
    public let ckfsRoot: String
    public let kbiteRoot: String
    public let kbiteOpenRoot: String
    public let kbiteDigestedRoot: String

    public init(
        gmccRoot: String,
        dbPath: String,
        socketPath: String,
        backupsRoot: String,
        ckfsRoot: String,
        kbiteRoot: String,
        kbiteOpenRoot: String,
        kbiteDigestedRoot: String
    ) {
        self.gmccRoot = gmccRoot
        self.dbPath = dbPath
        self.socketPath = socketPath
        self.backupsRoot = backupsRoot
        self.ckfsRoot = ckfsRoot
        self.kbiteRoot = kbiteRoot
        self.kbiteOpenRoot = kbiteOpenRoot
        self.kbiteDigestedRoot = kbiteDigestedRoot
    }
}

public struct ConfigSetRequest: Codable, Hashable, Sendable {
    public let key: ConfigKey
    public let value: String

    public init(key: ConfigKey, value: String) {
        self.key = key
        self.value = value
    }
}

public struct ConfigSetResponse: Codable, Hashable, Sendable {
    public let key: ConfigKey
    public let value: String

    public init(key: ConfigKey, value: String) {
        self.key = key
        self.value = value
    }
}
