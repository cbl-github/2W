import CryptoKit
import FeedKit
import Foundation

struct ParsedFeed {
    var title: String
    var siteURL: String?
    var items: [ParsedItem]
}

struct ParsedItem {
    var guid: String
    var url: String?
    var title: String
    var author: String?
    var publishedAt: Date?
    var contentHTML: String
    var summaryText: String
    /// RSS <comments> 元素；Atom/JSON Feed 无对应字段，恒 nil。
    var commentsURL: String?
    var categories: [String] = []
}

enum ParseFailure: LocalizedError {
    case unparseable(String)
    var errorDescription: String? {
        switch self {
        case .unparseable(let detail): return L("error.parse.unparseable", detail)
        }
    }
}

/// FeedKit 包一层：RSS/Atom/JSON 统一归一化成 ParsedFeed。
/// 输入必须是已转成 UTF-8 的字节（CharsetDecoder 的输出）。
enum FeedParsing {
    static func parse(data: Data, fallbackTitle: String) throws -> ParsedFeed {
        let parser = FeedParser(data: data)
        switch parser.parse() {
        case .failure(let error):
            throw ParseFailure.unparseable(error.localizedDescription)
        case .success(.rss(let rss)):
            return normalize(rss: rss, fallbackTitle: fallbackTitle)
        case .success(.atom(let atom)):
            return normalize(atom: atom, fallbackTitle: fallbackTitle)
        case .success(.json(let json)):
            return normalize(json: json, fallbackTitle: fallbackTitle)
        }
    }

    // MARK: - RSS

    private static func normalize(rss: RSSFeed, fallbackTitle: String) -> ParsedFeed {
        let items = (rss.items ?? []).map { item -> ParsedItem in
            let rawContent = item.content?.contentEncoded ?? item.description ?? ""
            let base = item.link.flatMap { URL(string: $0) } ?? rss.link.flatMap { URL(string: $0) }
            let content = redditRewrite(
                HTMLTools.absolutizeURLs(in: rawContent, base: base), link: item.link)
            let title = titleOrExcerpt(item.title, content: content)
            return ParsedItem(
                guid: item.guid?.value ?? item.link ?? stableHash(title, item.pubDate),
                url: item.link,
                title: title,
                author: item.author ?? item.dublinCore?.dcCreator,
                publishedAt: item.pubDate,
                contentHTML: content,
                summaryText: HTMLTools.excerpt(item.description ?? content),
                commentsURL: item.comments,
                categories: item.categories?.compactMap(\.value) ?? [])
        }
        return ParsedFeed(
            title: HTMLTools.plainText(rss.title ?? fallbackTitle),
            siteURL: rss.link,
            items: repairDuplicateGuids(items))
    }

    // MARK: - Atom

    private static func normalize(atom: AtomFeed, fallbackTitle: String) -> ParsedFeed {
        let items = (atom.entries ?? []).map { entry -> ParsedItem in
            let link = entry.links?.first {
                $0.attributes?.rel == nil || $0.attributes?.rel == "alternate"
            }?.attributes?.href ?? entry.links?.first?.attributes?.href
            let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
            let content = redditRewrite(
                HTMLTools.absolutizeURLs(in: rawContent, base: link.flatMap { URL(string: $0) }),
                link: link)
            let title = titleOrExcerpt(entry.title, content: content)
            return ParsedItem(
                guid: entry.id ?? link ?? stableHash(title, entry.published ?? entry.updated),
                url: link,
                title: title,
                author: entry.authors?.first?.name,
                publishedAt: entry.published ?? entry.updated,
                contentHTML: content,
                summaryText: HTMLTools.excerpt(entry.summary?.value ?? content),
                commentsURL: nil,
                categories: entry.categories?.compactMap { $0.attributes?.term } ?? [])
        }
        let site = atom.links?.first {
            $0.attributes?.rel == "alternate" || $0.attributes?.rel == nil
        }?.attributes?.href
        return ParsedFeed(
            title: HTMLTools.plainText(atom.title ?? fallbackTitle),
            siteURL: site,
            items: repairDuplicateGuids(items))
    }

    // MARK: - JSON Feed

    private static func normalize(json: JSONFeed, fallbackTitle: String) -> ParsedFeed {
        let items = (json.items ?? []).map { item -> ParsedItem in
            let rawContent = item.contentHtml
                ?? item.contentText.map { "<p>\(HTMLTools.escapeHTML($0))</p>" }
                ?? ""
            let content = HTMLTools.absolutizeURLs(
                in: rawContent, base: item.url.flatMap { URL(string: $0) })
            let title = titleOrExcerpt(item.title, content: content)
            return ParsedItem(
                guid: item.id ?? item.url ?? stableHash(title, item.datePublished),
                url: item.url,
                title: title,
                author: item.author?.name,
                publishedAt: item.datePublished,
                contentHTML: content,
                summaryText: HTMLTools.excerpt(item.summary ?? content),
                commentsURL: nil,
                categories: item.tags ?? [])
        }
        return ParsedFeed(
            title: HTMLTools.plainText(json.title ?? fallbackTitle),
            siteURL: json.homePageURL,
            items: repairDuplicateGuids(items))
    }

    /// Reddit 条目的表格布局正文入库前就重排（需求 27），其他站点原样透传。
    /// Reddit 的 `.rss` 实际返回 Atom，RSS 分支一并挂上是为了兼容镜像站。
    private static func redditRewrite(_ html: String, link: String?) -> String {
        guard let link, RedditContent.isRedditHost(link) else { return html }
        return RedditContent.rewrite(html: html)
    }

    /// 无标题占位（竞品报告 V6）：取正文纯文本前 60 字符；正文也空才留 "(无标题)"。
    /// 标题去标签后为空（如只含标记或空白）同样视为无标题。
    private static func titleOrExcerpt(_ rawTitle: String?, content: String) -> String {
        if let rawTitle {
            let title = HTMLTools.plainText(rawTitle)
            if !title.isEmpty { return title }
        }
        let body = HTMLTools.plainText(content)
        return body.isEmpty ? L("feed.article.untitled") : String(body.prefix(60))
    }

    /// guid/link 都缺时的稳定标识：内容指纹，跨进程、跨启动不变（Hasher 的种子是随机的，不能用）。
    private static func stableHash(_ title: String, _ date: Date?) -> String {
        let seed = "\(title)|\(date?.timeIntervalSince1970 ?? 0)"
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 同一响应里重复 GUID 的条目改用内容指纹。完全相同的重复项仍得到同一指纹并由 DB 去重。
    private static func repairDuplicateGuids(_ items: [ParsedItem]) -> [ParsedItem] {
        let counts = Dictionary(grouping: items, by: \.guid).mapValues(\.count)
        guard counts.values.contains(where: { $0 > 1 }) else { return items }
        return items.map { item in
            guard counts[item.guid, default: 0] > 1 else { return item }
            var repaired = item
            let seed = [item.url ?? "", item.title,
                        String(item.publishedAt?.timeIntervalSince1970 ?? 0), item.contentHTML]
                .joined(separator: "|")
            repaired.guid = SHA256.hash(data: Data(seed.utf8))
                .map { String(format: "%02x", $0) }.joined()
            return repaired
        }
    }
}
