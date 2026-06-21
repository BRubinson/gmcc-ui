import Foundation

// Runtime DTOs for the prompt-folder file shapes in gmcc.yeet.yaml:
//   {prompt}/{id}_{name}_data.gmcc.yaml   → GMCCPromptDataFile
//   {prompt}/{id}_{name}_initial.yaml     → GMCCInitialPromptFile
//   {prompt}/{id}_{name}_clarified.yaml   → GMCCClarifiedPromptFile
// These were previously unmapped (prompt 3 kept prompts as raw strings). Mapped here
// for full model fidelity; the Projects UI does not yet consume them.

// gmcc_prompt_data_file — identity-and-paths index for one prompt.
struct GMCCPromptDataFile: Identifiable, Equatable, Hashable {
    let base: GMCCBaseFields
    let paths: GMCCCkfsPaths
    let kbite: [String]
    let initialPromptPath: String
    let clarifiedPromptPath: String       // "" until status == Clarified
    let promptStatus: GMCCPromptStatus?
    let command: String

    var id: UUID { base.uuid }

    func matches(query: String) -> Bool { base.matches(query: query) }
}

// gmcc_initial_prompt_file — raw human-authored starting point, split into the
// backstory/goal/detail "prompt style".
struct GMCCInitialPromptFile: Equatable, Hashable {
    let backstory: String
    let goal: String
    let detail: String
    let kbitesLoaded: [String]
    let kbiteContextSummary: String?      // subagent/team tiers only
}

// gmcc_prompt_clarification — one Q/A pair from the Clarify phase. `rating` only set
// by the agent-teams tier.
struct GMCCPromptClarification: Equatable, Hashable {
    let q: String
    let a: String
    let rating: Int?
}

// gmcc_detected_yeet_type — one YEETS type detected in the initial prompt.
struct GMCCDetectedYeetType: Equatable, Hashable {
    let type: String
    let resolvedTo: String
    let source: GMCCYeetDetectionSource?
    let confidence: GMCCYeetDetectionConfidence?
}

// gmcc_clarified_prompt_key_file — a file flagged as relevant during Clarify.
// `consensus` only populated by the agent-teams tier.
struct GMCCClarifiedPromptKeyFile: Equatable, Hashable {
    let path: String
    let relevance: String
    let consensus: String?
}

// gmcc_clarified_prompt_file — the single source of truth after Clarify.
struct GMCCClarifiedPromptFile: Equatable, Hashable {
    let clarifiedAt: String
    let backstory: String
    let goalClarifications: [GMCCPromptClarification]
    let detailClarifications: [GMCCPromptClarification]
    let refinedGoal: String
    let refinedDetail: String
    let detectedYeetTypes: [GMCCDetectedYeetType]
    let keyFiles: [GMCCClarifiedPromptKeyFile]
    let patternsToFollow: [String]?       // subagent/team tiers only
    let constraints: [String]
    let kbitesLoaded: [String]
}
