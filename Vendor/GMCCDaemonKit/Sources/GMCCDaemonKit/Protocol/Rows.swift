import Foundation

// Typed read-side DTOs — the row shapes GMVibes renders from and gm prints.
// Same lowering conventions as Messages.swift.

// MARK: - Project

public struct ProjectRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let gitRepoName: String
    public let code: String
    public let name: String
    public let ckfsRelativeStoragePath: String
    public let createdAt: String
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case uuid
        case version
        case gitRepoName = "git_repo_name"
        case code
        case name
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        uuid: String,
        version: Int64,
        gitRepoName: String,
        code: String,
        name: String,
        ckfsRelativeStoragePath: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.gitRepoName = gitRepoName
        self.code = code
        self.name = name
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Instance

public struct InstanceRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let projectUuid: String
    public let code: String
    public let name: String
    public let absoluteFileSystemPath: String
    public let ckfsRelativeStoragePath: String
    public let createdAt: String
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case uuid
        case version
        case projectUuid = "project_uuid"
        case code
        case name
        case absoluteFileSystemPath = "absolute_file_system_path"
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        uuid: String,
        version: Int64,
        projectUuid: String,
        code: String,
        name: String,
        absoluteFileSystemPath: String,
        ckfsRelativeStoragePath: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.projectUuid = projectUuid
        self.code = code
        self.name = name
        self.absoluteFileSystemPath = absoluteFileSystemPath
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Session

/// Session listing shape — full scalars minus the backstory/goal prose
/// bodies, which stay behind SESSION_GET.
public struct SessionStub: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let instanceUuid: String
    public let code: String
    public let name: String
    public let status: String
    public let ckfsRelativeStoragePath: String
    public let createdAt: String
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case uuid
        case version
        case instanceUuid = "instance_uuid"
        case code
        case name
        case status
        case ckfsRelativeStoragePath = "ckfs_relative_storage_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        uuid: String,
        version: Int64,
        instanceUuid: String,
        code: String,
        name: String,
        status: String,
        ckfsRelativeStoragePath: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.instanceUuid = instanceUuid
        self.code = code
        self.name = name
        self.status = status
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SessionRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let code: String
    public let name: String
    public let backstory: String
    public let goal: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case uuid
        case version
        case code
        case name
        case backstory
        case goal
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        uuid: String,
        version: Int64,
        code: String,
        name: String,
        backstory: String,
        goal: String,
        status: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.code = code
        self.name = name
        self.backstory = backstory
        self.goal = goal
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Prompt

public struct PromptRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let sessionUuid: String
    public let seq: Int64
    public let code: String
    public let name: String
    public let backstory: String
    public let goal: String
    public let detail: String
    public let command: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String

    public var promptStatus: PromptStatus? { PromptStatus(rawValue: status) }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case version
        case sessionUuid = "session_uuid"
        case seq
        case code
        case name
        case backstory
        case goal
        case detail
        case command
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        uuid: String,
        version: Int64,
        sessionUuid: String,
        seq: Int64,
        code: String,
        name: String,
        backstory: String,
        goal: String,
        detail: String,
        command: String,
        status: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.sessionUuid = sessionUuid
        self.seq = seq
        self.code = code
        self.name = name
        self.backstory = backstory
        self.goal = goal
        self.detail = detail
        self.command = command
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Lightweight prompt listing shape (replaces reading the session_data
/// prompts: list).
public struct PromptStub: Codable, Hashable, Sendable {
    public let uuid: String
    public let seq: Int64
    public let code: String
    public let name: String
    public let status: String
    public let version: Int64

    public init(uuid: String, seq: Int64, code: String, name: String, status: String, version: Int64) {
        self.uuid = uuid
        self.seq = seq
        self.code = code
        self.name = name
        self.status = status
        self.version = version
    }
}

// MARK: - Artifact

public struct ArtifactRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let promptUuid: String
    public let filePath: String
    public let kind: String
    public let note: String?
    public let createdAt: String

    public var artifactKind: ArtifactKind? { ArtifactKind(rawValue: kind) }

    private enum CodingKeys: String, CodingKey {
        case uuid
        case promptUuid = "prompt_uuid"
        case filePath = "file_path"
        case kind
        case note
        case createdAt = "created_at"
    }

    public init(uuid: String, promptUuid: String, filePath: String, kind: String, note: String?, createdAt: String) {
        self.uuid = uuid
        self.promptUuid = promptUuid
        self.filePath = filePath
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
    }
}

// MARK: - File change

public struct ChangeRangeRow: Codable, Hashable, Sendable {
    public let lineStart: Int
    public let lineEnd: Int

    private enum CodingKeys: String, CodingKey {
        case lineStart = "line_start"
        case lineEnd = "line_end"
    }

    public init(lineStart: Int, lineEnd: Int) {
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}

public struct FileChangeRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let sessionUuid: String
    public let promptUuid: String?
    public let relativePath: String
    public let changeKind: String
    public let createdAt: String
    public let ranges: [ChangeRangeRow]

    private enum CodingKeys: String, CodingKey {
        case uuid
        case sessionUuid = "session_uuid"
        case promptUuid = "prompt_uuid"
        case relativePath = "relative_path"
        case changeKind = "change_kind"
        case createdAt = "created_at"
        case ranges
    }

    public init(
        uuid: String,
        sessionUuid: String,
        promptUuid: String?,
        relativePath: String,
        changeKind: String,
        createdAt: String,
        ranges: [ChangeRangeRow]
    ) {
        self.uuid = uuid
        self.sessionUuid = sessionUuid
        self.promptUuid = promptUuid
        self.relativePath = relativePath
        self.changeKind = changeKind
        self.createdAt = createdAt
        self.ranges = ranges
    }
}

