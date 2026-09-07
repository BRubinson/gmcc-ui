import Foundation

/// The daemon's first repo file writer — a value type whose entire public
/// surface can only name paths under `{instanceRoot}/.gmcc/dope/`.
///
/// KbiteMawOpenHandler (writes a caller-supplied absolute path, no root, no
/// containment) is explicitly NOT the template. Three independent layers of
/// containment, because one is not enough:
///   1. `resolve` — loud pre-flight on the instance root itself,
///   2. `domainFile(code:)` — re-validates the code even for callers that
///      already validated it, so `/` and `..` can never smuggle in,
///   3. every returned URL passes a final standardized-prefix guard.
///
/// GitHead.swift documents stale instance roots as COMMON; GitHead stays
/// silent because it only reads. This type THROWS, because the next step
/// writes into a user's repo.
public struct DopeRepoSandbox: Sendable {
    public let instanceRoot: URL
    public let dopeRoot: URL

    public struct SandboxError: Error, CustomStringConvertible, Sendable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: - Resolution

    public static func resolve(instanceRoot raw: String) throws -> DopeRepoSandbox {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SandboxError("instance root is empty — the session's instance row has no path")
        }
        guard trimmed.hasPrefix("/") else {
            throw SandboxError("instance root is not an absolute path: \(trimmed)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SandboxError("instance root is missing or stale: \(trimmed)")
        }
        guard GitHead.gitDirectory(repoRoot: trimmed) != nil else {
            throw SandboxError("instance root is not a git checkout: \(trimmed)")
        }
        let root = URL(fileURLWithPath: trimmed).standardizedFileURL
        let dopeRoot = root.appendingPathComponent(".gmcc/dope", isDirectory: true)
        // Symlink guard: standardizedFileURL is lexical, so a symlinked
        // .gmcc or .gmcc/dope would redirect every "contained" path (and the
        // atomic swap) outside the repo. resolvingSymlinksInPath resolves the
        // components that exist — refuse when the resolved dope root leaves
        // the resolved instance root.
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedDope = dopeRoot.resolvingSymlinksInPath()
        guard resolvedDope.path.hasPrefix(resolvedRoot.path + "/") else {
            throw SandboxError(
                "refusing symlinked dope root: \(dopeRoot.path) resolves to \(resolvedDope.path)")
        }
        return DopeRepoSandbox(instanceRoot: root, dopeRoot: dopeRoot)
    }

    // MARK: - Contained paths

    public var mainFile: URL {
        dopeRoot.appendingPathComponent(DopeDocumentCodec.mainFileName)
    }

    public var drawingConfigFile: URL {
        dopeRoot.appendingPathComponent(DopeDocumentCodec.drawingConfigFileName)
    }

    public var domainsDirectory: URL {
        dopeRoot.appendingPathComponent(DopeDocumentCodec.domainsDirectoryName, isDirectory: true)
    }

    public func domainFile(code: String) throws -> URL {
        try DopeCode.validateCode(code, field: "domain code")
        let url = domainsDirectory
            .appendingPathComponent(code + DopeDocumentCodec.domainFileSuffix)
        return try contained(url)
    }

    /// The final belt-and-braces guard on every path this type hands out —
    /// symlink-resolving, not lexical (a symlinked domains/ or domain file
    /// must not smuggle a read/write outside the dope root).
    private func contained(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        let resolved = standardized.resolvingSymlinksInPath()
        let resolvedRoot = dopeRoot.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(resolvedRoot.path + "/") else {
            throw SandboxError("path escapes the dope root: \(url.path)")
        }
        return standardized
    }

    // MARK: - Read

    public struct RepoBundle: Sendable {
        public let bundle: DopeDocumentBundle
        public let warnings: [String]
    }

