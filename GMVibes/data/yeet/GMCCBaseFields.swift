import Foundation

// Shared mixins for runtime ckfs DTOs — mirror the YEETS `has_base_fields` and
// `has_ckfs_paths` mixins defined in gmcc.yeet.yaml. The runtime files compose
// these inline at the top level (no `unwrap_*:` keys at the wire layer; the
// composition is purely a schema-side concept).

struct GMCCBaseFields: Equatable, Hashable {
    let id: Int
    let code: String
    let uuid: UUID
    let name: String
    let description: String
    let createdTime: String  // ISO8601 retained as raw string
    let updatedTime: String
}

struct GMCCCkfsPaths: Equatable, Hashable {
    let absolutePath: String
    let relativePath: String

    var absoluteURL: URL { URL(fileURLWithPath: absolutePath, isDirectory: true) }
}

// View-layer search predicate — shared by every entity row so the projects
// search bar can hit name/code/uuid/id with one call.
extension GMCCBaseFields {
    func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if name.localizedStandardContains(query) { return true }
        if code.localizedStandardContains(query) { return true }
        if uuid.uuidString.localizedStandardContains(query) { return true }
        if String(id).localizedStandardContains(query) { return true }
        if description.localizedStandardContains(query) { return true }
        return false
    }

    // Tokenized ANY-term match (name / code / id / description). Used by the
    // project-load + prompt-list search so both screens share the same semantics:
    // a row matches if it contains ANY space-separated term. Inactive query ⇒ true
    // (callers treat "no query" as "show everything").
    func matches(_ query: SearchQuery) -> Bool {
        guard query.isActive else { return true }
        return query.matchesAny(name, code, String(id), description)
    }
}
