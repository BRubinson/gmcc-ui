import Foundation
import Observation

enum GMCCEnvKey: String, CaseIterable, Hashable {
    case ckfsRoot      = "GMCC_CKFS_ROOT"
    case kbite         = "GMCC_KBITE"
    case kbiteDigested = "GMCC_KBITE_DIGESTED"
    case kbiteOpen     = "GMCC_KBITE_OPEN"
}

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
        values = Self.scanZshrc()
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