// MARK: - Kbite

/// Minimal kbite handle for registry listings.
public struct KbiteRef: Codable, Hashable, Sendable {
    public let uuid: String
    public let code: String

    public init(uuid: String, code: String) {
        self.uuid = uuid
        self.code = code
    }
}

public struct KbiteRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let code: String
    public let createdAt: String
    public let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case uuid
        case version
        case code
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(uuid: String, version: Int64, code: String, createdAt: String, updatedAt: String) {
        self.uuid = uuid
        self.version = version
        self.code = code
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A consumed source within a kbite, carrying its file stubs. resource_summary
/// is the full chewed analysis body — the per-resource synthesis.
public struct KbiteResourceRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let kbiteUuid: String
    public let resourceName: String
    public let resourceSummary: String
    public let resourceType: String
    public let resourceTrust: Int
    public let files: [KbiteResourceFileStub]

    private enum CodingKeys: String, CodingKey {
        case uuid
        case kbiteUuid = "kbite_uuid"
        case resourceName = "resource_name"
        case resourceSummary = "resource_summary"
        case resourceType = "resource_type"
        case resourceTrust = "resource_trust"
        case files
    }

    public init(
        uuid: String,
        kbiteUuid: String,
        resourceName: String,
        resourceSummary: String,
        resourceType: String,
        resourceTrust: Int,
        files: [KbiteResourceFileStub]
    ) {
        self.uuid = uuid
        self.kbiteUuid = kbiteUuid
        self.resourceName = resourceName
        self.resourceSummary = resourceSummary
        self.resourceType = resourceType
        self.resourceTrust = resourceTrust
        self.files = files
    }
}

/// File listing shape — name + summary only; content stays behind
/// KBITE_FILE_GET (the targeted load).
public struct KbiteResourceFileStub: Codable, Hashable, Sendable {
    public let uuid: String
    public let resourceFileName: String
    public let resourceFileSummary: String
    public let hasContent: Bool

    private enum CodingKeys: String, CodingKey {
        case uuid
        case resourceFileName = "resource_file_name"
        case resourceFileSummary = "resource_file_summary"
        case hasContent = "has_content"
    }

    public init(uuid: String, resourceFileName: String, resourceFileSummary: String, hasContent: Bool) {
        self.uuid = uuid
        self.resourceFileName = resourceFileName
        self.resourceFileSummary = resourceFileSummary
        self.hasContent = hasContent
    }
}

/// Full file row including content (nil for images/binaries the filesystem
/// keeps raw).
public struct KbiteResourceFileRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let kbiteResourceUuid: String
    public let resourceFileName: String
    public let resourceFileSummary: String
    public let resourceFileContent: String?
    public let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case uuid
        case kbiteResourceUuid = "kbite_resource_uuid"
        case resourceFileName = "resource_file_name"
        case resourceFileSummary = "resource_file_summary"
        case resourceFileContent = "resource_file_content"
        case createdAt = "created_at"
    }

    public init(
        uuid: String,
        kbiteResourceUuid: String,
        resourceFileName: String,
        resourceFileSummary: String,
        resourceFileContent: String?,
        createdAt: String
    ) {
        self.uuid = uuid
        self.kbiteResourceUuid = kbiteResourceUuid
        self.resourceFileName = resourceFileName
        self.resourceFileSummary = resourceFileSummary
        self.resourceFileContent = resourceFileContent
        self.createdAt = createdAt
    }
}

/// One KBITE_SEARCH result: file-level stub with its kbite/resource lineage,
/// bm25 score (smaller = more relevant), and the file's attached keywords.
public struct KbiteSearchHit: Codable, Hashable, Sendable {
    public let kbiteCode: String
    public let kbiteUuid: String
    public let resourceName: String
    public let fileUuid: String
    public let fileName: String
    public let fileSummary: String
    public let matchedKeywords: [String]
    public let score: Double

    private enum CodingKeys: String, CodingKey {
        case kbiteCode = "kbite_code"
        case kbiteUuid = "kbite_uuid"
        case resourceName = "resource_name"
        case fileUuid = "file_uuid"
        case fileName = "file_name"
        case fileSummary = "file_summary"
        case matchedKeywords = "matched_keywords"
        case score
    }

    public init(
        kbiteCode: String,
        kbiteUuid: String,
        resourceName: String,
        fileUuid: String,
        fileName: String,
        fileSummary: String,
        matchedKeywords: [String],
        score: Double
    ) {
        self.kbiteCode = kbiteCode
        self.kbiteUuid = kbiteUuid
        self.resourceName = resourceName
        self.fileUuid = fileUuid
        self.fileName = fileName
        self.fileSummary = fileSummary
        self.matchedKeywords = matchedKeywords
        self.score = score
    }
}

// MARK: - Change summaries

public struct ChangeSummary: Codable, Hashable, Sendable {
    public let changeCount: Int
    public let distinctFiles: Int
    public let totalLineSpan: Int

    private enum CodingKeys: String, CodingKey {
        case changeCount = "change_count"
        case distinctFiles = "distinct_files"
        case totalLineSpan = "total_line_span"
    }

    public init(changeCount: Int, distinctFiles: Int, totalLineSpan: Int) {
        self.changeCount = changeCount
        self.distinctFiles = distinctFiles
        self.totalLineSpan = totalLineSpan
    }
}

public struct PromptChangeSummary: Codable, Hashable, Sendable {
    /// nil = changes not attributed to any prompt.
    public let promptUuid: String?
    public let summary: ChangeSummary

    private enum CodingKeys: String, CodingKey {
        case promptUuid = "prompt_uuid"
        case summary
    }

    public init(promptUuid: String?, summary: ChangeSummary) {
        self.promptUuid = promptUuid
        self.summary = summary
    }
}