    /// Reads `main.doped.json`, then ONLY the files main's map names — after
    /// re-deriving each value from its key (the map is data, never followed).
    /// Never globs the directory.
    public func readBundle() throws -> RepoBundle {
        let mainURL = mainFile
        guard FileManager.default.fileExists(atPath: mainURL.path) else {
            throw SandboxError("no dope tree on disk: \(mainURL.path) does not exist")
        }
        let main: DopeMainDocument
        do {
            let data = try Data(contentsOf: mainURL)
            main = try DopeDocumentCodec.decoder.decode(DopeMainDocument.self, from: data)
        } catch let error as DecodingError {
            throw SandboxError("main.doped.json failed to parse: \(error)")
        }

        var warnings: [String] = []
        var files: [DopeDomainFileDocument] = []
        for (code, mapped) in main.domains.sorted(by: { $0.key < $1.key }) {
            let expected = DopeMainDocument.expectedFile(forDomainCode: code)
            guard mapped == expected else {
                throw SandboxError(
                    "main.doped.json maps domain '\(code)' to '\(mapped)' — refused; expected '\(expected)' (the map is data, never followed)")
            }
            let url = try domainFile(code: code)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SandboxError("domain file missing: \(expected)")
            }
            do {
                let data = try Data(contentsOf: url)
                let file = try DopeDocumentCodec.decoder.decode(
                    DopeDomainFileDocument.self, from: data)
                if file.body.code != code {
                    throw SandboxError(
                        "domain file \(expected) declares code '\(file.body.code)' — file name and code must agree")
                }
                files.append(file)
            } catch let error as DecodingError {
                throw SandboxError("\(expected) failed to parse: \(error)")
            }
        }
        // Unreferenced *.doped.json files under domains/ are surfaced as
        // warnings on read (write-repo prunes them).
        for orphan in try unreferencedDomainFiles(referenced: Set(main.domains.keys)) {
            warnings.append("unreferenced domain file on disk: domains/\(orphan)")
        }
        return RepoBundle(bundle: DopeDocumentBundle(main: main, domainFiles: files),
                          warnings: warnings)
    }

    /// Peek at the on-disk revision without a full parse. Nil when no tree
    /// exists on disk.
    public func peekRevision() -> Int64? {
        guard let data = try? Data(contentsOf: mainFile),
              let main = try? DopeDocumentCodec.decoder.decode(DopeMainDocument.self, from: data)
        else { return nil }
        return main.version
    }

    // MARK: - Write

    public struct WriteResult: Sendable {
        public let written: [String]
        public let pruned: [String]
    }

    /// Atomic whole-tree write: the complete new tree is staged into
    /// `.gmcc/.dope-staging-{uuid}` and swapped in with replaceItemAt —
    /// same volume by construction, so a crash mid-write leaves the old
    /// tree byte-intact and a reader never sees a half-written domain set.
    /// `drawing_config.doped.json` is preserved if present, written blank
    /// only when absent (a future UX pass owns its content). Returned paths
    /// are instance-root-relative.
    public func writeAtomically(_ bundle: DopeDocumentBundle) throws -> WriteResult {
        let fm = FileManager.default
        let gmccDir = instanceRoot.appendingPathComponent(".gmcc", isDirectory: true)
        let staging = gmccDir.appendingPathComponent(
            ".dope-staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        let pruned = try unreferencedDomainFiles(
            referenced: Set(bundle.domainFiles.map(\.body.code)))
            .map { "\(DopeDocumentCodec.domainsDirectoryName)/\($0)" }

        try fm.createDirectory(
            at: staging.appendingPathComponent(DopeDocumentCodec.domainsDirectoryName,
                                               isDirectory: true),
            withIntermediateDirectories: true)

        var written: [String] = []
        func stage(_ data: Data, _ relative: String) throws {
            let url = staging.appendingPathComponent(relative)
            try data.write(to: url, options: .atomic)
            written.append(".gmcc/dope/" + relative)
        }
        try stage(DopeDocumentCodec.encoder.encode(bundle.main),
                  DopeDocumentCodec.mainFileName)
        for file in bundle.domainFiles {
            try DopeCode.validateCode(file.body.code, field: "domain code")
            try stage(DopeDocumentCodec.encoder.encode(file),
                      DopeMainDocument.expectedFile(forDomainCode: file.body.code))
        }
        // Preserve an existing drawing config verbatim; blank when absent.
        let existingDrawingConfig = try? Data(contentsOf: drawingConfigFile)
        try stage(existingDrawingConfig ?? Data("{}\n".utf8),
                  DopeDocumentCodec.drawingConfigFileName)

        if fm.fileExists(atPath: dopeRoot.path) {
            _ = try fm.replaceItemAt(dopeRoot, withItemAt: staging)
        } else {
            try fm.createDirectory(at: gmccDir, withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: dopeRoot)
        }
        return WriteResult(written: written.sorted(), pruned: pruned)
    }

    /// Bounded stale scan: exactly one non-recursive listing of `domains/`,
    /// matching only `*.doped.json`.
    private func unreferencedDomainFiles(referenced: Set<String>) throws -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: domainsDirectory.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: domainsDirectory.path)
            .filter { $0.hasSuffix(DopeDocumentCodec.domainFileSuffix) }
            .filter { name in
                let code = String(name.dropLast(DopeDocumentCodec.domainFileSuffix.count))
                return !referenced.contains(code)
            }
            .sorted()
    }
}
