import Foundation

/// Compiled-in wire-protocol version. Bump whenever the wire shape changes.
/// The handshake compares client and server values; mismatch handling is
/// DIRECTIONAL: a newer client makes the (stale) daemon self-exit so the
/// freshly built binary can take over, while an older client is merely
/// rejected — the daemon stays up (an old pinned-Kit GMVibes must never be
/// able to kill-loop a fresh daemon).
public enum GMCCWireProtocol {
    public static let version = 9
}

/// Discriminator for every NDJSON message on the socket. One case per spec
/// message; each request type has its own handler in gmcc_daemon.
public enum MessageType: String, Codable, Hashable, CaseIterable, Sendable {
    // Infra
    case hello = "HELLO"
    case ping = "PING"
    case status = "STATUS"
    case shutdown = "SHUTDOWN"
    case subscribe = "SUBSCRIBE"
    case backup = "BACKUP"
    // Context bootstrap
    case contextEnsure = "CONTEXT_ENSURE"
    case contextGet = "CONTEXT_GET"
    // Listing (enumeration — the Landing browse surface)
    case projectList = "PROJECT_LIST"
    case instanceList = "INSTANCE_LIST"
    case sessionList = "SESSION_LIST"
    // Session
    case sessionGet = "SESSION_GET"
    case sessionUpdate = "SESSION_UPDATE"
    // Prompts
    case promptCreate = "PROMPT_CREATE"
    case promptList = "PROMPT_LIST"
    case promptGet = "PROMPT_GET"
    case promptUpdateContent = "PROMPT_UPDATE_CONTENT"
    case promptSetStatus = "PROMPT_SET_STATUS"
    // Artifacts
    case artifactAdd = "ARTIFACT_ADD"
    case artifactList = "ARTIFACT_LIST"
    // File changes
    case fileChangeAdd = "FILE_CHANGE_ADD"
    case fileChangeList = "FILE_CHANGE_LIST"
    // Kbites
    case kbiteList = "KBITE_LIST"
    case kbiteAdd = "KBITE_ADD"
    case kbiteRemove = "KBITE_REMOVE"
    case kbiteMawOpen = "KBITE_MAW_OPEN"
    case kbiteDigest = "KBITE_DIGEST"
    case kbiteGet = "KBITE_GET"
    case kbiteFileGet = "KBITE_FILE_GET"
    case kbiteSearch = "KBITE_SEARCH"
    case kbiteKeywordTag = "KBITE_KEYWORD_TAG"
    // Catalog search (instances + sessions, the GMVibes search bar)
    case catalogSearch = "CATALOG_SEARCH"
    // Full-text search over prompt/clarification/architecture text (v8)
    case search = "SEARCH"
    // Clarification machine (v7)
    case clarifyOpen = "CLARIFY_OPEN"
    case clarifyAsk = "CLARIFY_ASK"
    case clarifySeal = "CLARIFY_SEAL"
    case clarifyAnswer = "CLARIFY_ANSWER"
    case clarifyReopen = "CLARIFY_REOPEN"
    case clarifyFinalize = "CLARIFY_FINALIZE"
    case clarifyGet = "CLARIFY_GET"
    // Architecture machine (v7)
    case archOpen = "ARCH_OPEN"
    case archSummarize = "ARCH_SUMMARIZE"
    case archPersistAdd = "ARCH_PERSIST_ADD"
    case archFieldAdd = "ARCH_FIELD_ADD"
    case archGeneralAdd = "ARCH_GENERAL_ADD"
    case archPropose = "ARCH_PROPOSE"
    case archApprove = "ARCH_APPROVE"
    case archRevise = "ARCH_REVISE"
    case archGet = "ARCH_GET"
    // Exploration report machine (v9)
    case exploreOpen = "EXPLORE_OPEN"
    case exploreKeyFileAdd = "EXPLORE_KEY_FILE_ADD"
    case exploreFindingAdd = "EXPLORE_FINDING_ADD"
    case exploreRank = "EXPLORE_RANK"
    case exploreComplete = "EXPLORE_COMPLETE"
    case exploreReopen = "EXPLORE_REOPEN"
    case exploreGet = "EXPLORE_GET"
    // Review report machine (v9)
    case reviewOpen = "REVIEW_OPEN"
    case reviewFindingAdd = "REVIEW_FINDING_ADD"
    case reviewRank = "REVIEW_RANK"
    case reviewResolve = "REVIEW_RESOLVE"
    case reviewComplete = "REVIEW_COMPLETE"
    case reviewReopen = "REVIEW_REOPEN"
    case reviewGet = "REVIEW_GET"
    // Git-state resolution (v7)
    case sessionResolve = "SESSION_RESOLVE"
    case instanceCurrentSession = "INSTANCE_CURRENT_SESSION"
    // Daemon config (v7)
    case pathsGet = "PATHS_GET"
    case configSet = "CONFIG_SET"
    // Audit
    case eventList = "EVENT_LIST"
    // Daemon → client only
    case event = "EVENT"
    case error = "ERROR"
}

