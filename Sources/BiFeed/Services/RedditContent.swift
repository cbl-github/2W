import Foundation

/// Reddit 的 RSS/Atom 条目正文是老式布局：一张单行表格装缩略图和文字，
/// 末尾跟一行 `submitted by /u/x [link] [comments]` 模板。这里重排成正常正文。
///
/// 三条硬要求：
/// 1. 保守——每一步都先确认结构再动手，认不出就整段原样返回，宁可不动不可弄丢内容。
/// 2. 幂等——重排过的输出再进来是恒等变换（模板尾、表格壳、锚点包图都已不存在）。
/// 3. 纯函数——不碰网络不碰状态，可直接测。
enum RedditContent {
    static func rewrite(html: String) -> String {
        // [link] 锚点：自帖指回自身 permalink，链接帖是站外地址，图片帖是原图直链
        let linkHref = html
            .firstMatch(of: /<a\s[^>]*href="([^"]+)"[^>]*>\s*\[link\]\s*<\/a>/.ignoresCase())
            .map { HTMLTools.decodeEntities(String($0.1)) }
        var s = stripTemplateTail(html)
        s = unwrapLayoutTable(s)
        // 原图只有在正文确实有图可换时才用得上，否则留给下面的「链接：」段落
        let fullImage = linkHref.flatMap {
            isImageURL($0) && s.contains(/<img\b/.ignoresCase()) ? $0 : nil
        }
        s = liftThumbnails(s, fullImage: fullImage)
        if let linkHref, fullImage == nil, !isRedditHost(linkHref) {
            let escaped = HTMLTools.escapeHTML(linkHref)
            s += "<p>链接：<a href=\"\(escaped)\">\(escaped)</a></p>"
        }
        return s
    }

    /// 模板尾行。要求 `submitted by` 后面紧跟 `/u/` 锚点、再往后出现 `[comments]` 才删，
    /// 免得正文里恰好写了「submitted by」就被连尾巴带正文一起吃掉。
    private static func stripTemplateTail(_ html: String) -> String {
        let pattern = /(?:&#32;|\s|<br\s*\/?>)*submitted by\s*(?:&#32;\s*)*<a\s[^>]*>\s*\/u\/[\s\S]*\[comments\][\s\S]*$/
            .ignoresCase()
        guard let m = html.firstMatch(of: pattern) else { return html }
        return html.replacingCharacters(in: m.range, with: "")
    }

    /// 单行布局表（缩略图一格 + 文字一格）拆壳。正文里的真表格是多行，
    /// 而且不会顶在最前面，两个条件一起把它排除掉。
    private static func unwrapLayoutTable(_ html: String) -> String {
        guard html.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<table"),
              html.matches(of: /<tr\b[^>]*>/.ignoresCase()).count == 1 else { return html }
        return html.replacing(/<\/?(?:table|tbody|thead|tr|td|th)\b[^>]*>/.ignoresCase(), with: " ")
    }

    /// `<a href="原图"><img src="缩略图"></a>` → `<img src="原图">`。
    /// Reddit 里这个 href 常常是 permalink 而不是图，这时用 [link] 给出的原图顶上；
    /// 两者都不是图片就保留原锚点。
    private static func liftThumbnails(_ html: String, fullImage: String?) -> String {
        html.replacing(/<a\s[^>]*href="([^"]+)"[^>]*>\s*(<img\b[^>]*>)\s*<\/a>/.ignoresCase()) { m in
            let href = HTMLTools.decodeEntities(String(m.1))
            if isImageURL(href) { return "<img src=\"\(HTMLTools.escapeHTML(href))\">" }
            if let fullImage { return "<img src=\"\(HTMLTools.escapeHTML(fullImage))\">" }
            return String(m.0)
        }
    }

    private static func isImageURL(_ url: String) -> Bool {
        guard let ext = URL(string: url)?.pathExtension.lowercased() else { return false }
        return ["jpg", "jpeg", "png", "gif", "webp", "avif"].contains(ext)
    }

    /// 后缀比较带上点号：`notreddit.com` 不是 Reddit。
    static func isRedditHost(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host()?.lowercased() else { return false }
        return host == "reddit.com" || host.hasSuffix(".reddit.com")
    }
}
