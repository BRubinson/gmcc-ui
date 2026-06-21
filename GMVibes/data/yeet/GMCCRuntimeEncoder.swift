import Foundation

// Write-side mirror of GMCCRuntimeDecoder. Emits YEET-conformant YAML for the
// ckfs file shapes the authoring surface creates, byte-compatible with
// scripts/detect_repo.sh so a subsequent SessionStart boot sees freshly-written
// entries as already-present (idempotent) and so the output passes /gm_compile.
//
// No YAML library: files are built as [String] line arrays joined with "\n".
// The canonical key order matches the plugin templates (NOT YeetLanguageEngine's
// __yeet_ordered_keys__ sidecar, which is parser-internal). Mixin fields
// (has_base_fields / has_ckfs_paths / has_kbite_list) are flattened to top-level
// keys exactly as the wire format stores them.

enum GMCCEncodeError: Error, LocalizedError {
    case writeFailed(URL, String)
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case let .writeFailed(url, reason): return "Failed to write \(url.lastPathComponent): \(reason)"
        case let .invalidName(name):        return "Invalid name \"\(name)\" — must contain at least one letter or digit."
        }
    }
}

nonisolated enum GMCCRuntimeEncoder {

    // MARK: - Public entry points

    /// Writes prompts/{id}_{seg}/ with its _data.gmcc.yaml + _initial.yaml + an
    /// empty memory/ subdir, then appends the prompt's stub entry to the parent
    /// session_data.gmcc.yaml's prompts[] list. Returns the new prompt folder URL.
    @discardableResult
    static func writePromptFolder(
        sessionDirURL: URL,        // .../sessions/{slug}
        sessionRelPath: String,    // projects/.../sessions/{slug}
        nextID: Int,
        name: String,
        backstory: String,
        goal: String,
        detail: String,
        kbites: [String]
    ) throws -> URL {
        let seg = try sanitizeSegment(name)
        let promptsRoot = sessionDirURL.appendingPathComponent("prompts", isDirectory: true)
        // Re-derive the id at write time so a sheet that captured a stale nextID
        // (the 1s loop may have advanced it) can't collide with an existing folder.
        let effectiveID = max(nextID, (maxFolderPrefix(in: promptsRoot) ?? 0) + 1)
        let folderName = "\(effectiveID)_\(seg)"
        let now = iso8601Now()

        let promptDir = promptsRoot.appendingPathComponent(folderName, isDirectory: true)
        let memoryDir = promptDir.appendingPathComponent("memory", isDirectory: true)
        try createDirectory(memoryDir)   // creates promptDir as an intermediate too

        let dataName = "\(folderName)_data.gmcc.yaml"
        let initialName = "\(folderName)_initial.yaml"
        let dataURL = promptDir.appendingPathComponent(dataName)
        let initialURL = promptDir.appendingPathComponent(initialName)

        let relBase = "\(sessionRelPath)/prompts/\(folderName)"

        // --- {id}_{seg}_data.gmcc.yaml (gmcc_prompt_data_file) ---
        var data: [String] = header("gmcc.gmcc_prompt_data_file")
        data += [
            scalar("id", String(effectiveID)),
            scalar("code", seg),
            scalar("uuid", newUUID()),
            scalar("name", name.isEmpty ? seg : name),
            quotedEmpty("description"),
            scalar("created_time", now),
            scalar("updated_time", now),
            scalar("gmcc_ckfs_absolute_path", dataURL.path),
            scalar("gmcc_ckfs_relative_path", "\(relBase)/\(dataName)"),
            "",
        ]
        data += kbiteBlock(kbites)
        data += [
            "",
            scalar("initial_prompt_path", initialName),
            quotedEmpty("clarified_prompt_path"),
            scalar("prompt_status", "Draft"),
            quotedEmpty("command"),
        ]
        try writeNew(render(data), to: dataURL)

        // --- {id}_{seg}_initial.yaml (gmcc_initial_prompt_file) ---
        var initial: [String] = header("gmcc.gmcc_initial_prompt_file")
        initial += blockScalar("backstory", backstory)
        initial += blockScalar("goal", goal)
        initial += blockScalar("detail", detail)
        initial += listBlock("kbites_loaded", kbites)
        try writeNew(render(initial), to: initialURL)

        // --- append prompts[] stub to session_data.gmcc.yaml ---
        let sessionDataURL = sessionDirURL.appendingPathComponent("session_data.gmcc.yaml")
        let path = "prompts/\(folderName)/\(dataName)"
        let entry = [
            "  - id: \(effectiveID)",
            "    name: \(name.isEmpty ? seg : name)",
            "    status: Draft",
            "    path: \(path)",
        ]
        // Prompt entries have no `code:` — anchor dedupe on the unique path: line.
        try appendListEntry(to: sessionDataURL, listKey: "prompts", entryLines: entry,
                            dedupeAnchor: "    path: \(path)")

        return promptDir
    }

    /// Rewrites an existing {id}_{name}_initial.yaml in place with new
    /// backstory/goal/detail prose. Regenerates the whole file (yeet header +
    /// the three block scalars + kbites_loaded + optional kbite_context_summary)
    /// rather than patching lines, then writes via the atomic .tmp-replace
    /// primitive so the 1s read loop never observes a partial file. The caller
    /// supplies the kbites_loaded / kbite_context_summary it decoded so they
    /// round-trip untouched.
    static func writeInitialPromptFile(
        at initialURL: URL,
        backstory: String,
        goal: String,
        detail: String,
        kbitesLoaded: [String],
        kbiteContextSummary: String?
    ) throws {
        var lines: [String] = header("gmcc.gmcc_initial_prompt_file")
        lines += blockScalar("backstory", backstory)
        lines += blockScalar("goal", goal)
        lines += blockScalar("detail", detail)
        lines += listBlock("kbites_loaded", kbitesLoaded)
        if let summary = kbiteContextSummary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += blockScalar("kbite_context_summary", summary)
        }
        try writeAtomicReplace(render(lines), to: initialURL)
    }

    /// Stamps sessions/{slug}/session_data.gmcc.yaml (+ prompts/ subdir) with the
    /// given instance/project back-references, then appends a session entry to the
    /// parent instance_data.gmcc.yaml's sessions[] list. Returns the session dir URL.
    @discardableResult
    static func writeSession(
        instanceDirURL: URL,       // .../instances/{instance}
        instanceRelPath: String,   // projects/.../instances/{instance}
        projectUUID: UUID,
        instanceUUID: UUID,
        branch: String,
        name: String,
        description: String,
        parentKbite: [String]
    ) throws -> URL {
        let slug = slugBranch(branch)
        guard !slug.isEmpty else { throw GMCCEncodeError.invalidName(branch) }
        let now = iso8601Now()
        let display = name.isEmpty ? slug : name

        let sessionDir = instanceDirURL.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        let promptsDir = sessionDir.appendingPathComponent("prompts", isDirectory: true)
        try createDirectory(promptsDir)

        let sessionDataURL = sessionDir.appendingPathComponent("session_data.gmcc.yaml")
        let absPath = sessionDir.path
        let relPath = "\(instanceRelPath)/sessions/\(slug)"

        // --- session_data.gmcc.yaml (gmcc_session_data_file) ---
        var lines: [String] = header("gmcc.gmcc_session_data_file")
        lines += [
            scalar("id", "1"),     // detect_repo always writes id: 1; uuid is identity.
            scalar("code", slug),
            scalar("uuid", newUUID()),
            scalar("name", display),
            quotedString("description", description),
            scalar("created_time", now),
            scalar("updated_time", now),
            scalar("gmcc_ckfs_absolute_path", absPath),
            scalar("gmcc_ckfs_relative_path", relPath),
            scalar("branch", branch),
            scalar("instance_uuid", instanceUUID.uuidString.lowercased()),
            scalar("project_uuid", projectUUID.uuidString.lowercased()),
            "",
        ]
        // backstory — session-level narrative is always seeded empty per the v11
        // template (the user's text goes to the `description:` base field above).
        lines += [quotedEmpty("backstory"), ""]
        lines += kbiteBlock(parentKbite)            // inherited from parent instance
        lines += ["prompts: []", "changed_files: []"]
        try writeNew(render(lines), to: sessionDataURL)

        // --- append sessions[] entry to instance_data.gmcc.yaml (mirror detect_repo 5g) ---
        let instanceDataURL = instanceDirURL.appendingPathComponent("instance_data.gmcc.yaml")
        let entry = [
            "  - id: 1",
            "    code: \(slug)",
            "    uuid: \(newUUID())",
            "    name: \(display)",
            "    " + quotedString("description", description),
            "    created_time: \(now)",
            "    updated_time: \(now)",
            "    gmcc_ckfs_absolute_path: \(absPath)",
            "    gmcc_ckfs_relative_path: \(relPath)",
            "    branch: \(branch)",
        ]
        try appendListEntry(to: instanceDataURL, listKey: "sessions", entryLines: entry,
                            dedupeAnchor: "    code: \(slug)")

        return sessionDir
    }

    // MARK: - Header + scalar helpers

    private static func header(_ type: String) -> [String] {
        ["yeet:", "  - gmcc", "yeet_type: \(type)", ""]
    }

    private static func scalar(_ key: String, _ value: String) -> String {
        "\(key): \(value)"
    }

    private static func quotedEmpty(_ key: String) -> String {
        "\(key): \"\""
    }

    // Double-quoted string value (escaping `\` and `"`); empty → `key: ""`.
    // Single-line use only — callers pass display strings, not block prose.
    private static func quotedString(_ key: String, _ value: String) -> String {
        let oneLine = value.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if oneLine.isEmpty { return quotedEmpty(key) }
        let escaped = oneLine.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\(key): \"\(escaped)\""
    }

    // Literal block scalar `key: |` with each content line indented 2 spaces.
    // Empty/whitespace-only content collapses to `key: ""` (never a bare `key: |`
    // with no body, which would misparse). Leading and trailing blank lines are
    // stripped so the body's first/last content line is never an empty `  ` line
    // (which the parser's block-scalar reader would otherwise drop, losing
    // round-trip fidelity).
    private static func blockScalar(_ key: String, _ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [quotedEmpty(key)]
        }
        var body = normalized
        while body.hasPrefix("\n") { body.removeFirst() }
        while body.hasSuffix("\n") { body.removeLast() }
        let indented = body.components(separatedBy: "\n").map { "  \($0)" }
        return ["\(key): |"] + indented
    }

    // Largest leading integer of `{N}_…` subdirectory names under a prompts root.
    // Returns nil when the directory is absent or has no numbered prompt folders.
    private static func maxFolderPrefix(in promptsRoot: URL) -> Int? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: promptsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let ids: [Int] = entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            guard let underscore = name.firstIndex(of: "_") else { return nil }
            return Int(name[name.startIndex..<underscore])
        }
        return ids.max()
    }

    // List<string>: `key: []` when empty, else a block sequence.
    private static func listBlock(_ key: String, _ list: [String]) -> [String] {
        list.isEmpty ? ["\(key): []"] : ["\(key):"] + list.map { "  - \($0)" }
    }

    // kbite has a blank-line gap before it in the templates; same shape as listBlock.
    private static func kbiteBlock(_ list: [String]) -> [String] {
        listBlock("kbite", list)
    }

    // MARK: - Identity / formatting

    private static func newUUID() -> String { UUID().uuidString.lowercased() }

    private static func iso8601Now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // no fractional seconds
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    // Branch slug — matches detect_repo.sh's slugify(): only `/` → `__`.
    private static func slugBranch(_ branch: String) -> String {
        branch.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "__")
    }

    // Folder/file/code segment for a prompt name. Lowercases, maps `/`→`__`,
    // collapses any run of non-[a-z0-9_-] into a single `_`, trims stray `_`.
    private static func sanitizeSegment(_ name: String) throws -> String {
        let lower = name.lowercased()
        var out = ""
        var lastWasSep = false
        for ch in lower {
            if ch == "/" {
                out += "__"; lastWasSep = false
            } else if ch.isLetter || ch.isNumber || ch == "-" {
                out.append(ch); lastWasSep = false
            } else {
                if !lastWasSep && !out.isEmpty { out.append("_") }
                lastWasSep = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        while out.hasPrefix("_") { out.removeFirst() }
        guard !out.isEmpty else { throw GMCCEncodeError.invalidName(name) }
        return out
    }

    // MARK: - File writing

    private static func render(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }

    private static func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw GMCCEncodeError.writeFailed(url, error.localizedDescription)
        }
    }

    // New files: no read-loop has indexed them yet, so a plain write is race-free.
    private static func writeNew(_ text: String, to url: URL) throws {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw GMCCEncodeError.writeFailed(url, error.localizedDescription)
        }
    }

    // Append an entry to an existing file's block-sequence list, idempotently.
    //  1. Dedupe: if dedupeAnchor already present verbatim, no-op.
    //  2. Sentinel transition: `{listKey}: []` → `{listKey}:`.
    //  3. Insert entryLines at the END OF THE LIST BLOCK — i.e. after the list's
    //     last indented line, before the next top-level key. This matters because
    //     a target list is not always the file's last key (e.g. session_data's
    //     `prompts:` is followed by `changed_files:`/`phase_history:`); appending
    //     at raw EOF would mis-nest the entry. All other content is preserved
    //     verbatim. Written via .tmp + atomic replace so the 1s refresh loop never
    //     reads a partial file.
    private static func appendListEntry(
        to fileURL: URL,
        listKey: String,
        entryLines: [String],
        dedupeAnchor: String
    ) throws {
        let original: String
        do {
            original = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw GMCCEncodeError.writeFailed(fileURL, "read for append failed: \(error.localizedDescription)")
        }

        var lines = original.components(separatedBy: "\n")

        // Drop a single trailing empty element from the split (files end in "\n").
        if lines.last == "" { lines.removeLast() }

        // 1. Locate the list key, transitioning an empty-list sentinel.
        var listIdx: Int? = nil
        if let idx = lines.firstIndex(of: "\(listKey): []") {
            lines[idx] = "\(listKey):"
            listIdx = idx
        } else if let idx = lines.firstIndex(of: "\(listKey):") {
            listIdx = idx
        }

        // 2. Dedupe guard — scoped to the list block only, so a coincidentally
        //    identical line elsewhere (e.g. a changed_files/phase_history field)
        //    can't suppress a legitimate append.
        if let start = listIdx, lines[start...].contains(dedupeAnchor) { return }
        if listIdx == nil, lines.contains(dedupeAnchor) { return }

        // 3. Find the end of the list block: scan past the list's indented item
        //    lines AND any blank lines interleaved between items (block scalars in
        //    phase_history entries produce these). The block ends at the first
        //    non-empty column-0 line (the next top-level key or a comment). Insert
        //    after the last indented line. Falls back to EOF when the list is the
        //    file's final key.
        if let start = listIdx {
            var insertAt = start + 1
            var i = start + 1
            while i < lines.count {
                let line = lines[i]
                if line.hasPrefix(" ") {
                    insertAt = i + 1
                    i += 1
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1   // blank line inside/after the block — keep scanning
                } else {
                    break    // non-empty column-0 line terminates the list block
                }
            }
            lines.insert(contentsOf: entryLines, at: insertAt)
        } else {
            // Key absent entirely — shouldn't happen for our shapes; append at EOF.
            lines += entryLines
        }

        let text = lines.joined(separator: "\n") + "\n"
        try writeAtomicReplace(text, to: fileURL)
    }

    private static func writeAtomicReplace(_ text: String, to url: URL) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try text.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw GMCCEncodeError.writeFailed(url, error.localizedDescription)
        }
    }
}
