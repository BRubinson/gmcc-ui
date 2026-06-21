import Foundation

// Enums from gmcc.yeet.yaml (sections.default.enums). Each is backed by the raw
// wire string the ckfs yamls actually store, with a lenient failable init so an
// unknown/absent value decodes to nil rather than crashing.

enum GMCCPromptStatus: String, Equatable, Hashable, CaseIterable {
    case draft      = "Draft"
    case clarifying = "Clarifying"
    case clarified  = "Clarified"
}

enum GMCCYeetDetectionSource: String, Equatable, Hashable, CaseIterable {
    case declared = "declared"
    case inferred = "inferred"
}

enum GMCCYeetDetectionConfidence: String, Equatable, Hashable, CaseIterable {
    case confident          = "confident"
    case needsClarification = "needs_clarification"
}

enum GMCCPhaseReviewStatus: String, Equatable, Hashable, CaseIterable {
    case pass            = "pass"
    case passWithIssues  = "pass_with_issues"
}
