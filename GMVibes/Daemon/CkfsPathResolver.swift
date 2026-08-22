import Foundation
import GMCCDaemonKit

/// Filesystem derivations off daemon rows, isolated in one place. Rows carry
/// ckfs-RELATIVE storage paths; everything here resolves against
/// $GMCC_CKFS_ROOT. /archive_legacy_yaml_gmcc moves PROMPT folders (not
/// session dirs) into _archive/cold_storage/<same relative path>, so the
/// archive mirror is probed at the prompt-folder level, where archiving
/// actually happens.
///
/// All functions perform synchronous FileManager probes — callers resolve
/// off the main actor and cache the results (never call from a View body).
nonisolated enum CkfsPathResolver {
    /// Session codes are slugged branch names (`/` → `__`). No branch column
    /// exists in the db; un-slugging is the display derivation (lossy in
    /// principle for a branch that itself contains "__").
    static func unslugBranch(_ sessionCode: String) -> String {
        sessionCode.replacingOccurrences(of: "__", with: "/")
    }

    /// Slug rule shared with prompt codes (mirrors the historical folder
    /// segment rule; also used by CreatePromptView's code preview).
    ///
    /// WARNING: this is NOT the session-code rule. `session.code` is derived
    /// from the branch with ONLY `/` → `__` (no case/punctuation folding) —
    /// use `GitSlug.sessionCode(forBranch:)` for branch comparison, or a
    /// branch like `Feature/Login` will silently never match its session.
    static func slug(_ name: String) -> String {
        let lower = name.lowercased()
        var out = ""
        var lastWasSep = false
        for ch in lower {
            if ch == "/" { out += "__"; lastWasSep = false }
            else if ch.isLetter || ch.isNumber || ch == "-" { out.append(ch); lastWasSep = false }
            else { if !lastWasSep && !out.isEmpty { out.append("_") }; lastWasSep = true }
        }
        while out.hasSuffix("_") { out.removeLast() }
        while out.hasPrefix("_") { out.removeFirst() }
        return out
    }

    private static func archiveMirror(relative: String, ckfsRoot: String) -> URL {
        URL(fileURLWithPath: ckfsRoot, isDirectory: true)
            .appendingPathComponent("_archive/cold_storage", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
    }

    /// Resolve a ckfs-relative path, falling back to the archive mirror when
    /// the live location is gone. Returns the live URL when neither exists
    /// (callers render empty states off a missing directory).
    static func resolve(relative: String, ckfsRoot: String) -> URL {
        let live = URL(fileURLWithPath: ckfsRoot, isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        if FileManager.default.fileExists(atPath: live.path) { return live }
        let archived = archiveMirror(relative: relative, ckfsRoot: ckfsRoot)
        if FileManager.default.fileExists(atPath: archived.path) { return archived }
        return live
    }

    static func sessionDir(ckfsRoot: String, session: SessionStub) -> URL {
        URL(fileURLWithPath: ckfsRoot, isDirectory: true)
            .appendingPathComponent(session.ckfsRelativeStoragePath, isDirectory: true)
    }

    /// A prompt's folder under a session, or nil when no matching folder
    /// exists anywhere (a fresh prompt with no filesystem presence — callers
    /// render an empty state rather than a stranger's folder).
    ///
    /// Match rules, in order, probing the LIVE session dir then the archive
    /// mirror at each step (archive moves prompt folders, leaving the session
    /// dir live with an emptied prompts/):
    /// 1. `<seq>_<code>` — exact (app-created prompts get this on disk).
    /// 2. `<seq>_<slug(name)>` — imported folders were named from prompt
    ///    NAMES, while gm-created rows default code to "p{seq}".
    /// A loose `<seq>_*` prefix scan is deliberately NOT used: a db prompt at
    /// a seq that collides with an unrelated legacy folder would resolve to a
    /// stranger's files (reproduced on the real tree during review).
    static func promptFolder(
        ckfsRoot: String,
        session: SessionStub,
        seq: Int64,
        code: String,
        name: String
    ) -> URL? {
        let livePrompts = sessionDir(ckfsRoot: ckfsRoot, session: session)
            .appendingPathComponent("prompts", isDirectory: true)
        let archivedPrompts = archiveMirror(
            relative: session.ckfsRelativeStoragePath, ckfsRoot: ckfsRoot)
            .appendingPathComponent("prompts", isDirectory: true)

        var candidates = ["\(seq)_\(code)"]
        let named = "\(seq)_\(slug(name))"
        if named != candidates[0], slug(name).isEmpty == false {
            candidates.append(named)
        }
        for candidate in candidates {
            for base in [livePrompts, archivedPrompts] {
                let url = base.appendingPathComponent(candidate, isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// The conventional (not-yet-existing) folder for a prompt — where the
    /// app creates the folder for a freshly created prompt.
    static func conventionalPromptFolder(
        ckfsRoot: String, session: SessionStub, seq: Int64, code: String
    ) -> URL {
        sessionDir(ckfsRoot: ckfsRoot, session: session)
            .appendingPathComponent("prompts", isDirectory: true)
            .appendingPathComponent("\(seq)_\(code)", isDirectory: true)
    }

    /// Memory root for a prompt, in priority order:
    /// 1. Deepest common ancestor of the prompt's registered artifact files
    ///    that exists on disk (the db tells us where its files are before we
    ///    guess) — handles absolute and ckfs-relative artifact paths.
    /// 2. The matched prompt folder's memory/ subdirectory.
    /// Returns nil when neither resolves (fresh prompt, no folder yet).
    static func memoryRoot(
        ckfsRoot: String,
        session: SessionStub,
        seq: Int64,
        code: String,
        name: String,
        artifacts: [ArtifactRow]
    ) -> URL? {
        let parents = artifacts.compactMap { artifact -> URL? in
            let path = artifact.filePath
            let fileURL: URL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: ckfsRoot, isDirectory: true).appendingPathComponent(path)
            let parent = fileURL.deletingLastPathComponent()
            return FileManager.default.fileExists(atPath: parent.path) ? parent : nil
        }
        if var common = parents.first {
            for parent in parents.dropFirst() {
                while common.path != "/" && parent.path != common.path
                    && !parent.path.hasPrefix(common.path + "/") {
                    common.deleteLastPathComponent()
                }
            }
            if common.path != "/" { return common }
        }
        return promptFolder(ckfsRoot: ckfsRoot, session: session, seq: seq, code: code, name: name)
            .map { $0.appendingPathComponent("memory", isDirectory: true) }
    }
}
