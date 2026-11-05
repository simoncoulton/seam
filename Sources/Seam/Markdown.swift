import SwiftUI

/// Block-level Markdown for the preview pane. Inline styling (bold, italic, code, links) comes from
/// `AttributedString(markdown:)`; the blocks are parsed here because SwiftUI's `Text` ignores block structure.
enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    /// `marker` is a bullet, an ordinal such as "1.", or "[ ]" / "[x]" for task items.
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]], aligns: [HorizontalAlignment])
    case image(alt: String, src: String)
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var para: [String] = []
        var quote: [String] = []
        var fence: [String]?

        func flush() {
            if !para.isEmpty { addText(para.joined(separator: " ")); para = [] }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }
        /// Images become their own blocks, after the text of the paragraph they came from.
        func addText(_ text: String) {
            let (rest, images) = extractImages(text)
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { blocks.append(.paragraph(rest)) }
            blocks.append(contentsOf: images)
        }

        let lines = source.components(separatedBy: .newlines).map { $0.replacingOccurrences(of: "\t", with: "    ") }
        var n = 0
        while n < lines.count {
            let line = lines[n]
            n += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    blocks.append(.code(fence!.joined(separator: "\n"))); fence = nil
                } else { fence!.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { flush(); fence = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { flush(); blocks.append(.rule); continue }
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = trimmed[m].filter { $0 == "#" }.count
                let text = trimmed[m.upperBound...].replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
                blocks.append(.heading(level, text)); continue
            }
            if trimmed.hasPrefix(">") {
                if !para.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            // A pipe row followed by a delimiter row (---|:-:) starts a table.
            if trimmed.contains("|"), n < lines.count, let aligns = tableAligns(lines[n]) {
                let header = cells(trimmed)
                if header.count == aligns.count {
                    flush()
                    var rows: [[String]] = []
                    n += 1
                    while n < lines.count, lines[n].contains("|"),
                          !lines[n].trimmingCharacters(in: .whitespaces).isEmpty {
                        var row = cells(lines[n])
                        row = Array((row + Array(repeating: "", count: aligns.count)).prefix(aligns.count))
                        rows.append(row)
                        n += 1
                    }
                    blocks.append(.table(header: header, rows: rows, aligns: aligns))
                    continue
                }
            }
            if let m = trimmed.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flush()
                let marker = trimmed[m].trimmingCharacters(in: .whitespaces)
                let indent = (line.prefix { $0 == " " }.count) / 2
                var text = String(trimmed[m.upperBound...])
                var shown = marker.first!.isNumber ? marker : "•"
                if let t = text.range(of: #"^\[( |x|X)\]\s+"#, options: .regularExpression) {
                    shown = text[t].dropFirst().first == " " ? "[ ]" : "[x]"
                    text = String(text[t.upperBound...])
                }
                blocks.append(.bullet(indent: indent, marker: shown, text: text))
                continue
            }
            if line.hasPrefix("    "), para.isEmpty, case .bullet = blocks.last { // wrapped list item
                if case .bullet(let i, let mk, let t) = blocks.removeLast() { blocks.append(.bullet(indent: i, marker: mk, text: t + " " + trimmed)) }
                continue
            }
            if !quote.isEmpty { flush() }
            para.append(trimmed)
        }
        if let fence { blocks.append(.code(fence.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func cells(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
        return s.replacingOccurrences(of: "\\|", with: "\u{0}").components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    private static func tableAligns(_ line: String) -> [HorizontalAlignment]? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.contains("-"), s.range(of: #"^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$"#, options: .regularExpression) != nil else { return nil }
        return cells(s).map { c in
            if c.hasPrefix(":") && c.hasSuffix(":") { return .center }
            return c.hasSuffix(":") ? .trailing : .leading
        }
    }

    private static func extractImages(_ text: String) -> (String, [MarkdownBlock]) {
        let image = #"!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#
        // `[![badge](img)](link)`: keep the image, drop the link around it.
        var rest = text.replacingOccurrences(of: #"\[(\#(image))\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        var found: [MarkdownBlock] = []
        guard let re = try? NSRegularExpression(pattern: image) else { return (text, []) }
        let ns = rest as NSString
        for m in re.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
            found.append(.image(alt: ns.substring(with: m.range(at: 1)), src: ns.substring(with: m.range(at: 2))))
        }
        rest = re.stringByReplacingMatches(in: rest, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (rest, found)
    }
}

struct MarkdownView: View {
    let source: String
    /// Folder the file lives in, for relative image paths.
    let base: URL
    private let ws = Workspace.shared
    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
        }
        .font(.system(size: 12))
        .tint(ws.theme.tint)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            let sizes: [CGFloat] = [20, 17, 15, 13.5, 12.5, 12]
            inline(text).font(.system(size: sizes[min(level, 6) - 1], weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            inline(text).fixedSize(horizontal: false, vertical: true)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                switch marker {
                case "[ ]": Image(systemName: "square").foregroundStyle(ws.theme.dim)
                case "[x]": Image(systemName: "checkmark.square.fill").foregroundStyle(ws.theme.tint)
                default: Text(marker).foregroundStyle(ws.theme.dim)
                }
                inline(text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(ws.theme.dim.opacity(0.6)).frame(width: 3)
                inline(text).foregroundStyle(ws.theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let text):
            Text(text).font(.system(size: 11, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ws.theme.bg.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        case .table(let header, let rows, let aligns):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                    tableRow(header, aligns, bold: true)
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        Divider().opacity(0.3)
                        tableRow(row, aligns, bold: false)
                            .background(i % 2 == 1 ? ws.theme.bg.opacity(0.25) : .clear)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(ws.theme.dim.opacity(0.3)))
            }
        case .image(let alt, let src):
            MarkdownImage(alt: alt, src: src, base: base)
        case .rule:
            Divider().opacity(0.4)
        }
    }

    private func tableRow(_ cells: [String], _ aligns: [HorizontalAlignment], bold: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                inline(cell).fontWeight(bold ? .semibold : .regular)
                    .multilineTextAlignment(aligns[i] == .center ? .center : (aligns[i] == .trailing ? .trailing : .leading))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: aligns[i], vertical: .top))
            }
        }
        .background(bold ? ws.theme.bg.opacity(0.5) : .clear)
    }
}

/// A Markdown image: a local path (relative to the file), a `file:` URL, or an http(s) URL.
private struct MarkdownImage: View {
    let alt: String
    let src: String
    let base: URL
    @StateObject private var box = Local<NSImage?>(nil)
    private let ws = Workspace.shared

    private var remote: URL? {
        guard let u = URL(string: src), let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        return u
    }

    private var local: URL? {
        if remote != nil { return nil }
        if let u = URL(string: src), u.isFileURL { return u }
        let path = src.removingPercentEncoding ?? src
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: base)
    }

    var body: some View {
        Group {
            if let remote {
                AsyncImage(url: remote) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
                    else if phase.error != nil { missing }
                    else { ProgressView().controlSize(.small) }
                }
            } else if let image = box.value {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                missing
            }
        }
        .frame(maxWidth: box.value.map { min($0.size.width, 520) } ?? 520, alignment: .leading)
        .task { if let local { box.value = await Task.detached { NSImage(contentsOf: local) }.value } }
    }

    private var missing: some View {
        Label(alt.isEmpty ? src : alt, systemImage: "photo")
            .font(.system(size: 11)).foregroundStyle(ws.theme.dim)
    }
}
