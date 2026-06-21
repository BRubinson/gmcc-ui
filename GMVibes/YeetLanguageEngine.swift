import Foundation

// Minimal indentation-driven YAML parser tailored to the YEETS dialect:
// - two-space indent
// - mapping keys end in `:`
// - sequence items prefixed with `- `
// - block scalars introduced with `|` (literal) or `>` (folded), trailing `-`/`+` chomping ignored
// - inline values are scalars (string, int, uuid, version) — no flow style, no anchors, no tags
// - `# …` line comments
//
// Anything outside this dialect is preserved as a string scalar — the viewer is
// read-only and we only need to surface known top-level shapes.

enum YeetLanguageEngine {
    static func parse(url: URL) throws -> YeetDocument {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw YeetParseError.readFailed(error.localizedDescription)
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> YeetDocument {
        var parser = LineParser(text: text)
        guard case let .mapping(root) = try parser.parseNode(indent: 0) else {
            throw YeetParseError.invalidShape(line: 1, reason: "top-level must be a mapping")
        }

        let header = Self.buildHeader(from: root)
        let sections = Self.buildSections(from: root["sections"])

        return YeetDocument(header: header, sections: sections, sourceText: text)
    }

    // MARK: - Header

    private static func buildHeader(from root: [String: YeetYAML]) -> YeetHeader {
        var header = YeetHeader()
        header.name = root["name"]?.scalarString
        header.uuid = root["uuid"]?.scalarString
        header.package = root["package"]?.scalarString
        header.yeetVersion = root["yeet_version"]?.scalarString
        header.description = root["description"]?.scalarString

        if case let .sequence(items)? = root["yeet"] {
            header.imports = items.compactMap { $0.scalarString }
        }

        return header
    }

    // MARK: - Sections

    private static func buildSections(from node: YeetYAML?) -> [YeetSection] {
        guard case let .mapping(map)? = node else { return [] }
        // Preserve source order using the orderedKeys carried alongside the mapping.
        let keys = map.orderedKeys ?? Array(map.keys)
        return keys.compactMap { name in
            guard case let .mapping(body)? = map[name] else { return nil }
            return buildSection(name: name, body: body)
        }
    }

    private static func buildSection(name: String, body: [String: YeetYAML]) -> YeetSection {
        var section = YeetSection(name: name)
        section.description = body["description"]?.scalarString

        if case let .mapping(structsMap)? = body["structs"] {
            let keys = structsMap.orderedKeys ?? Array(structsMap.keys)
            section.structs = keys.compactMap { sName -> YeetStructDecl? in
                guard case let .mapping(sBody)? = structsMap[sName] else { return nil }
                return buildStruct(name: sName, body: sBody)
            }
        }

        if case let .mapping(enumsMap)? = body["enums"] {
            let keys = enumsMap.orderedKeys ?? Array(enumsMap.keys)
            section.enums = keys.compactMap { eName -> YeetEnumDecl? in
                guard case let value? = enumsMap[eName] else { return nil }
                return buildEnum(name: eName, value: value)
            }
        }

        return section
    }

    private static func buildStruct(name: String, body: [String: YeetYAML]) -> YeetStructDecl {
        var decl = YeetStructDecl(name: name)
        decl.description = body["description"]?.scalarString

        if case let .mapping(fieldsMap)? = body["fields"] {
            let keys = fieldsMap.orderedKeys ?? Array(fieldsMap.keys)
            decl.fields = keys.compactMap { fName -> YeetField? in
                guard let rawType = fieldsMap[fName]?.scalarString else { return nil }
                return buildField(name: fName, rawType: rawType)
            }
        }

        return decl
    }

    private static func buildEnum(name: String, value: YeetYAML) -> YeetEnumDecl {
        var decl = YeetEnumDecl(name: name)
        switch value {
        case let .mapping(body):
            decl.description = body["description"]?.scalarString
            if case let .sequence(items)? = body["cases"] {
                decl.cases = items.compactMap { $0.scalarString }
            }
        case let .sequence(items):
            decl.cases = items.compactMap { $0.scalarString }
        case .scalar:
            break
        }
        return decl
    }

    private static func buildField(name: String, rawType: String) -> YeetField {
        let trimmed = rawType.trimmingCharacters(in: .whitespaces)
        if let unwrapped = unwrapInner(trimmed) {
            return YeetField(name: name, rawType: trimmed, isUnwrap: true, unwrappedType: unwrapped)
        }
        return YeetField(name: name, rawType: trimmed, isUnwrap: false, unwrappedType: nil)
    }

    private static func unwrapInner(_ raw: String) -> String? {
        let prefix = "Unwrap<"
        guard raw.hasPrefix(prefix), raw.hasSuffix(">") else { return nil }
        let start = raw.index(raw.startIndex, offsetBy: prefix.count)
        let end = raw.index(before: raw.endIndex)
        guard start < end else { return nil }
        return String(raw[start..<end])
    }
}

// MARK: - YAML value type

indirect enum YeetYAML: Equatable {
    case scalar(String)
    case mapping([String: YeetYAML])
    case sequence([YeetYAML])

    var scalarString: String? {
        if case let .scalar(s) = self { return s }
        return nil
    }
}

// Carry the original key order on mappings so the renderer matches source order.
// We tag it on the dictionary via an associated reference object stored in a
// `_orderedKeys_` slot kept by the parser. Swift dicts don't preserve order;
// we sidecar the order list into a magic key that we strip on lookup.
private extension Dictionary where Key == String, Value == YeetYAML {
    var orderedKeys: [String]? {
        if case let .sequence(items)? = self["__yeet_ordered_keys__"] {
            return items.compactMap { $0.scalarString }
        }
        return nil
    }
}

// MARK: - Line parser

private struct LineParser {
    let lines: [String]
    var cursor: Int = 0

