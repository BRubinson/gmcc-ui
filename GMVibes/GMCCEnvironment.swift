import Foundation
import Observation

enum GMCCEnvKey: String, CaseIterable, Hashable {
    case ckfsRoot       = "GMCC_CKFS_ROOT"
    case kbite          = "GMCC_KBITE"
    case kbiteDigested  = "GMCC_KBITE_DIGESTED"
    case kbiteOpen      = "GMCC_KBITE_OPEN"
    case projects       = "GMCC_PROJECTS"
    case projectsIndex  = "GMCC_PROJECTS_INDEX"
}

// Runtime vars exported by detect_repo.sh on SessionStart (via $CLAUDE_ENV_FILE).
// These are not persisted to ~/.zshrc — they're per-session and only visible
// when the app is launched from a process that has them set.
enum GMCCRuntimeEnvKey: String, CaseIterable, Hashable {
    case booted       = "GMCC_BOOTED"
    case pluginRoot   = "GMCC_PLUGIN_ROOT"
    case projectPath  = "GMCC_PROJECT_PATH"
    case instancePath = "GMCC_INSTANCE_PATH"
    case sessionPath  = "GMCC_SESSION_PATH"
}

@Observable
@MainActor
final class GMCCEnvironment {
    private(set) var values: [GMCCEnvKey: String] = [:]
    private(set) var runtimeValues: [GMCCRuntimeEnvKey: String] = [:]

    subscript(key: GMCCEnvKey) -> String? { values[key] }
    subscript(runtime key: GMCCRuntimeEnvKey) -> String? { runtimeValues[key] }

    var isLoaded: Bool { values[.ckfsRoot] != nil }

    init() {
        refresh()
    }

    func refresh() {
        values = Self.scanZshrc()
        runtimeValues = Self.scanProcessEnvironment()
    }

    private static func scanProcessEnvironment() -> [GMCCRuntimeEnvKey: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [GMCCRuntimeEnvKey: String] = [:]
        for key in GMCCRuntimeEnvKey.allCases {
            if let value = env[key.rawValue], !value.isEmpty {
                out[key] = value
            }
        }
        return out
    }

    private static func scanZshrc() -> [GMCCEnvKey: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let zshrc = home.appendingPathComponent(".zshrc")

        guard let contents = try? String(contentsOf: zshrc, encoding: .utf8) else {
            return [:]
        }

        let raw = parseExports(contents)
        let resolved = resolve(raw, home: home)

        var out: [GMCCEnvKey: String] = [:]
        for key in GMCCEnvKey.allCases {
            if let value = resolved[key.rawValue] {
                out[key] = value
            }
        }
        return out
    }

    private static func parseExports(_ contents: String) -> [String: String] {
        let knownKeys = Set(GMCCEnvKey.allCases.map(\.rawValue))
        let pattern = /^\s*export\s+([A-Z_][A-Z0-9_]*)\s*=\s*(.+?)\s*$/

        var raw: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            guard let match = try? pattern.firstMatch(in: line) else { continue }

            let name = String(match.output.1)
            guard knownKeys.contains(name) else { continue }

            raw[name] = stripQuotes(String(match.output.2))
        }
        return raw
    }

    private static func resolve(_ raw: [String: String], home: URL) -> [String: String] {
        var resolved: [String: String] = ["HOME": home.path]
        let names = raw.keys

        for _ in 0..<8 {
            var changed = false
            for name in names {
                guard let rawValue = raw[name] else { continue }
                let expanded = expand(rawValue, vars: resolved, home: home)
                if resolved[name] != expanded {
                    resolved[name] = expanded
                    changed = true
                }
            }
            if !changed { break }
        }
        return resolved
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

        // Longest names first so $GMCC_KBITE_DIGESTED isn't shadowed by $GMCC_KBITE.
        let sortedNames = vars.keys.sorted { $0.count > $1.count }
        for name in sortedNames {
            guard let replacement = vars[name] else { continue }
            out = out.replacingOccurrences(of: "${\(name)}", with: replacement)
            out = out.replacingOccurrences(of: "$\(name)", with: replacement)
        }
        return out
    }
}
