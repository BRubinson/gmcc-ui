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

    var id: UUID { sessionUUID }
}
