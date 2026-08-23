import Foundation

/// Payload identifying a session for the session route (`Route.session`).
/// Plain value semantics: the old hand-written `==`/`hash` keyed on
/// `sessionUUID` alone existed to make `WindowGroup(for:)` dedupe to one
/// window per session — that dedupe was doing concurrency control, a job that
/// now belongs to `SessionScopeCache`, so the override is deliberately gone.
///
/// uuid-only payload: all filesystem locations are derived at render time from
/// daemon rows via CkfsPathResolver.
struct SessionWindowID: Codable, Hashable, Identifiable {
    let sessionUUID: UUID
    let instanceUUID: UUID
    let sessionName: String
    /// Deep-link target: a SEARCH hit addresses a PROMPT, not just a session.
    /// `var` + Optional ⇒ the memberwise init defaults it to nil and synthesized
    /// Codable uses decodeIfPresent (the PromptMemoriesWindowID contract).
    ///
    /// Part of Hashable: a hit targeting a DIFFERENT prompt of the open
    /// session changes route identity and re-ids the window content (cheap
    /// via SessionScopeCache's grace list). A repeat hit with the SAME target
    /// is route-equal — `WindowNav.go` short-circuits — so `openSession` also
    /// delivers the target on the one-shot `pendingPromptTarget` channel,
    /// which the live screen consumes.
    var targetPromptUUID: UUID?

    var id: UUID { sessionUUID }
}