    init(text: String) {
        self.lines = text.components(separatedBy: "\n")
    }

    // MARK: Public entry — parses a node starting at the current cursor for the
    // given parent indent. Returns when a line with less indent is encountered.

    mutating func parseNode(indent: Int) throws -> YeetYAML {
        skipBlank()
        guard cursor < lines.count else { return .mapping([:]) }

        let first = lines[cursor]
        let firstIndent = leadingSpaces(first)
        let payload = first.dropFirst(firstIndent)

        if payload.hasPrefix("- ") || payload == "-" {
            return try parseSequence(indent: firstIndent)
        }
        return try parseMapping(indent: firstIndent == 0 ? 0 : firstIndent)
    }

    private mutating func parseMapping(indent: Int) throws -> YeetYAML {
        var map: [String: YeetYAML] = [:]
        var order: [String] = []

        while cursor < lines.count {
            skipBlank()
            guard cursor < lines.count else { break }

            let line = lines[cursor]
            let lineIndent = leadingSpaces(line)
            if lineIndent < indent { break }
            if lineIndent > indent {
                // Unexpected indent — skip to recover.
                cursor += 1
                continue
            }

            let payload = line.dropFirst(lineIndent)
            if payload.hasPrefix("- ") || payload == "-" {
                // sequence item at mapping level — caller's problem.
                break
            }

            guard let colonIdx = findKeyColon(payload) else {
                cursor += 1
                continue
            }

            let key = String(payload[..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let afterColon = payload.index(after: colonIdx)
            let valuePart = String(payload[afterColon...]).trimmingCharacters(in: .whitespaces)
            cursor += 1

            if valuePart.isEmpty {
                let nested = try parseNestedValue(parentIndent: indent)
                map[key] = nested
            } else if valuePart == "|" || valuePart == ">" ||
                      valuePart == "|-" || valuePart == "|+" ||
                      valuePart == ">-" || valuePart == ">+" {
                let folded = valuePart.hasPrefix(">")
                let block = readBlockScalar(parentIndent: indent, folded: folded)
                map[key] = .scalar(block)
            } else if valuePart == "[]" {
                map[key] = .sequence([])
            } else if valuePart == "{}" {
                map[key] = .mapping([:])
            } else {
                map[key] = .scalar(unquote(valuePart))
            }
            order.append(key)
        }

        if !order.isEmpty {
            map["__yeet_ordered_keys__"] = .sequence(order.map { .scalar($0) })
        }
        return .mapping(map)
    }

    private mutating func parseSequence(indent: Int) throws -> YeetYAML {
        var items: [YeetYAML] = []

        while cursor < lines.count {
            skipBlank()
            guard cursor < lines.count else { break }

            let line = lines[cursor]
            let lineIndent = leadingSpaces(line)
            if lineIndent < indent { break }
            if lineIndent > indent {
                cursor += 1
                continue
            }

            let payload = line.dropFirst(lineIndent)
            if !(payload.hasPrefix("- ") || payload == "-") {
                break
            }

            let afterDash: String
            if payload == "-" {
                afterDash = ""
            } else {
                afterDash = String(payload.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }

            if afterDash.isEmpty {
                cursor += 1
                let nested = try parseNestedValue(parentIndent: indent)
                items.append(nested)
                continue
            }

            // Inline sequence value: either `- foo` (scalar) or `- key: value` (mapping).
            if let colonIdx = findKeyColon(Substring(afterDash)) {
                // Treat the rest of this line + any deeper-indented continuation
                // as a single mapping item. Rewrite the current line to start
                // after the dash and re-enter parseMapping at indent+2.
                let key = String(Substring(afterDash)[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let after = Substring(afterDash).index(after: colonIdx)
                let valuePart = String(Substring(afterDash)[after...]).trimmingCharacters(in: .whitespaces)
                let itemIndent = indent + 2
                cursor += 1

                var map: [String: YeetYAML] = [:]
                var order: [String] = []
                if valuePart.isEmpty {
                    map[key] = try parseNestedValue(parentIndent: itemIndent)
                } else {
                    map[key] = .scalar(unquote(valuePart))
                }
                order.append(key)

                // Continue eating same-indent keys belonging to this item.
                while cursor < lines.count {
                    skipBlank()
                    guard cursor < lines.count else { break }
                    let l = lines[cursor]
                    let li = leadingSpaces(l)
                    if li != itemIndent { break }
                    let p = l.dropFirst(li)
                    if p.hasPrefix("- ") || p == "-" { break }
                    guard let cIdx = findKeyColon(p) else { cursor += 1; continue }
                    let k = String(p[..<cIdx]).trimmingCharacters(in: .whitespaces)
                    let aft = p.index(after: cIdx)
                    let vp = String(p[aft...]).trimmingCharacters(in: .whitespaces)
                    cursor += 1
                    if vp.isEmpty {
                        map[k] = try parseNestedValue(parentIndent: itemIndent)
                    } else if vp == "|" || vp == ">" || vp == "|-" || vp == "|+" || vp == ">-" || vp == ">+" {
                        map[k] = .scalar(readBlockScalar(parentIndent: itemIndent, folded: vp.hasPrefix(">")))
                    } else if vp == "[]" {
                        map[k] = .sequence([])
                    } else if vp == "{}" {
                        map[k] = .mapping([:])
                    } else {
                        map[k] = .scalar(unquote(vp))
                    }
                    order.append(k)
                }
                if !order.isEmpty {
                    map["__yeet_ordered_keys__"] = .sequence(order.map { .scalar($0) })
                }
                items.append(.mapping(map))
            } else {
                items.append(.scalar(unquote(afterDash)))
                cursor += 1
            }
        }

        return .sequence(items)
    }

    private mutating func parseNestedValue(parentIndent: Int) throws -> YeetYAML {
        skipBlank()
        guard cursor < lines.count else { return .mapping([:]) }
        let line = lines[cursor]
        let lineIndent = leadingSpaces(line)
        if lineIndent <= parentIndent { return .mapping([:]) }

        let payload = line.dropFirst(lineIndent)
        if payload.hasPrefix("- ") || payload == "-" {
            return try parseSequence(indent: lineIndent)
        }
        return try parseMapping(indent: lineIndent)
    }

    // MARK: Helpers

    private mutating func skipBlank() {
        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                cursor += 1
            } else {
                break
            }
        }
    }

    private func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 } else { break }
        }
        return count
    }

