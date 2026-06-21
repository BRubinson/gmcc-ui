import Foundation

// Typed decoder over YeetLanguageEngine's raw YAML AST. Maps the four runtime
// ckfs file shapes defined in gmcc.yeet.yaml into Swift DTOs.

enum GMCCDecodeError: Error, LocalizedError {
    case readFailed(URL, String)
    case malformed(URL, String)

    var errorDescription: String? {
        switch self {
        case let .readFailed(url, reason): return "Failed to read \(url.lastPathComponent): \(reason)"
        case let .malformed(url, reason):  return "Malformed \(url.lastPathComponent): \(reason)"
        }
    }
}

nonisolated enum GMCCRuntimeDecoder {

    // MARK: - Public entry points

    static func decodeProjectIndex(at url: URL) throws -> GMCCProjectIndexFile {
        let root = try parseRoot(at: url)
        let base = try requireBase(root, at: url)
        let paths = requirePaths(root)
        let projects = sequence(root["projects"]).compactMap { node -> GMCCProjectEntry? in
            guard case let .mapping(map) = node else { return nil }
            guard let b = decodeBase(map), let p = decodePaths(map) else { return nil }
            return GMCCProjectEntry(base: b, paths: p)
        }
        return GMCCProjectIndexFile(base: base, paths: paths, kbite: stringList(root["kbite"]), projects: projects)
    }

    static func decodeProjectData(at url: URL) throws -> GMCCProjectDataFile {
        let root = try parseRoot(at: url)
        let base = try requireBase(root, at: url)
        let paths = requirePaths(root)
        let instances = sequence(root["instances"]).compactMap { node -> GMCCInstanceEntry? in
            guard case let .mapping(map) = node else { return nil }
            guard let b = decodeBase(map), let p = decodePaths(map) else { return nil }
            return GMCCInstanceEntry(base: b, paths: p, systemPath: nullableScalar(map["system_path"]))
        }
        return GMCCProjectDataFile(
            base: base,
            paths: paths,
            kbite: stringList(root["kbite"]),
            repositoryName: nullableScalar(root["repository_name"]),
            httpURI: nullableScalar(root["http_uri"]),
            sshURI: nullableScalar(root["ssh_uri"]),
            instances: instances
        )
    }

    static func decodeInstanceData(at url: URL) throws -> GMCCInstanceDataFile {
        let root = try parseRoot(at: url)
        let base = try requireBase(root, at: url)
        let paths = requirePaths(root)
        let sessions = sequence(root["sessions"]).compactMap { node -> GMCCSessionEntry? in
            guard case let .mapping(map) = node else { return nil }
            guard let b = decodeBase(map), let p = decodePaths(map) else { return nil }
            return GMCCSessionEntry(base: b, paths: p, branch: nullableScalar(map["branch"]))
        }
        return GMCCInstanceDataFile(
            base: base,
            paths: paths,
            kbite: stringList(root["kbite"]),
            systemPath: nullableScalar(root["system_path"]),
            projectUUID: uuidScalar(root["project_uuid"]),
            sessions: sessions
        )
    }

    static func decodeSessionData(at url: URL) throws -> GMCCSessionDataFile {
        let root = try parseRoot(at: url)
        let base = try requireBase(root, at: url)
        let paths = requirePaths(root)

        let prompts = sequence(root["prompts"]).compactMap { node -> GMCCPromptFilesEntry? in
            guard case let .mapping(map) = node, let id = intScalar(map["id"]) else { return nil }
            return GMCCPromptFilesEntry(
                promptID: id,
                name: nullableScalar(map["name"]) ?? "",
                status: promptStatus(map["status"]),
                path: nullableScalar(map["path"]) ?? ""
            )
        }
        let changedFiles = sequence(root["changed_files"]).compactMap { node -> GMCCChangedFilesEntry? in
            guard case let .mapping(map) = node else { return nil }
            return GMCCChangedFilesEntry(
                file: nullableScalar(map["file"]) ?? "",
                timestamp: nullableScalar(map["timestamp"]) ?? "",
                lines: intMatrix(map["lines"]),
                commit: nullableScalar(map["commit"]) ?? "",
                note: nullableScalar(map["note"]) ?? ""
            )
        }
        // phase_history is absent in a fresh session — distinguish nil from empty.
        let phaseHistory: [GMCCPhaseHistoryEntry]?
        if root["phase_history"] == nil {
            phaseHistory = nil
        } else {
            phaseHistory = sequence(root["phase_history"]).compactMap { node -> GMCCPhaseHistoryEntry? in
                guard case let .mapping(map) = node, let pid = intScalar(map["prompt_id"]) else { return nil }
                return GMCCPhaseHistoryEntry(
                    promptID: pid,
                    command: nullableScalar(map["command"]) ?? "",
                    completedAt: nullableScalar(map["completed_at"]) ?? "",
                    reviewStatus: reviewStatus(map["review_status"]),
                    teamsUsed: optionalStringList(map["teams_used"])
                )
            }
        }

        return GMCCSessionDataFile(
            base: base,
            paths: paths,
            kbite: stringList(root["kbite"]),
            branch: nullableScalar(root["branch"]),
            instanceUUID: uuidScalar(root["instance_uuid"]),
            projectUUID: uuidScalar(root["project_uuid"]),
            backstory: nullableScalar(root["backstory"]) ?? "",
            prompts: prompts,
            changedFiles: changedFiles,
            phaseHistory: phaseHistory
        )
    }

    // MARK: - Prompt-folder file decoders

    static func decodePromptData(at url: URL) throws -> GMCCPromptDataFile {
        let root = try parseRoot(at: url)
        let base = try requireBase(root, at: url)
        let paths = requirePaths(root)
        return GMCCPromptDataFile(
            base: base,
            paths: paths,
            kbite: stringList(root["kbite"]),
            initialPromptPath: nullableScalar(root["initial_prompt_path"]) ?? "",
            clarifiedPromptPath: nullableScalar(root["clarified_prompt_path"]) ?? "",
            promptStatus: promptStatus(root["prompt_status"]),
            command: nullableScalar(root["command"]) ?? ""
        )
    }

    static func decodeInitialPrompt(at url: URL) throws -> GMCCInitialPromptFile {
        let root = try parseRoot(at: url)
        return GMCCInitialPromptFile(
            backstory: nullableScalar(root["backstory"]) ?? "",
            goal: nullableScalar(root["goal"]) ?? "",
            detail: nullableScalar(root["detail"]) ?? "",
            kbitesLoaded: stringList(root["kbites_loaded"]),
            kbiteContextSummary: nullableScalar(root["kbite_context_summary"])
        )
    }

    static func decodeClarifiedPrompt(at url: URL) throws -> GMCCClarifiedPromptFile {
        let root = try parseRoot(at: url)
        let goalClar = sequence(root["goal_clarifications"]).compactMap(decodeClarification)
        let detailClar = sequence(root["detail_clarifications"]).compactMap(decodeClarification)
        let detected = sequence(root["detected_yeet_types"]).compactMap { node -> GMCCDetectedYeetType? in
            guard case let .mapping(map) = node else { return nil }
            return GMCCDetectedYeetType(
                type: nullableScalar(map["type"]) ?? "",
                resolvedTo: nullableScalar(map["resolved_to"]) ?? "",
                source: detectionSource(map["source"]),
                confidence: detectionConfidence(map["confidence"])
            )
        }
        let keyFiles = sequence(root["key_files"]).compactMap { node -> GMCCClarifiedPromptKeyFile? in
            guard case let .mapping(map) = node else { return nil }
            return GMCCClarifiedPromptKeyFile(
                path: nullableScalar(map["path"]) ?? "",
                relevance: nullableScalar(map["relevance"]) ?? "",
                consensus: nullableScalar(map["consensus"])
            )
        }
        return GMCCClarifiedPromptFile(
            clarifiedAt: nullableScalar(root["clarified_at"]) ?? "",
            backstory: nullableScalar(root["backstory"]) ?? "",
            goalClarifications: goalClar,
            detailClarifications: detailClar,
            refinedGoal: nullableScalar(root["refined_goal"]) ?? "",
            refinedDetail: nullableScalar(root["refined_detail"]) ?? "",
            detectedYeetTypes: detected,
            keyFiles: keyFiles,
            patternsToFollow: optionalStringList(root["patterns_to_follow"]),
            constraints: stringList(root["constraints"]),
            kbitesLoaded: stringList(root["kbites_loaded"])
        )
    }

    private static func decodeClarification(_ node: YeetYAML) -> GMCCPromptClarification? {
        guard case let .mapping(map) = node else { return nil }
        return GMCCPromptClarification(
            q: nullableScalar(map["q"]) ?? "",
            a: nullableScalar(map["a"]) ?? "",
            rating: intScalar(map["rating"])
        )
    }

    // MARK: - Helpers

    private static func parseRoot(at url: URL) throws -> [String: YeetYAML] {
        do {
            return try YeetLanguageEngine.parseRawRoot(url: url)
        } catch let YeetParseError.readFailed(reason) {
            throw GMCCDecodeError.readFailed(url, reason)
        } catch {
            throw GMCCDecodeError.malformed(url, String(describing: error))
        }
    }

    private static func requireBase(_ root: [String: YeetYAML], at url: URL) throws -> GMCCBaseFields {
        guard let b = decodeBase(root) else {
            throw GMCCDecodeError.malformed(url, "missing required base fields (id/code/uuid/name)")
        }
        return b
    }

    private static func requirePaths(_ root: [String: YeetYAML]) -> GMCCCkfsPaths {
        // Path fields may be absent on legacy files; preserve empty strings rather
        // than throw so the rest of the file still decodes.
        decodePaths(root) ?? GMCCCkfsPaths(absolutePath: "", relativePath: "")
    }

    private static func decodeBase(_ map: [String: YeetYAML]) -> GMCCBaseFields? {
        guard let code = nullableScalar(map["code"]),
              let name = nullableScalar(map["name"]),
              let uuid = uuidScalar(map["uuid"]) else {
            return nil
        }
        let id = intScalar(map["id"]) ?? 0
        return GMCCBaseFields(
            id: id,
            code: code,
            uuid: uuid,
            name: name,
            description: nullableScalar(map["description"]) ?? "",
            createdTime: nullableScalar(map["created_time"]) ?? "",
            updatedTime: nullableScalar(map["updated_time"]) ?? ""
        )
    }

    private static func decodePaths(_ map: [String: YeetYAML]) -> GMCCCkfsPaths? {
        let abs = nullableScalar(map["gmcc_ckfs_absolute_path"])
        let rel = nullableScalar(map["gmcc_ckfs_relative_path"])
        guard abs != nil || rel != nil else { return nil }
        return GMCCCkfsPaths(absolutePath: abs ?? "", relativePath: rel ?? "")
    }

    private static func sequence(_ node: YeetYAML?) -> [YeetYAML] {
        if case let .sequence(items)? = node { return items }
        return []
    }

    private static func nullableScalar(_ node: YeetYAML?) -> String? {
        guard let s = node?.scalarString else { return nil }
        if s.isEmpty || s == "null" || s == "~" { return nil }
        return s
    }

    private static func uuidScalar(_ node: YeetYAML?) -> UUID? {
        guard let s = nullableScalar(node) else { return nil }
        return UUID(uuidString: s)
    }

    private static func intScalar(_ node: YeetYAML?) -> Int? {
        guard let s = nullableScalar(node) else { return nil }
        return Int(s)
    }

    // MARK: - List + enum helpers

    // List<string> — handles a block sequence OR an inline flow scalar "[a, b, c]".
    // (The parser keeps non-empty inline flow values as raw scalar strings.)
    private static func stringList(_ node: YeetYAML?) -> [String] {
        if case let .sequence(items)? = node {
            return items.compactMap { $0.scalarString.flatMap(cleanScalar) }
        }
        guard let s = node?.scalarString, s != "[]" else { return [] }
        return flowElements(s).compactMap(cleanScalar)
    }

    // Like stringList but returns nil for an absent/null node (for `List<…>?` fields).
    private static func optionalStringList(_ node: YeetYAML?) -> [String]? {
        guard let node else { return nil }
        if let s = node.scalarString, s.isEmpty || s == "null" || s == "~" { return nil }
        let list = stringList(node)
        return list.isEmpty ? nil : list
    }

    // List<List<int>> for changed_files.lines. Handles block-of-blocks OR a flow
    // scalar like "[[1, 65], [70, 80]]".
    private static func intMatrix(_ node: YeetYAML?) -> [[Int]] {
        func ints(_ raw: String) -> [Int] {
            flowElements(raw).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        if case let .sequence(rows)? = node {
            return rows.map { row in
                if case let .sequence(cells) = row {
                    return cells.compactMap { $0.scalarString.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
                }
                return row.scalarString.map(ints) ?? []
            }
        }
        guard let s = node?.scalarString, s != "[]" else { return [] }
        return flowElements(s).map(ints)
    }

    // Split one layer of an inline flow value "[a, b, [c, d]]" on top-level commas,
    // respecting bracket/brace nesting. A non-bracketed scalar yields a single element.
    private static func flowElements(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return trimmed.isEmpty ? [] : [trimmed]
        }
        let inner = trimmed.dropFirst().dropLast()
        var elements: [String] = []
        var depth = 0
        var current = ""
        for c in inner {
            if c == "[" || c == "{" { depth += 1; current.append(c) }
            else if c == "]" || c == "}" { depth -= 1; current.append(c) }
            else if c == "," && depth == 0 {
                elements.append(current); current = ""
            } else { current.append(c) }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { elements.append(current) }
        return elements
    }

    // Trim + drop empty/null scalars; used when mapping flow/list elements.
    private static func cleanScalar(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "null" || s == "~" { return nil }
        return s
    }

    private static func promptStatus(_ node: YeetYAML?) -> GMCCPromptStatus? {
        nullableScalar(node).flatMap(GMCCPromptStatus.init(rawValue:))
    }

    private static func reviewStatus(_ node: YeetYAML?) -> GMCCPhaseReviewStatus? {
        nullableScalar(node).flatMap(GMCCPhaseReviewStatus.init(rawValue:))
    }

    private static func detectionSource(_ node: YeetYAML?) -> GMCCYeetDetectionSource? {
        nullableScalar(node).flatMap(GMCCYeetDetectionSource.init(rawValue:))
    }

    private static func detectionConfidence(_ node: YeetYAML?) -> GMCCYeetDetectionConfidence? {
        nullableScalar(node).flatMap(GMCCYeetDetectionConfidence.init(rawValue:))
    }
}
