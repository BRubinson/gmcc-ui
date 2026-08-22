import Foundation
import Observation

/// The exact rule `gm` uses to derive `session.code` from a git branch
/// (`GitContext.sessionCode` in the daemon's ContextOptions.swift): ONLY
/// `/` → `__`. No case folding, no punctuation folding.
///
/// Do NOT use `CkfsPathResolver.slug()` for branch comparison — that is the
/// prompt-FOLDER naming rule and folds far more aggressively; a branch like
/// `Feature/Login` or `release-v1.2` would silently never match its session.
enum GitSlug {
    static func sessionCode(forBranch branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "__")
    }
}

/// Where the checked-out-branch signal comes from. Placeholder implementation
/// reads the repo directly; a future daemon call (SESSION_RESOLVE /
/// INSTANCE_CURRENT_SESSION — written as a goal to the gmcc project) replaces
/// it behind this protocol.
protocol CheckedOutBranchSource: Sendable {
    /// The branch checked out at a repo root, or nil (detached HEAD, not a
    /// repo, unreadable).
    func branch(atRepoRoot root: String) -> String?
}

/// Reads `.git/HEAD` — a tiny `ref: refs/heads/<branch>` file — instead of
/// spawning `git`: a syscall, not a subprocess, and it needs no daemon
/// traffic, so the serial-queue fairness constraint can't be violated.
struct GitHeadFileReader: CheckedOutBranchSource {
    func branch(atRepoRoot root: String) -> String? {
        guard let head = try? String(contentsOf: Self.headURL(forRepoRoot: root), encoding: .utf8)
        else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }   // detached HEAD
        return String(trimmed.dropFirst("ref: refs/heads/".count))
    }

    /// Resolves worktree/submodule indirection: `.git` may be a FILE reading
    /// `gitdir: <path>`.
    static func gitDirURL(forRepoRoot root: String) -> URL {
        // isDirectory: true — a file-typed base drops its last component
        // during relative resolution, sending submodule gitdirs one level up.
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        let dotGit = rootURL.appendingPathComponent(".git")
        if let marker = try? String(contentsOf: dotGit, encoding: .utf8),
           marker.hasPrefix("gitdir:") {
            let path = String(marker.dropFirst("gitdir:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: path, relativeTo: rootURL)
            return url.standardizedFileURL
        }
        return dotGit
    }

    static func headURL(forRepoRoot root: String) -> URL {
        gitDirURL(forRepoRoot: root).appendingPathComponent("HEAD")
    }
}

/// Per-instance checked-out-branch cache. Event-driven: a DispatchSource
/// watches each watched instance's `.git` directory and re-reads HEAD on
/// change — no polling loop, no timer, no git subprocess. Views track
/// `branchByInstance` through @Observable; no invalidation domain needed.
@Observable
@MainActor
final class CheckoutWatcher {
    /// Branch (raw, un-slugged) by instance uuid. nil entry = unknown/detached.
    private(set) var branchByInstance: [String: String] = [:]

    private let source: CheckedOutBranchSource
    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var watchedPaths: [String: String] = [:]   // instanceUuid → repo root

    init(source: CheckedOutBranchSource = GitHeadFileReader()) {
        self.source = source
    }

    /// Is this session the checked-out one on its instance?
    /// `session.code` IS the slugged branch (GitSlug rule).
    func isCheckedOut(sessionCode: String, instanceUuid: String) -> Bool {
        guard let branch = branchByInstance[instanceUuid] else { return false }
        return GitSlug.sessionCode(forBranch: branch) == sessionCode
    }

    /// The slugged code of the checked-out branch on an instance (to find the
    /// matching session row), or nil.
    func checkedOutCode(instanceUuid: String) -> String? {
        branchByInstance[instanceUuid].map(GitSlug.sessionCode(forBranch:))
    }

    /// (Re)target the watcher set. One read + one DispatchSource per instance;
    /// instances whose repo path vanished are dropped.
    func watch(instances: [(uuid: String, repoPath: String)]) {
        let wanted = Dictionary(instances.map { ($0.uuid, $0.repoPath) },
                                uniquingKeysWith: { first, _ in first })

        for uuid in watchedPaths.keys where wanted[uuid] == nil {
            dropWatcher(instanceUuid: uuid)
        }

        for (uuid, path) in wanted {
            ensureWatching(instanceUuid: uuid, repoPath: path)
        }
    }

    /// Add one instance to the watch set without dropping the others (the
    /// instance page calls this defensively; `watch(instances:)` replaces).
    /// A failed `open()` is NOT recorded, so a repo that appears later (clone
    /// in progress, unmounted volume) gets retried on the next call.
    func ensureWatching(instanceUuid: String, repoPath: String) {
        refresh(instanceUuid: instanceUuid, repoPath: repoPath)
        if watchedPaths[instanceUuid] != repoPath {
            watchers[instanceUuid]?.cancel()
            watchers[instanceUuid] = nil
            watchedPaths[instanceUuid] = nil
            if let watcher = makeWatcher(instanceUuid: instanceUuid, repoPath: repoPath) {
                watchers[instanceUuid] = watcher
                watchedPaths[instanceUuid] = repoPath
            }
        }
    }

    private func dropWatcher(instanceUuid: String) {
        watchers[instanceUuid]?.cancel()
        watchers[instanceUuid] = nil
        watchedPaths[instanceUuid] = nil
        if branchByInstance[instanceUuid] != nil {
            branchByInstance[instanceUuid] = nil
        }
    }

    private func refresh(instanceUuid: String, repoPath: String) {
        let branch = source.branch(atRepoRoot: repoPath)
        if branchByInstance[instanceUuid] != branch {
            branchByInstance[instanceUuid] = branch
        }
    }

    private func makeWatcher(instanceUuid: String, repoPath: String) -> DispatchSourceFileSystemObject? {
        let gitDir = GitHeadFileReader.gitDirURL(forRepoRoot: repoPath)
        let fd = open(gitDir.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        watcher.setEventHandler { [weak self] in
            guard let self else { return }
            let mask = self.watchers[instanceUuid]?.data ?? []
            if mask.contains(.delete) || mask.contains(.rename) {
                // The watched inode was replaced (re-clone, worktree remove) —
                // the source is dead. Drop and re-arm against the new .git.
                self.watchers[instanceUuid]?.cancel()
                self.watchers[instanceUuid] = nil
                self.watchedPaths[instanceUuid] = nil
                self.ensureWatching(instanceUuid: instanceUuid, repoPath: repoPath)
            } else {
                self.refresh(instanceUuid: instanceUuid, repoPath: repoPath)
            }
        }
        watcher.setCancelHandler { close(fd) }
        watcher.resume()
        return watcher
    }
}
