import Foundation

/// 页面声明的一个候选 feed（需求 17）。title 取 `<link>` 的 title 属性，缺失时用 URL 路径兜底。
struct FeedCandidate: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: URL { url }
}

enum HTMLTools {
    /// 去标签出纯文本：先删 script/style 整块，再删标签，解常用实体，折叠空白。
    static func plainText(_ html: String) -> String {
        var s = html
        s = s.replacing(/<(script|style)[^>]*>[\s\S]*?<\/\1>/.ignoresCase(), with: " ")
        s = s.replacing(/<!--[\s\S]*?-->/, with: " ")
        // 只剥已知 HTML 标签；中文标题里的「<书名>」不是标签，必须保留。
        // 标签名枚举本身超过 120 字符且不能再拆（一个 `|` 交替表达式），按 reers 指南对
        // 不可分割长字面量的例外保留；用扩展正则字面量 #/ ... /# 折成多行只为满足行长，
        // 该定界符下折行不改变匹配语义（已用两侧样例逐一比对旧写法验证一致）。
        s = s.replacing(
            #/
            <\/?(?:a|abbr|address|article|aside|audio|b|blockquote|body|br|button|canvas|caption|center|code|dd|del
              |details|div|dl|dt|em|embed|figcaption|figure|font|footer|form|h[1-6]|head|header|hr|html|i|iframe|img
              |input|label|li|link|main|mark|meta|nav|noscript|object|ol|option|p|picture|pre|s|section|select|small
              |source|span|strike|strong|sub|summary|sup|table|tbody|td|template|textarea|tfoot|th|thead|time|title
              |tr|u|ul|video)\b[^>]*>
            /#.ignoresCase(),
            with: " ")
        s = s.replacing(/<!doctype[^>]*>|<\?xml[^>]*\?>/.ignoresCase(), with: " ")
        s = decodeEntities(s)
        s = s.replacing(/\s+/, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 摘要截断优先落在句末标点上，避免结尾悬着半句。
    /// 回退幅度超过 limit 的 40%（说明这一段句子太长）或截断范围内没有句读时，退回硬截断。
    static func excerpt(_ html: String, limit: Int = 300) -> String {
        let text = plainText(html)
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        let sentenceEnds: Set<Character> = ["。", "！", "？", ".", "!", "?", "…"]
        if let last = cut.lastIndex(where: { sentenceEnds.contains($0) }) {
            let end = cut.index(after: last)
            let kept = cut.distance(from: cut.startIndex, to: end)
            if limit - kept <= Int(Double(limit) * 0.4) {
                return String(cut[..<end])
            }
        }
        return cut
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        let table: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
        ]
        for (k, v) in table { out = out.replacingOccurrences(of: k, with: v) }
        out = out.replacing(/&#(\d+);/, with: { m in
            guard let code = UInt32(m.1), let scalar = Unicode.Scalar(code) else { return String(m.0) }
            return String(Character(scalar))
        })
        return out
    }

    /// 在 HTML 里发现 feed 链接（需求 1、17）：扫 `<link rel="alternate" type=… href=…>`。
    /// 按出现顺序返回，绝对 URL 相同的只留第一个。
    static func discoverFeeds(html: String, base: URL) -> [FeedCandidate] {
        let feedTypes = ["application/rss+xml", "application/atom+xml", "application/feed+json", "application/json"]
        var found: [FeedCandidate] = []
        var seen = Set<String>()
        for m in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
            let tag = String(m.0)
            guard tag.contains(/rel\s*=\s*["']?alternate["']?/.ignoresCase()) else { continue }
            guard let typeMatch = tag.firstMatch(of: /type\s*=\s*["']([^"']+)["']/.ignoresCase()),
                  feedTypes.contains(String(typeMatch.1).lowercased()) else { continue }
            guard let hrefMatch = tag.firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase()) else { continue }
            let href = decodeEntities(String(hrefMatch.1))
            guard let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  seen.insert(url.absoluteString).inserted else { continue }
            let title = tag.firstMatch(of: /\btitle\s*=\s*["']([^"']*)["']/.ignoresCase())
                .map { decodeEntities(String($0.1)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            found.append(FeedCandidate(url: url, title: title.isEmpty ? fallbackTitle(url) : title))
        }
        return found
    }

    private static func fallbackTitle(_ url: URL) -> String {
        url.path().isEmpty ? url.absoluteString : url.path()
    }

    /// 粗判响应是不是 HTML 页面（而非 feed 本体）。
    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(1024).lowercased()
        return head.contains("<!doctype html") || head.contains("<html")
    }

    /// 把正文里的相对 src/href 转为绝对 HTTP(S) URL。倒序替换保持 NSRange 有效。
    static func absolutizeURLs(in html: String, base: URL?) -> String {
        guard let base else { return html }
        let regex = try! NSRegularExpression(
            pattern: #"(?i)\b(?:src|href)\s*=\s*(['"])([^'"]+)\1"#)
        let source = html as NSString
        let result = NSMutableString(string: html)
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches.reversed() {
            let range = match.range(at: 2)
            let raw = decodeEntities(source.substring(with: range))
            guard !raw.hasPrefix("#"), !raw.lowercased().hasPrefix("data:"),
                  let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let escaped = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            result.replaceCharacters(in: range, with: escaped)
        }
        return result as String
    }
}