/// Version-first pre-head: `type` stays a RAW STRING so the protocol-version
/// gate runs even for message names this build doesn't know. A newer client
/// invoking a newer-only message must get PROTOCOL_MISMATCH (+ directional
/// self-exit), not a decode failure — same forward-compat rule as
/// ErrorPayload.code and event kind. Narrow to MessageType only AFTER the
/// version check; unknown-but-version-matched names get UNKNOWN_TYPE echoing
/// the real request_id.
public struct RawEnvelopeHead: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let typeRaw: String
    public let requestId: String?

    public var type: MessageType? { MessageType(rawValue: typeRaw) }

    // The one intentional rename ("type" is a Swift keyword-adjacent name kept
    // raw for forward compat). Sibling keys MUST stay bare cases: an explicit
    // snake_case raw value stops matching under .convertFromSnakeCase and the
    // field silently decodes to nil. "type" has no underscore, so it is a
    // fixed point of both key strategies.
    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case typeRaw = "type"
        case requestId
    }

    public init(protocolVersion: Int, typeRaw: String, requestId: String?) {
        self.protocolVersion = protocolVersion
        self.typeRaw = typeRaw
        self.requestId = requestId
    }
}

/// The minimal prefix decodable from any incoming line — enough to route the
/// message and enforce the protocol-version handshake before the payload type
/// is known.
public struct EnvelopeHead: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let type: MessageType
    public let requestId: String

    public init(protocolVersion: Int, type: MessageType, requestId: String) {
        self.protocolVersion = protocolVersion
        self.type = type
        self.requestId = requestId
    }
}

/// Client → daemon message wrapper.
public struct RequestEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let type: MessageType
    public let requestId: String
    public let payload: Payload

    public init(type: MessageType, requestId: String = UUID().uuidString.lowercased(), payload: Payload) {
        self.protocolVersion = GMCCWireProtocol.version
        self.type = type
        self.requestId = requestId
        self.payload = payload
    }
}

/// Daemon → client message wrapper. `requestId` echoes the request (empty for
/// unsolicited event notifications).
public struct ResponseEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let protocolVersion: Int
    public let type: MessageType
    public let requestId: String
    public let ok: Bool
    public let payload: Payload?
    public let error: ErrorPayload?

    public init(
        type: MessageType,
        requestId: String,
        ok: Bool,
        payload: Payload? = nil,
        error: ErrorPayload? = nil
    ) {
        self.protocolVersion = GMCCWireProtocol.version
        self.type = type
        self.requestId = requestId
        self.ok = ok
        self.payload = payload
        self.error = error
    }
}

public enum ErrorCode: String, Codable, Hashable, CaseIterable, Sendable {
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case badRequest = "BAD_REQUEST"
    case unknownType = "UNKNOWN_TYPE"
    case dbError = "DB_ERROR"
    case internalError = "INTERNAL_ERROR"
    // Domain codes (StoreError → wire)
    case notFound = "NOT_FOUND"
    case versionConflict = "VERSION_CONFLICT"
    case invalidTransition = "INVALID_TRANSITION"
    case contentLocked = "CONTENT_LOCKED"
    /// The prompt exists but has no clarification/architecture/exploration/
    /// review summary. The payload's `promptIsLegacy` says which absence:
    /// true ⇒ pre-m0002 prompt, read the ckfs artifact; false ⇒ not opened
    /// yet (for exploration/review a pre-m0004 prompt may instead have an
    /// on-disk explore.md/review.md — the mandatory migrate pass moves those
    /// into rows). Plain NOT_FOUND now means only that the uuid itself is
    /// unknown.
    case summaryAbsent = "SUMMARY_ABSENT"
}

/// Error envelope. `code` travels as a RAW STRING so a daemon that grows new
/// codes can't make an older pinned-Kit client fail to decode the whole
/// envelope — clients switch on the typed accessor and fall through on nil.
public struct ErrorPayload: Codable, Hashable, Sendable {
    public let codeRaw: String
    public let message: String
    /// Set on PROTOCOL_MISMATCH so clients can be directional too: retry with
    /// autostart only when a freshly built binary would win.
    public let daemonProtocolVersion: Int?
    /// Set on SUMMARY_ABSENT: machine-readable answer to "is this prompt
    /// legacy?" so callers never parse the message text.
    public let promptIsLegacy: Bool?

    public var code: ErrorCode? { ErrorCode(rawValue: codeRaw) }

    // Same rule as RawEnvelopeHead: only the intentional rename is explicit,
    // every sibling stays a bare case ("daemon_protocol_version" as a raw
    // value would silently decode to nil under .convertFromSnakeCase — and
    // with it the client's directional PROTOCOL_MISMATCH retry).
    private enum CodingKeys: String, CodingKey {
        case codeRaw = "code"
        case message
        case daemonProtocolVersion
        case promptIsLegacy
    }

    public init(code: ErrorCode, message: String, daemonProtocolVersion: Int? = nil, promptIsLegacy: Bool? = nil) {
        self.codeRaw = code.rawValue
        self.message = message
        self.daemonProtocolVersion = daemonProtocolVersion
        self.promptIsLegacy = promptIsLegacy
    }
}

/// Payload type for responses that carry no data.
public struct EmptyPayload: Codable, Hashable, Sendable {
    public init() {}
}

/// NDJSON framing helpers: one JSON document per `\n`-terminated line.
/// Coders come from WireCodec — the snake_case key strategies are the wire's
/// entire casing contract now that types carry no CodingKeys.
public enum NDJSON {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try WireCodec.encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try WireCodec.decoder.decode(type, from: line)
    }
}
