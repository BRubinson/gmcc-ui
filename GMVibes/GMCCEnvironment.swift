import Foundation
import Observation

enum GMCCEnvKey: String, CaseIterable, Hashable {
    case ckfsRoot       = "GMCC_CKFS_ROOT"
    // The kbite roots survive only for the KBites browser's filesystem tabs;
    // they die when the daemon serves kbite tree listings (written goal).
    case kbiteDigested  = "GMCC_KBITE_DIGESTED"
    case kbiteOpen      = "GMCC_KBITE_OPEN"
}

/// Locator for the few filesystem roots the daemon can't answer yet (memory
/// files, folder-open actions, KBites browse tabs). Resolution order per key:
/// process environment → conventional-location probe → a single-key ~/.zshrc
/// scan. The old 140-line multi-variable shell parser/expander is gone — a
/// PATHS-style daemon message (written goal) retires this file entirely.
@Observable
@MainActor
final class GMCCEnvironment {
    private(set) var values: [GMCCEnvKey: String] = [:]

    subscript(key: GMCCEnvKey) -> String? { values[key] }

    var isLoaded: Bool { values[.ckfsRoot] != nil }

    init() {
        refresh()
    }

    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let zshrc = Self.scanZshrc(home: home)

        var out: [GMCCEnvKey: String] = [:]
        for key in GMCCEnvKey.allCases {
            if let value = env[key.rawValue], !value.isEmpty {
                out[key] = value
            } else if let value = zshrc[key], !value.contains("$") {
                // A value still containing "$" references a variable the
                // single-purpose scan couldn't expand — drop it so the
                // conventional-location probe below takes over instead of
                // surfacing a garbage literal path.
                out[key] = value
            }
        }
        // Conventional-location probe: the standard install puts the ckfs at
        // ~/gmcc_ckfs (and kbites under it).
        if out[.ckfsRoot] == nil {
            let conventional = home.appendingPathComponent("gmcc_ckfs")
            if FileManager.default.fileExists(atPath: conventional.path) {
                out[.ckfsRoot] = conventional.path
            }
        }
        if let root = out[.ckfsRoot] {
            let kbites = URL(fileURLWithPath: root).appendingPathComponent("kbites")
            if out[.kbiteDigested] == nil {
                let digested = kbites.appendingPathComponent("digested")
                if FileManager.default.fileExists(atPath: digested.path) {
                    out[.kbiteDigested] = digested.path
                }
            }
            if out[.kbiteOpen] == nil {
                let open = kbites.appendingPathComponent("open")
                if FileManager.default.fileExists(atPath: open.path) {
                    out[.kbiteOpen] = open.path
                }
            }
        }
        if values != out { values = out }
    }

    /// Minimal single-purpose scan: `export GMCC_*=...` lines only, with `~`
    /// and `$HOME`/`$GMCC_CKFS_ROOT` expansion — not a shell interpreter.
    private static func scanZshrc(home: URL) -> [GMCCEnvKey: String] {
        let zshrc = home.appendingPathComponent(".zshrc")
        guard let contents = try? String(contentsOf: zshrc, encoding: .utf8) else { return [:] }

        let pattern = /^\s*export\s+([A-Z_][A-Z0-9_]*)\s*=\s*(.+?)\s*$/
        var raw: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            guard let match = try? pattern.firstMatch(in: line) else { continue }
            raw[String(match.output.1)] = stripQuotes(String(match.output.2))
        }

        var out: [GMCCEnvKey: String] = [:]
        // ckfsRoot first, then GMCC_KBITE (a common intermediate the kbite
        // keys reference even though it's no longer surfaced as a key).
        var expansions = ["HOME": home.path]
        if let root = raw[GMCCEnvKey.ckfsRoot.rawValue].map({ expand($0, vars: expansions, home: home) }) {
            out[.ckfsRoot] = root
            expansions[GMCCEnvKey.ckfsRoot.rawValue] = root
        }
        if let kbite = raw["GMCC_KBITE"].map({ expand($0, vars: expansions, home: home) }) {
            expansions["GMCC_KBITE"] = kbite
        }
        for key in GMCCEnvKey.allCases where key != .ckfsRoot {
            if let value = raw[key.rawValue] {
                out[key] = expand(value, vars: expansions, home: home)
            }
        }
        return out
    }

    private static func stripQuotes(_ s: String) -> String {
        var value = s
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
           (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func expand(_ value: String, vars: [String: String], home: URL) -> String {
        var out = value
        if out == "~" {
            out = home.path
        } else if out.hasPrefix("~/") {
            out = home.appendingPathComponent(String(out.dropFirst(2))).path
        }
        for (name, replacement) in vars.sorted(by: { $0.key.count > $1.key.count }) {
            out = out.replacingOccurrences(of: "${\(name)}", with: replacement)
            out = out.replacingOccurrences(of: "$\(name)", with: replacement)
        }
        return out
    }
}
