import Foundation

// Runtime DTO for {session}/session_data.gmcc.yaml.
// Conforms to gmcc.gmcc_session_data_file.

struct GMCCSessionDataFile: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let kbite: [String]            // has_kbite_list
    let branch: String?
    let instanceUUID: UUID?
    let projectUUID: UUID?
    let backstory: String
    let prompts: [GMCCPromptFilesEntry]
    let changedFiles: [GMCCChangedFilesEntry]
    let phaseHistory: [GMCCPhaseHistoryEntry]?   // absent in a fresh session

    var id: UUID { base.uuid }
}

// gmcc_session_data_file_prompt_files_entry — lightweight scan stub for one prompt
// inside a session_data file. NOTE: distinct from PromptFileStub below, which is the
// view layer's mtime-based directory listing. This entry mirrors the typed wire shape.
struct GMCCPromptFilesEntry: Identifiable, Equatable, Hashable {
    let promptID: Int
    let name: String
    let status: GMCCPromptStatus?
    let path: String

    var id: Int { promptID }

    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if String(promptID).localizedStandardContains(query) { return true }
        return false
    }
}

// gmcc_session_data_file_changed_files_entry — per-edit record. `lines` is a list of
// [start, end] inclusive line-range pairs; `commit` is a short sha or "uncommitted".
struct GMCCChangedFilesEntry: Equatable, Hashable {
    let file: String
    let timestamp: String
    let lines: [[Int]]
    let commit: String
    let note: String
}

// gmcc_session_data_file_phase_history_entry — one completed bot-workflow run.
// `reviewStatus` is nil for the lightweight tier; `teamsUsed` only set by /gm_bot_team.
struct GMCCPhaseHistoryEntry: Equatable, Hashable {
    let promptID: Int
    let command: String
    let completedAt: String
    let reviewStatus: GMCCPhaseReviewStatus?
    let teamsUsed: [String]?
}

// Lightweight directory listing for a session's prompts/*.yaml.
// Body is loaded lazily on row tap — not eagerly cached.
struct PromptFileStub: Identifiable, Equatable, Hashable {
    let url: URL
    let displayName: String
    let modifiedAt: Date

    var id: URL { url }

    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return displayName.localizedStandardContains(query)
    }
}
