import Foundation

/// 当前文章 → 带 YAML frontmatter 的 Markdown（COMPETITIVE.md 第二批 F17）。
/// HTML→Markdown 是简版转换：只认 h1-h6/p/li/blockquote/pre/img/a，其余标签剥掉当纯文本。
///
/// 译文对位：段落序号与 ReaderTemplate.js 的 extract() 同规则——
/// 块级元素只取最内层（SEL 命中的后代优先）、跳过 pre、纯文本不足 2 字符不占号。
/// 两边处理同一份 extractedHTML ?? html，顺序扫描即得相同序号；
/// 对不上的序号（比如楼层段落的缓存译文）只是找不到宿主段落，不报错。
enum MarkdownExporter {
    static func markdown(data: ReaderData, translations: [(Int, String)], thread: ForumThread?) -> String {
        var counter = BlockCounter(translations: Dictionary(uniqueKeysWithValues: translations))
        var out = [frontmatter(data)]
        out += blocks(html: data.extractedHTML ?? data.html, counter: &counter)
        if let thread { out += forumBlocks(thread) }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// NSSavePanel 的默认文件名：去掉路径分隔符等会出问题的字符；前导点会变隐藏文件，一并去掉。
    static func filename(for title: String) -> String {
        var name = title.replacing(/[\/:\\\n\r\t]/, with: " ")
        name = name.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
        name = String(name.drop(while: { $0 == "." }).prefix(80))
        return (name.isEmpty ? L("export.untitled") : name) + ".md"
    }

    // MARK: - frontmatter

    private static func frontmatter(_ data: ReaderData) -> String {
        var lines = ["---", "title: \(yaml(data.article.title))", "source: \(yaml(data.feedTitle))"]
        if let url = data.article.url { lines.append("url: \(yaml(url))") }
        if let date = data.article.publishedAt { lines.append("date: \(dateFormatter.string(from: date))") }
        lines.append("tags: [bifeed]")
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    private static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ") + "\""
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - 块级转换

    /// 译文序号发放器：每遇到一个 extract() 会收的块就 +1，有无译文都要推进。
    private struct BlockCounter {
        let translations: [Int: String]
        private var next = 0

        // private 存储属性会把隐式 memberwise init 也拉成 private，显式补一个
        init(translations: [Int: String]) {
            self.translations = translations
        }

        mutating func claim() -> String? {
            defer { next += 1 }
            return translations[next]
        }
    }

    /// extract() 的 SEL 标签，外加要整块特殊处理的 ul/ol/pre。
    /// 计算属性而非 static let：Regex 非 Sendable，不进全局存储。
    private static var blockOpen: Regex<(Substring, Substring)> {
        /<(h[1-6]|p|li|blockquote|ul|ol|pre)\b[^>]*>/.ignoresCase()
    }

    /// 只有 SEL 标签（决定"最内层"判定；ul/ol/pre 不算，extract() 的 querySelector 不含它们）
    private static func containsSel(_ s: Substring) -> Bool {
        s.contains(/<(h[1-6]|p|li|blockquote)\b/.ignoresCase())
    }

    private static func blocks(html: String, counter: inout BlockCounter) -> [String] {
        var s = html
        s = s.replacing(/<(script|style)[^>]*>[\s\S]*?<\/\1>/.ignoresCase(), with: " ")
        s = s.replacing(/<!--[\s\S]*?-->/, with: " ")
        var out: [String] = []
        parse(s[...], counter: &counter, into: &out)
        return out
    }

    /// 顺序扫块级标签；标签之间的散文本当普通段落（extract() 不收散文本，不占译文序号）。
    private static func parse(_ html: Substring, counter: inout BlockCounter, into out: inout [String]) {
        var rest = html
        while let m = rest.firstMatch(of: blockOpen) {
            appendLoose(rest[rest.startIndex ..< m.range.lowerBound], to: &out)
            let tag = String(m.1).lowercased()
            let (inner, tail) = innerAndTail(tag: tag, from: m.range.upperBound, in: rest)
            render(tag: tag, inner: inner, counter: &counter, into: &out)
            rest = tail
        }
        appendLoose(rest, to: &out)
    }

    /// 找 tag 的配对闭合，返回（内层内容, 余下部分）。
    /// p 不能合法包含块级元素：内容里出现任何块级开标签就视为自动闭合（HTML5 规则，
    /// 浏览器同样处理，未闭合的 <p> 才不会吞并后文打乱译文序号）。
    /// 其余标签按同名开闭计数配对（blockquote/ul/ol/li 会同名嵌套）；没有闭合就取到末尾。
    private static func innerAndTail(tag: String, from start: Substring.Index, in s: Substring)
        -> (inner: Substring, tail: Substring) {
        let close = s.range(of: "</\(tag)>", options: .caseInsensitive, range: start ..< s.endIndex)
        if tag == "p" {
            let open = s[start...].firstMatch(of: blockOpen)?.range
            switch (close, open) {
            case let (c?, o?) where o.lowerBound < c.lowerBound:
                return (s[start ..< o.lowerBound], s[o.lowerBound...])
            case let (nil, o?):
                return (s[start ..< o.lowerBound], s[o.lowerBound...])
            case let (c?, _):
                return (s[start ..< c.lowerBound], s[c.upperBound...])
            case (nil, nil):
                return (s[start...], s[s.endIndex...])
            }
        }
        // \b 防止找 <p 时吃进 <pre
        let open = try! Regex("<\(tag)\\b").ignoresCase()
        var depth = 1
        var cursor = start
        var closeRange = close
        while let c = closeRange {
            depth += s[cursor ..< c.lowerBound].matches(of: open).count - 1
            if depth == 0 { return (s[start ..< c.lowerBound], s[c.upperBound...]) }
            cursor = c.upperBound
            closeRange = s.range(of: "</\(tag)>", options: .caseInsensitive, range: cursor ..< s.endIndex)
        }
        return (s[start...], s[s.endIndex...])
    }

    private static func render(tag: String, inner: Substring, counter: inout BlockCounter, into out: inout [String]) {
        switch tag {
        case "pre":
            // 围栏代码：剥标签解实体、保留换行；extract() 跳过 pre，不占译文序号
            let code = HTMLTools.decodeEntities(String(inner).replacing(/<[^>]+>/, with: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append("```\n\(code)\n```")
        case "ul", "ol":
            // 只认 li，编号列表也用 "- "（简版）；li 由递归处理
            parse(inner, counter: &counter, into: &out)
        case "blockquote" where containsSel(inner):
            // 有更内层的块：容器本身不占译文序号（extract() 只取最内层），整体加引用前缀
            var nested: [String] = []
            parse(inner, counter: &counter, into: &nested)
            if !nested.isEmpty { out.append(quote(nested.joined(separator: "\n\n"), level: 1)) }
        case "li" where containsSel(inner):
            var nested: [String] = []
            parse(inner, counter: &counter, into: &nested)
            guard !nested.isEmpty else { return }
            nested[0] = "- " + nested[0]
            out += nested
        default:
            leaf(tag: tag, inner: inner, counter: &counter, into: &out)
        }
    }

    /// 叶子块：产出 markdown；可翻译的（纯文本 >= 2 字符，与 extract() 同阈值）占一个译文序号，
    /// 命中缓存译文就在原文块下加「> 译：」引用行。
    private static func leaf(tag: String, inner: Substring, counter: inout BlockCounter, into out: inout [String]) {
        let translation = HTMLTools.plainText(String(inner)).count >= 2 ? counter.claim() : nil
        let text = inlineText(inner)
        if !text.isEmpty {
            switch tag {
            case "blockquote":
                out.append("> " + text.replacingOccurrences(of: "\n", with: "\n> "))
            case "li":
                out.append("- " + text.replacingOccurrences(of: "\n", with: "\n  "))
            case let h where h.hasPrefix("h"):
                out.append(String(repeating: "#", count: Int(h.dropFirst())!) + " "
                    + text.replacingOccurrences(of: "\n", with: " "))
            default:
                out.append(text)
            }
        }
        if let translation {
            out.append("> " + L("export.translationPrefix") + translation.replacingOccurrences(of: "\n", with: " "))
        }
    }

    /// 块标签之间的散文本。有些源整篇用 div 当段落：div/表格类边界先转双换行再按空行分段。
    private static func appendLoose(_ s: Substring, to out: inout [String]) {
        guard !s.isEmpty else { return }
        let prepared = String(s).replacing(
            /<\/?(?:div|section|article|figure|figcaption|header|footer|table|tr)\b[^>]*>/.ignoresCase(),
            with: "<br><br>")
        let text = inlineText(prepared[...])
        for para in text.split(separator: /\n\n+/) {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty { out.append(p) }
        }
    }

    // MARK: - 行内转换

    /// img/a 转 markdown，br 转换行，其余标签剥掉。实体在剥完标签后统一解
    ///（先解会把 &lt;p&gt; 变成真标签）；\u{1} 给 br 占位，免得空白折叠吃掉换行。
    private static func inlineText(_ html: Substring) -> String {
        var s = String(html)
        // img 先于 a：<a><img></a> 转完是合法的图片链接 [![alt](src)](href)
        s = s.replacing(/<img\b[^>]*>/.ignoresCase(), with: { m in
            let tag = String(m.output)
            guard let src = attribute("src", in: tag) else { return "" }
            return "![\(attribute("alt", in: tag) ?? "")](\(src))"
        })
        s = s.replacing(/<a\b([^>]*)>([\s\S]*?)<\/a>/.ignoresCase(), with: { m in
            let label = String(m.2).replacing(/<[^>]+>/, with: " ")
                .replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
            guard let href = attribute("href", in: String(m.1)), !label.isEmpty else { return label }
            return "[\(label)](\(href))"
        })
        s = s.replacing(/<br\s*\/?>/.ignoresCase(), with: "\u{1}")
        s = s.replacing(/<[^>]+>/, with: " ")
        s = HTMLTools.decodeEntities(s)
        s = s.replacing(/[ \t\r\n]+/, with: " ")
        s = s.replacingOccurrences(of: "\u{1}", with: "\n")
        s = s.replacing(/[ ]*\n[ ]*/, with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从标签源码里取 name="value" / name='value' 的属性值（解实体）。
    private static func attribute(_ name: String, in tag: String) -> String? {
        let re = try! Regex("\(name)\\s*=\\s*[\"']([^\"']*)[\"']").ignoresCase()
        guard let m = (try? re.firstMatch(in: tag)) ?? nil,
              let v = m.output[1].substring else { return nil }
        return HTMLTools.decodeEntities(String(v))
    }

    // MARK: - 楼层

    /// 楼层附在文末：每层一个引用块（首行 作者/楼号/时间），HN 树形按 depth 加深引用层级。
    /// 楼层不对位译文——extract() 给楼层的序号取决于页面实时 DOM，导出侧无法复现。
    private static func forumBlocks(_ thread: ForumThread) -> [String] {
        let isHN = thread.source == "hn"
        var out = ["## " + L("export.forum.heading", isHN ? L("forum.comments") : L("forum.replies"), thread.postCount)]
        var mute = BlockCounter(translations: [:])
        for post in thread.posts {
            let badge = post.isOP ? (isHN ? " · OP" : " · " + L("forum.opBadge")) : ""
            let meta = isHN ? post.timeText : "#\(post.index) · \(post.timeText)"
            var body: [String] = []
            parse(post.html[...], counter: &mute, into: &body)
            let content = (["**\(post.author)**\(badge) · \(meta)"] + body).joined(separator: "\n\n")
            out.append(quote(content, level: post.depth + 1))
        }
        return out
    }

    /// 每行加 level 层引用前缀；空行也带前缀，块内引用才不断开。
    private static func quote(_ text: String, level: Int) -> String {
        let prefix = String(repeating: "> ", count: level)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { prefix + String($0) }
            .joined(separator: "\n")
    }
}
