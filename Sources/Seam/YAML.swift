import Foundation

/// The small YAML subset Seam's config files use: block maps, block lists, nested maps and lists, quoted and plain
/// scalars, `#` comments, and `[]` / `{}` for empty collections. No anchors, tags, multi-line scalars or flow
/// collections with content.
indirect enum YAML {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([YAML])
    case map([(key: String, value: YAML)])

    subscript(key: String) -> YAML? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): b
        case .string(let s) where ["yes", "on"].contains(s.lowercased()): true
        case .string(let s) where ["no", "off"].contains(s.lowercased()): false
        default: nil
        }
    }

    var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s)
        default: nil
        }
    }

    var items: [YAML] {
        if case .list(let l) = self { return l }
        return []
    }
}

// MARK: - Parsing

extension YAML {
    private struct Line {
        var indent: Int
        var text: String
    }

    /// Returns nil for text that is not valid in the subset (bad indentation, a key with no colon, ...).
    static func parse(_ source: String) -> YAML? {
        var lines: [Line] = []
        for raw in source.components(separatedBy: .newlines) {
            let stripped = stripComment(raw).replacingOccurrences(of: "\t", with: "  ")
            let text = stripped.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "---" { continue }
            lines.append(Line(indent: stripped.prefix { $0 == " " }.count, text: text))
        }
        guard !lines.isEmpty else { return .map([]) }
        var i = 0
        guard let value = parseBlock(&lines, &i, indent: lines[0].indent), i == lines.count else { return nil }
        return value
    }

    private static func parseBlock(_ lines: inout [Line], _ i: inout Int, indent: Int) -> YAML? {
        guard i < lines.count else { return .null }
        return isListItem(lines[i].text) ? parseList(&lines, &i, indent: indent) : parseMap(&lines, &i, indent: indent)
    }

    private static func isListItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") }

    private static func parseMap(_ lines: inout [Line], _ i: inout Int, indent: Int) -> YAML? {
        var pairs: [(key: String, value: YAML)] = []
        while i < lines.count, lines[i].indent == indent, !isListItem(lines[i].text) {
            guard let (key, rest) = splitKey(lines[i].text) else { return nil }
            i += 1
            if !rest.isEmpty {
                pairs.append((key, parseScalar(rest)))
            } else if i < lines.count, lines[i].indent > indent {
                guard let nested = parseBlock(&lines, &i, indent: lines[i].indent) else { return nil }
                pairs.append((key, nested))
            } else if i < lines.count, lines[i].indent == indent, isListItem(lines[i].text) {
                // "key:" followed by a list written at the same indent.
                guard let nested = parseList(&lines, &i, indent: indent) else { return nil }
                pairs.append((key, nested))
            } else {
                pairs.append((key, .null))
            }
        }
        return .map(pairs)
    }

    private static func parseList(_ lines: inout [Line], _ i: inout Int, indent: Int) -> YAML? {
        var items: [YAML] = []
        while i < lines.count, lines[i].indent == indent, isListItem(lines[i].text) {
            let text = lines[i].text
            let rest = text == "-" ? "" : String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty {
                i += 1
                if i < lines.count, lines[i].indent > indent {
                    guard let nested = parseBlock(&lines, &i, indent: lines[i].indent) else { return nil }
                    items.append(nested)
                } else {
                    items.append(.null)
                }
            } else if isListItem(rest) {
                return nil
            } else if splitKey(rest) != nil, !isQuotedScalar(rest) {
                // "- key: value": the item is a map whose first pair sits on the dash line.
                let inner = indent + (text.count - rest.count)
                lines[i] = Line(indent: inner, text: rest)
                guard let map = parseMap(&lines, &i, indent: inner) else { return nil }
                items.append(map)
            } else {
                items.append(parseScalar(rest))
                i += 1
            }
        }
        return .list(items)
    }

    private static func isQuotedScalar(_ s: String) -> Bool {
        guard let first = s.first, first == "\"" || first == "'" else { return false }
        return s.count >= 2 && s.last == first
    }