    private func findKeyColon(_ payload: Substring) -> Substring.Index? {
        // First top-level `: ` (or trailing `:`) outside quotes/brackets.
        var inSingle = false
        var inDouble = false
        var depth = 0
        var i = payload.startIndex
        while i < payload.endIndex {
            let c = payload[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if !inSingle && !inDouble {
                if c == "<" || c == "[" || c == "{" { depth += 1 }
                else if c == ">" || c == "]" || c == "}" { depth = max(0, depth - 1) }
                else if c == ":" && depth == 0 {
                    let next = payload.index(after: i)
                    if next == payload.endIndex || payload[next] == " " { return i }
                }
            }
            i = payload.index(after: i)
        }
        return nil
    }

    private mutating func readBlockScalar(parentIndent: Int, folded: Bool) -> String {
        var captured: [String] = []
        var blockIndent: Int? = nil

        while cursor < lines.count {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                captured.append("")
                cursor += 1
                continue
            }
            let lineIndent = leadingSpaces(line)
            if lineIndent <= parentIndent { break }
            if blockIndent == nil { blockIndent = lineIndent }
            let strip = min(blockIndent ?? lineIndent, lineIndent)
            let content = String(line.dropFirst(strip))
            captured.append(content)
            cursor += 1
        }

        // Trim trailing empties.
        while let last = captured.last, last.isEmpty {
            captured.removeLast()
        }

        if folded {
            // Collapse runs of non-empty lines into a single line separated by spaces;
            // blank lines become a paragraph break.
            var out: [String] = []
            var run: [String] = []
            for line in captured {
                if line.isEmpty {
                    if !run.isEmpty {
                        out.append(run.joined(separator: " "))
                        run.removeAll()
                    }
                    out.append("")
                } else {
                    run.append(line)
                }
            }
            if !run.isEmpty { out.append(run.joined(separator: " ")) }
            return out.joined(separator: "\n")
        }
        return captured.joined(separator: "\n")
    }

    private func unquote(_ s: String) -> String {
        var v = s
        // Strip trailing inline comments — only when there's a `# ` outside quotes.
        if let hash = findInlineComment(v) {
            v = String(v[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) ||
           (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    private func findInlineComment(_ s: String) -> String.Index? {
        var inSingle = false
        var inDouble = false
        var i = s.startIndex
        var prev: Character = " "
        while i < s.endIndex {
            let c = s[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if c == "#" && !inSingle && !inDouble && prev == " " {
                return i
            }
            prev = c
            i = s.index(after: i)
        }
        return nil
    }
}
