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
/// bodies, which stay behind SESSION_GET. `status` was retired from the wire
/// at v7 (the column survives but every row has read 'active' forever;
/// checked-out state is git-derived via SESSION_RESOLVE instead).
/// `lastActivityAt` is the latest of the session's own updated_at, its
/// prompts' updated_at, and its file changes' created_at (item 1).
public struct SessionStub: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let instanceUuid: String
    public let code: String
    public let name: String
    public let ckfsRelativeStoragePath: String
    public let createdAt: String
    public let updatedAt: String
    public let lastActivityAt: String

    public init(
        uuid: String,
        version: Int64,
        instanceUuid: String,
        code: String,
        name: String,
        ckfsRelativeStoragePath: String,
        createdAt: String,
        updatedAt: String,
        lastActivityAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.instanceUuid = instanceUuid
        self.code = code
        self.name = name
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
    }
}

public struct SessionRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let code: String
    public let name: String
    public let backstory: String
    public let goal: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        uuid: String,
        version: Int64,
        code: String,
        name: String,
        backstory: String,
        goal: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.code = code
        self.name = name
        self.backstory = backstory
        self.goal = goal
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
    public let ckfsRelativeStoragePath: String
    /// True when the prompt predates the m0002 lifecycle epoch — it
    /// legitimately has no clarification/architecture rows and never will.
    /// Computed at materialization against the epoch cache, never stored.
    public let isLegacy: Bool
    public let createdAt: String
    public let updatedAt: String

    public var promptStatus: PromptStatus? { PromptStatus(rawValue: status) }

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
        ckfsRelativeStoragePath: String,
        isLegacy: Bool,
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
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.isLegacy = isLegacy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Lightweight prompt listing shape (replaces reading the session_data
/// prompts: list). Carries its parent session uuid so whole-db listings
/// (PROMPT_LIST with no session filter) stay interpretable — seq is only
/// unique per session.
public struct PromptStub: Codable, Hashable, Sendable {
    public let uuid: String
    public let sessionUuid: String
    public let seq: Int64
    public let code: String
    public let name: String
    public let status: String
    public let version: Int64
    public let ckfsRelativeStoragePath: String
    /// True when the prompt predates the m0002 lifecycle epoch (see
    /// PromptRow.isLegacy).
    public let isLegacy: Bool
    /// Present only when PROMPT_LIST was called with `with_reports` — nested
    /// so "not requested" (nil) and "requested, none exists" (present with
    /// nil members) stay distinguishable.
    public let reports: PromptReportsStub?
    public let createdAt: String
    public let updatedAt: String

    public init(
        uuid: String,
        sessionUuid: String,
        seq: Int64,
        code: String,
        name: String,
        status: String,
        version: Int64,
        ckfsRelativeStoragePath: String,
        isLegacy: Bool,
        reports: PromptReportsStub? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.sessionUuid = sessionUuid
        self.seq = seq
        self.code = code
        self.name = name
        self.status = status
        self.version = version
        self.ckfsRelativeStoragePath = ckfsRelativeStoragePath
        self.isLegacy = isLegacy
        self.reports = reports
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The PROMPT_LIST `with_reports` enrichment block: one summary stub per
/// report machine. A nil member means that summary was never opened —
/// combined with `isLegacy` that is exactly the SUMMARY_ABSENT
/// discrimination, surfaced in a listing.
public struct PromptReportsStub: Codable, Hashable, Sendable {
    public let clarification: ClarificationReportStub?
    public let architecture: ArchitectureReportStub?

    public init(clarification: ClarificationReportStub?, architecture: ArchitectureReportStub?) {
        self.clarification = clarification
        self.architecture = architecture
    }
}

/// Clarification summary stub for the enrichment block. Carries the summary
/// version so the caller can mutate immediately without a confirming fetch.
public struct ClarificationReportStub: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let version: Int64
    public let status: String
    public let refinedGoal: String
    public let backstoryNote: String
    public let questionCount: Int
    /// Resume signal: >0 means the clarification stalled mid-answering.
    public let openQuestionCount: Int

    public init(
        summaryUuid: String,
        version: Int64,
        status: String,
        refinedGoal: String,
        backstoryNote: String,
        questionCount: Int,
        openQuestionCount: Int
    ) {
        self.summaryUuid = summaryUuid
        self.version = version
        self.status = status
        self.refinedGoal = refinedGoal
        self.backstoryNote = backstoryNote
        self.questionCount = questionCount
        self.openQuestionCount = openQuestionCount
    }
}

/// Architecture summary stub for the enrichment block.
public struct ArchitectureReportStub: Codable, Hashable, Sendable {
    public let summaryUuid: String
    public let version: Int64
    public let status: String
    public let persistenceChangeCount: Int
    public let generalChangeCount: Int

    public init(
        summaryUuid: String,
        version: Int64,
        status: String,
        persistenceChangeCount: Int,
        generalChangeCount: Int
    ) {
        self.summaryUuid = summaryUuid
        self.version = version
        self.status = status
        self.persistenceChangeCount = persistenceChangeCount
        self.generalChangeCount = generalChangeCount
    }
}

/// One ranked SEARCH result. Stubs-not-content discipline: `excerpt` is a
/// bounded FTS5 snippet, never a full body; full prompt lineage rides along
/// so the caller never needs a follow-up fetch to know what it found.
public struct SearchHit: Codable, Hashable, Sendable {
    /// Raw kind string (same forward-compat rule as event kinds/error codes).
    public let kind: String
    /// The matched row's own uuid.
    public let subjectUuid: String
    public let promptUuid: String
    public let promptSeq: Int64
    public let promptName: String
    public let promptStatus: String
    public let sessionUuid: String
    public let sessionCode: String
    /// Short label per kind: prompt name / question / file path / "architecture summary".
    public let title: String
    /// Bounded snippet from the best-matching column.
    public let excerpt: String
    /// bm25-derived; negative, smaller = better; comparable WITHIN a kind only.
    public let score: Double

    public init(
        kind: String,
        subjectUuid: String,
        promptUuid: String,
        promptSeq: Int64,
        promptName: String,
        promptStatus: String,
        sessionUuid: String,
        sessionCode: String,
        title: String,
        excerpt: String,
        score: Double
    ) {
        self.kind = kind
        self.subjectUuid = subjectUuid
        self.promptUuid = promptUuid
        self.promptSeq = promptSeq
        self.promptName = promptName
        self.promptStatus = promptStatus
        self.sessionUuid = sessionUuid
        self.sessionCode = sessionCode
        self.title = title
        self.excerpt = excerpt
        self.score = score
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

    public init(promptUuid: String?, summary: ChangeSummary) {
        self.promptUuid = promptUuid
        self.summary = summary
    }
}

// MARK: - Clarification (v7)

public struct ClarificationSummaryRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let promptUuid: String
    public let status: String
    public let backstoryNote: String
    public let refinedGoal: String
    public let refinedDetail: String
    public let createdAt: String
    public let updatedAt: String

    public var clarificationStatus: ClarificationStatus? { ClarificationStatus(rawValue: status) }

    public init(
        uuid: String,
        version: Int64,
        promptUuid: String,
        status: String,
        backstoryNote: String,
        refinedGoal: String,
        refinedDetail: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.promptUuid = promptUuid
        self.status = status
        self.backstoryNote = backstoryNote
        self.refinedGoal = refinedGoal
        self.refinedDetail = refinedDetail
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ClarificationRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let clarificationSummaryUuid: String
    public let seq: Int64
    public let category: String
    public let question: String
    public let answer: String?
    public let answerSource: String?
    public let status: String

    public init(
        uuid: String,
        version: Int64,
        clarificationSummaryUuid: String,
        seq: Int64,
        category: String,
        question: String,
        answer: String?,
        answerSource: String?,
        status: String
    ) {
        self.uuid = uuid
        self.version = version
        self.clarificationSummaryUuid = clarificationSummaryUuid
        self.seq = seq
        self.category = category
        self.question = question
        self.answer = answer
        self.answerSource = answerSource
        self.status = status
    }
}

// MARK: - Architecture (v7)

public struct ArchitectureSummaryRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let version: Int64
    public let promptUuid: String
    public let body: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String

    public var architectureStatus: ArchitectureStatus? { ArchitectureStatus(rawValue: status) }

    public init(
        uuid: String,
        version: Int64,
        promptUuid: String,
        body: String,
        status: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.uuid = uuid
        self.version = version
        self.promptUuid = promptUuid
        self.body = body
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Implementation-state decoration on a planned change row — DERIVED from the
/// path join against file_change at read time, never stored, so it can never
/// go stale. fileChangeCount 0 = planned but untouched.
public struct ChangeImplementationState: Codable, Hashable, Sendable {
    public let fileChangeCount: Int
    public let firstChangedAt: String?
    public let lastChangedAt: String?

    public init(fileChangeCount: Int, firstChangedAt: String?, lastChangedAt: String?) {
        self.fileChangeCount = fileChangeCount
        self.firstChangedAt = firstChangedAt
        self.lastChangedAt = lastChangedAt
    }
}

public struct ArchPersistenceFieldChangeRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let seq: Int64
    public let fieldName: String
    public let changeReason: String
    public let changePurpose: String
    public let dataType: String
    public let nullable: Bool
    public let isForeignKey: Bool
    public let fkTarget: String?
    public let isIndexed: Bool

    public init(
        uuid: String,
        seq: Int64,
        fieldName: String,
        changeReason: String,
        changePurpose: String,
        dataType: String,
        nullable: Bool,
        isForeignKey: Bool,
        fkTarget: String?,
        isIndexed: Bool
    ) {
        self.uuid = uuid
        self.seq = seq
        self.fieldName = fieldName
        self.changeReason = changeReason
        self.changePurpose = changePurpose
        self.dataType = dataType
        self.nullable = nullable
        self.isForeignKey = isForeignKey
        self.fkTarget = fkTarget
        self.isIndexed = isIndexed
    }
}

public struct ArchPersistenceChangeRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let seq: Int64
    public let className: String
    public let filePath: String
    public let reasonBrief: String
    public let fields: [ArchPersistenceFieldChangeRow]
    public let implementation: ChangeImplementationState

    public init(
        uuid: String,
        seq: Int64,
        className: String,
        filePath: String,
        reasonBrief: String,
        fields: [ArchPersistenceFieldChangeRow],
        implementation: ChangeImplementationState
    ) {
        self.uuid = uuid
        self.seq = seq
        self.className = className
        self.filePath = filePath
        self.reasonBrief = reasonBrief
        self.fields = fields
        self.implementation = implementation
    }
}

public struct ArchGeneralChangeRow: Codable, Hashable, Sendable {
    public let uuid: String
    public let seq: Int64
    public let filePath: String
    public let className: String?
    public let reasonBrief: String
    public let changeDepth: String
    public let changeCode: String
    public let implementation: ChangeImplementationState

    public init(
        uuid: String,
        seq: Int64,
        filePath: String,
        className: String?,
        reasonBrief: String,
        changeDepth: String,
        changeCode: String,
        implementation: ChangeImplementationState
    ) {
        self.uuid = uuid
        self.seq = seq
        self.filePath = filePath
        self.className = className
        self.reasonBrief = reasonBrief
        self.changeDepth = changeDepth
        self.changeCode = changeCode
        self.implementation = implementation
    }
}

/// A file this prompt touched that no architecture change row planned —
/// scope drift, the bucket that accelerates debugging.
public struct UnplannedChangeRow: Codable, Hashable, Sendable {
    public let path: String
    public let changeCount: Int
    public let firstChangedAt: String
    public let lastChangedAt: String

    public init(path: String, changeCount: Int, firstChangedAt: String, lastChangedAt: String) {
        self.path = path
        self.changeCount = changeCount
        self.firstChangedAt = firstChangedAt
        self.lastChangedAt = lastChangedAt
    }
}
