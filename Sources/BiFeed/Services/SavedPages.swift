import Foundation
import GRDB

/// 需求 26：手动保存单篇网页。文章挂在一个惰性创建的本地容器源下，
/// 侧栏、未读、星标、搜索、导出全都自然可用，不需要单独的存储路径。
enum SavedPages {
    /// 非 http(s) scheme：Feed.isFetchable 据此把这个源挡在抓取与 OPML 导出之外。
    static let feedURL = "bifeed://saved"
    static let feedTitle = "手动保存"

    /// 保留策略的按源覆盖（v9 已有的机制）：保存的网页是用户主动留下的，purge 不该清掉它们。
    /// keepDays = 0 即不按时间清理，keepCount 给个够不着的大数。
    static let keepCount = 100_000

    /// 惰性创建容器源。整段在一次写事务里做完，重复保存不会插出第二个容器。
    static func containerFeed(_ db: AppDatabase) async throws -> Feed {
        try await db.pool.write { database in
            if let existing = try Feed.filter(Column("url") == feedURL).fetchOne(database) { return existing }
            var feed = Feed(id: nil, url: feedURL, title: feedTitle, siteURL: nil, folderId: nil,
                            addedAt: Date(), keepCount: keepCount, keepDays: 0)
            try feed.insert(database)
            return feed
        }
    }

    /// 抓页面 → 提正文 → 入库。
    @MainActor
    static func save(url: URL, into db: AppDatabase) async throws {
        let page = try await FullTextExtractor.shared.extractPage(url: url)
        try await store(url: url, title: page.title, html: page.html, into: db)
    }

    /// 入库部分，不碰网络（测试直接用这条）。guid 取规范化 URL：
    /// 同一页重复保存走 applyFetchSuccess 里既有的 (feedId, guid) 冲突忽略，不会重复入库。
    static func store(url: URL, title: String?, html: String, into db: AppDatabase) async throws {
        let feed = try await containerFeed(db)
        let item = ParsedItem(
            guid: URLNormalizer.normalized(url.absoluteString) ?? url.absoluteString,
            url: url.absoluteString,
            title: title ?? url.absoluteString,
            author: nil,
            publishedAt: Date(),
            contentHTML: html,
            summaryText: HTMLTools.excerpt(html))
        // 走正常入库路径，静音规则照常生效
        let rules = try await MuteRules.all(db)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: MuteRules.evaluate([item], feedId: feed.id!, folderId: feed.folderId, rules: rules))
    }
}
