import Foundation
import GMCCDaemonKit

/// App-facing typed error surface. Views and stores branch on these cases —
/// never on message text — per the daemon's typed-code contract.
nonisolated enum DaemonError: Error, Equatable {
    /// Binary absent at ~/gmcc/bin/gmcc_daemon (distinct from a stopped daemon).
    case notInstalled
    /// Socket dead and autostart disabled (or autostart exhausted its retries).
    case unreachable(String)
    /// Daemon is newer than our linked GMCCDaemonKit — rebuild GMVibes /
    /// update the package. Starting the daemon cannot fix this state.
    case clientTooOld(daemonVersion: Int)
    /// Daemon reported an older protocol and the kit's respawn cycle still
    /// failed to retire it.
    case daemonTooOld(daemonVersion: Int?, message: String)
    case notFound
    case versionConflict
    case invalidTransition
    case contentLocked
    /// Any other server-reported code (BAD_REQUEST, DB_ERROR, …) — surfaced
    /// verbatim so e.g. a schema re-baseline DB_ERROR stays diagnosable.
    case server(code: String, message: String)
    /// Wire-level encode/decode/socket failure.
    case transport(String)

    init(_ error: Error) {
        if let already = error as? DaemonError {
            self = already
            return
        }
        guard let clientError = error as? DaemonClientError else {
            self = .transport(String(describing: error))
            return
        }
        switch clientError {
        case .unreachable(let message):
            // "Never installed" and "installed but stopped" are different UI
            // states; classify before reporting unreachable.
            if FileManager.default.isExecutableFile(atPath: Paths.binDaemon.path) {
                self = .unreachable(message)
            } else {
                self = .notInstalled
            }
        case .protocolMismatch(let message, let daemonVersion):
            if let daemonVersion, daemonVersion >= GMCCWireProtocol.version {
                self = .clientTooOld(daemonVersion: daemonVersion)
            } else {
                self = .daemonTooOld(daemonVersion: daemonVersion, message: message)
            }
        case .server(let payload):
            switch payload.code {
            case .notFound: self = .notFound
            case .versionConflict: self = .versionConflict
            case .invalidTransition: self = .invalidTransition
            case .contentLocked: self = .contentLocked
            default: self = .server(code: payload.codeRaw, message: payload.message)
            }
        case .wire(let message):
            self = .transport(message)
        }
    }
}

nonisolated extension UUID {
    /// The db and the ckfs yamls store lowercase v4 uuids and SQLite TEXT
    /// comparison is case-sensitive; Swift's `uuidString` emits uppercase.
    /// Every uuid crossing the wire goes through this.
    var wireString: String { uuidString.lowercased() }
}
