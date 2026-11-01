import Foundation
import SwiftUI

/// Claude 回复里的 Markdown，按块拆开（和手机网页的 md() 同一套规则）
indirect enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, items: [MarkdownListItem])
    case table(header: [String], rows: [[String]])
    case rule
}

struct MarkdownListItem: Hashable {
    var marker: String
    var text: String
    var indent: Int
}

enum Markdown {
    private static let cache = NSCache<NSString, Box>()
    private final class Box { let blocks: [MarkdownBlock]; init(_ b: [MarkdownBlock]) { blocks = b } }

    static func blocks(_ source: String) -> [MarkdownBlock] {
        if let hit = cache.object(forKey: source as NSString) { return hit.blocks }
        let blocks = parse(source)
        cache.setObject(Box(blocks), forKey: source as NSString)
        return blocks
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#)
    private static let tableSeparator = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#)
    private static let rulePattern = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)
    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*)$"#)
    private static let fencePattern = try! NSRegularExpression(pattern: #"^\s*(```|~~~)\s*([\w+#.-]*)\s*$"#)

    private static func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: line).map { String(line[$0]) } ?? ""
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool { groups(regex, line) != nil }

    private static func isQuote(_ line: String) -> Bool { line.drop { $0 == " " || $0 == "\t" }.hasPrefix(">") }

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        lines[i].contains("|") && i + 1 < lines.count && matches(tableSeparator, lines[i + 1])
    }

    private static func startsBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || matches(headingPattern, line) || matches(listPattern, line) || isQuote(line)
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let fence = groups(fencePattern, line) {
                var buffer: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence[1]) {
                    buffer.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(buffer.joined(separator: "\n")))
                continue
            }
            if isTableStart(lines, i) {
                func cells(_ l: String) -> [String] {
                    var t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("|") { t.removeFirst() }
                    if t.hasSuffix("|") { t.removeLast() }
                    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                let header = cells(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            }
            if let h = groups(headingPattern, line) {
                out.append(.heading(level: min(h[1].count, 4), text: h[2]))
                i += 1
                continue
            }
            if matches(rulePattern, line) {
                out.append(.rule)
                i += 1
                continue
            }
            if isQuote(line) {
                var buffer: [String] = []
                while i < lines.count, isQuote(lines[i]) {
                    var text = String(lines[i].drop { $0 == " " || $0 == "\t" }.dropFirst())
                    if text.hasPrefix(" ") { text.removeFirst() }
                    buffer.append(text)
                    i += 1
                }
                out.append(.quote(parse(buffer.joined(separator: "\n"))))
                continue
            }
            if let first = groups(listPattern, line) {
                let ordered = first[2].first?.isNumber == true
                var items: [MarkdownListItem] = []
                var number = 0
                while i < lines.count {
                    if let m = groups(listPattern, lines[i]) {
                        var text = m[3]
                        var marker = ordered ? "\(Int(m[2].dropLast()) ?? (number + 1))." : "•"
                        if text.hasPrefix("[ ] ") { marker = "☐"; text.removeFirst(4) }
                        else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { marker = "☑"; text.removeFirst(4) }
                        number += 1
                        let indent = m[1].replacingOccurrences(of: "\t", with: "  ").count / 2
                        items.append(MarkdownListItem(marker: marker, text: text, indent: indent))
                        i += 1
                    } else if lines[i].hasPrefix("  "), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty, !items.isEmpty {
                        // 列表项的续行
                        items[items.count - 1].text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                out.append(.list(ordered: ordered, items: items))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }
            var buffer: [String] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty,
                  !(!buffer.isEmpty && startsBlock(lines[i])), !isTableStart(lines, i) {
                buffer.append(lines[i])
                i += 1
            }
            out.append(.paragraph(buffer.joined(separator: "\n")))
        }
        return out
    }

    // MARK: 行内

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// 粗体、斜体、删除线、`代码`、链接；裸网址也变成可点的链接
    static func inline(_ text: String, code: Color = Color.primary.opacity(0.08)) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = ChatType.code   // 照 VS Code：0.9em 的编辑器字体（Menlo）
            result[run.range].backgroundColor = code
        }
        // Markdown 自带的自动链接（GitHub 风格）一直延到下一个空格：「…/a.dmg。Apple」「www.b.com。好」整段成了链接，点开是坏地址。
        // 裸网址（链接文字就是网址）到第一个非 ASCII 字符为止；[文字](网址) 这种写明的链接不动
        var autolinks: [(range: Range<AttributedString.Index>, end: AttributedString.Index, head: String)] = []
        for run in result.runs where run.link != nil {
            let text = String(result[run.range].characters)
            guard text.hasPrefix("http://") || text.hasPrefix("https://") || text.hasPrefix("www."),
                  let cut = text.firstIndex(where: { !$0.isASCII }) else { continue }
            let head = String(text[..<cut])
            autolinks.append((run.range, result.index(run.range.lowerBound, offsetByCharacters: head.count), head))
        }
        for link in autolinks {
            result[link.end..<link.range.upperBound].link = nil
            result[link.range.lowerBound..<link.end].link = URL(string: link.head.contains("://") ? link.head : "http://" + link.head)
        }
        let plain = String(result.characters)
        if let detector = linkDetector {
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let found = match.url, var range = Range(match.range, in: plain) else { continue }
                // 网址后面紧跟中文（「…/a.dmg。Apple 芯片」「localhost:3000，然后」）：系统会把全角标点和后面的字一起算进网址，
                // 点开是坏地址。网址到第一个非 ASCII 字符为止
                var url = found
                if let cut = plain[range].firstIndex(where: { !$0.isASCII }) {
                    range = range.lowerBound..<cut
                    let text = String(plain[range])
                    guard !range.isEmpty, let trimmed = URL(string: text.contains("://") ? text : "http://" + text) else { continue }
                    url = trimmed
                }
                guard let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result),
                      result[lower..<upper].link == nil else { continue }
                result[lower..<upper].link = url
            }
        }
        // 电脑上的文件路径（`~/Desktop/报价单.xlsx`、正文里的 /Users/…/a.pdf）：变成文件链接，对话页轻点取回手机预览、转发（见 FileLink）
        FileLink.linkify(&result)
        // claude.ai 的链接（Artifact 预览、用量页……）只显示文字、不让点：在手机或别的网络里打开，IP 和平时用 Claude 的不一样，账号容易被风控
        let blocked = result.runs.compactMap { run in run.link.flatMap { blockedLink($0) ? run.range : nil } }
        for range in blocked { result[range].link = nil }
        return result
    }

    /// claude.ai 及其子域名的网址（手表上同样的判断见 WText.markdown）
    static func blockedLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "claude.ai" || host.hasSuffix(".claude.ai")
    }
}