    /// Splits "key: value" (value may be empty). Keys may be quoted.
    private static func splitKey(_ text: String) -> (String, String)? {
        var key = ""
        var rest = Substring(text)
        if let q = rest.first, q == "\"" || q == "'" {
            guard let end = closingQuote(in: rest) else { return nil }
            key = unquote(String(rest[rest.startIndex...end]))
            rest = rest[rest.index(after: end)...]
            guard rest.hasPrefix(":") else { return nil }
            rest = rest.dropFirst()
        } else {
            guard let colon = text.indices.first(where: { text[$0] == ":" && (text.index(after: $0) == text.endIndex || text[text.index(after: $0)] == " ") })
            else { return nil }
            key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            rest = text[text.index(after: colon)...]
        }
        guard !key.isEmpty else { return nil }
        return (key, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func closingQuote(in s: Substring) -> String.Index? {
        guard let q = s.first else { return nil }
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            if q == "\"", s[i] == "\\" { i = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex; continue }
            if s[i] == q {
                if q == "'", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "'" { i = s.index(i, offsetBy: 2); continue }
                return i
            }
            i = s.index(after: i)
        }
        return nil
    }

    private static func parseScalar(_ s: String) -> YAML {
        if isQuotedScalar(s) { return .string(unquote(s)) }
        switch s {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case "[]": return .list([])
        case "{}": return .map([])
        default: break
        }
        if let i = Int(s) { return .int(i) }
        if s.contains("."), let d = Double(s) { return .double(d) }
        return .string(s)
    }

    private static func unquote(_ s: String) -> String {
        let body = String(s.dropFirst().dropLast())
        if s.first == "'" { return body.replacingOccurrences(of: "''", with: "'") }
        var out = ""
        var escaped = false
        for ch in body {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Drops a trailing `# comment`. A `#` only starts one after whitespace and outside quotes. Hand-edited themes
    /// often leave colors unquoted (`background: #1d2027`), so a hex color in value position is kept.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var prev: Character = " "
        let chars = Array(line)
        for (idx, ch) in chars.enumerated() {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'", prev == " " || prev == ":" || prev == "-" || prev == "[" {
                quote = ch
            } else if ch == "#", prev == " " || idx == 0 {
                let before = String(chars[..<idx]).trimmingCharacters(in: .whitespaces)
                if before.hasSuffix(":") || before.hasSuffix("-") {
                    let word = chars[idx...].prefix { !$0.isWhitespace }
                    let hex = word.dropFirst()
                    if (3...8).contains(hex.count), hex.allSatisfy(\.isHexDigit) { prev = ch; continue }
                }
                return String(chars[..<idx])
            }
            prev = ch
        }
        return line
    }
}

// MARK: - Writing

extension YAML {
    /// Renders the value as a document, optionally preceded by `#` comment lines.
    func render(header: String? = nil) -> String {
        var out = ""
        if let header { out += header.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "#" : "# \($0)" }.joined(separator: "\n") + "\n\n" }
        out += Self.lines(of: self, indent: 0).joined(separator: "\n")
        return out + "\n"
    }

    private static func lines(of value: YAML, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch value {
        case .map(let pairs):
            return pairs.flatMap { key, v -> [String] in
                switch v {
                case .map(let inner) where !inner.isEmpty: return ["\(pad)\(scalar(key)):"] + lines(of: v, indent: indent + 2)
                case .list(let inner) where !inner.isEmpty: return ["\(pad)\(scalar(key)):"] + lines(of: v, indent: indent + 2)
                default: return ["\(pad)\(scalar(key)): \(inline(v))"]
                }
            }
        case .list(let items):
            return items.flatMap { item -> [String] in
                guard case .map(let pairs) = item, !pairs.isEmpty else { return ["\(pad)- \(inline(item))"] }
                var out = lines(of: item, indent: indent + 2)
                out[0] = "\(pad)- " + out[0].dropFirst(indent + 2)
                return out
            }
        default:
            return ["\(pad)\(inline(value))"]
        }
    }

    private static func inline(_ v: YAML) -> String {
        switch v {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double(let d): d == d.rounded() && abs(d) < 1e9 ? String(format: "%.1f", d) : String(d)
        case .string(let s): scalar(s)
        case .list: "[]"
        case .map: "{}"
        }
    }

    /// A string, quoted only when a plain scalar would read back as something else.
    private static func scalar(_ s: String) -> String {
        let needsQuotes = s.isEmpty
            || s != s.trimmingCharacters(in: .whitespaces)
            || s.contains(": ") || s.contains(" #") || s.hasSuffix(":")
            || s.contains("\n") || s.contains("\"") || s.contains("\\") || s.contains("\t")
            || "#&*!|>'%@`[]{},-?:".contains(s.first!)
            || ["~", "null", "true", "false", "yes", "no", "on", "off"].contains(s.lowercased())
            || Int(s) != nil || Double(s) != nil
        guard needsQuotes else { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
