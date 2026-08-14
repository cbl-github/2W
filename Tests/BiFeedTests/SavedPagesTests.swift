import GRDB
import XCTest
@testable import BiFeed

final class SavedPagesTests: XCTestCase {
    private let page = URL(string: "https://example.com/post?id=1#anchor")!

    func testContainerFeedIsCreatedOnceAndExemptFromPurge() async throws {
        let db = try makeTempDB()
        try await SavedPages.store(url: page, title: "标题", html: "<p>正文</p>", into: db)
        try await SavedPages.store(url: URL(string: "https://example.com/other")!,
                                   title: nil, html: "<p>另一篇</p>", into: db)

        let feeds = try await db.pool.read { try Feed.fetchAll($0) }
        XCTAssertEqual(feeds.count, 1, "容器源只惰性创建一次")
        XCTAssertEqual(feeds[0].url, SavedPages.feedURL)
        XCTAssertEqual(feeds[0].title, SavedPages.feedTitle)
        XCTAssertEqual(feeds[0].keepCount, SavedPages.keepCount)
        XCTAssertEqual(feeds[0].keepDays, 0)

        // 全局保留策略只留 1 条、1 天，按源覆盖必须挡住它
        try await db.purge(keepCount: 1, keepDays: 1)
        let titles = try await db.pool.read { d in
            try String.fetchAll(d, sql: "SELECT title FROM article ORDER BY id")
        }
        XCTAssertEqual(titles.count, 2, "手动保存的文章不被保留策略清掉")
        XCTAssertEqual(titles[1], "https://example.com/other", "没有页面标题时回落到 URL")
    }

    func testSavingSameURLTwiceDoesNotDuplicate() async throws {
        let db = try makeTempDB()
        try await SavedPages.store(url: page, title: "第一次", html: "<p>a</p>", into: db)
        // 只差 fragment 与跟踪参数：规范化后是同一个 guid
        try await SavedPages.store(url: URL(string: "https://example.com/post?id=1&utm_source=x")!,
                                   title: "第二次", html: "<p>b</p>", into: db)

        let (count, title) = try await db.pool.read { d in
            (try Article.fetchCount(d), try String.fetchOne(d, sql: "SELECT title FROM article"))
        }
        XCTAssertEqual(count, 1, "同一页重复保存不重复入库")
        XCTAssertEqual(title, "第一次", "冲突忽略，旧条目不被覆盖")
    }

    func testSavedArticleIsSearchableAndListed() async throws {
        let db = try makeTempDB()
        try await SavedPages.store(url: page, title: "Swift 并发", html: "<p>actor 隔离</p>", into: db)
        let items = try await db.pool.read { d in
            try ArticleListItem.fetchAll(d, scope: .all, search: "Swift")
        }
        XCTAssertEqual(items.map(\.title), ["Swift 并发"])
        XCTAssertEqual(items.first?.url, page.absoluteString)
    }

    func testNonHTTPFeedIsNeitherFetchedNorExported() async throws {
        let db = try makeTempDB()
        try await SavedPages.store(url: page, title: "t", html: "<p>x</p>", into: db)
        let http = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let (folders, feeds) = try await db.pool.read { d in
            (try Folder.fetchAll(d), try Feed.fetchAll(d))
        }

        let container = feeds.first { $0.url == SavedPages.feedURL }!
        XCTAssertFalse(container.isFetchable, "bifeed:// 源不参与抓取")
        XCTAssertTrue(http.isFetchable)
        XCTAssertFalse(Feed(id: nil, url: "垃圾地址", title: "x", siteURL: nil, folderId: nil,
                            addedAt: Date()).isFetchable, "无 scheme 的脏地址同样挡住")

        // refreshOne 私有：刷一次容器源，整行状态必须原样不动（入库时的时间戳也不变）
        let scheduler = FetchScheduler(db: db, fetcher: FeedFetcher(), onRefreshingChange: { _ in })
        await scheduler.refresh(feedId: container.id!)
        let refreshed = try await db.feed(id: container.id!)
        XCTAssertEqual(refreshed, container, "跳过的源不写任何抓取状态")
        XCTAssertNil(refreshed?.fetchError, "跳过 ≠ 失败，不该落错误")

        let exported = OPML.export(folders: folders, feeds: feeds)
        XCTAssertFalse(exported.contains(SavedPages.feedURL), "OPML 导出排除 bifeed:// 源")
        XCTAssertTrue(exported.contains("https://a.example/rss"))
    }
}

final class PaywallDetectorTests: XCTestCase {
    func testKnownDomainsAndSubdomains() {
        XCTAssertTrue(PaywallDetector.isLikelyPaywalled(urlString: "https://nytimes.com/2026/a"))
        XCTAssertTrue(PaywallDetector.isLikelyPaywalled(urlString: "https://www.nytimes.com/2026/a"))
        XCTAssertTrue(PaywallDetector.isLikelyPaywalled(urlString: "http://cn.wsj.com/x?y=1"))
        XCTAssertTrue(PaywallDetector.isLikelyPaywalled(urlString: "https://WWW.FT.COM/content/1"))
    }

    func testNonPaywalledAndInvalidInput() {
        XCTAssertFalse(PaywallDetector.isLikelyPaywalled(urlString: "https://example.com/a"))
        XCTAssertFalse(PaywallDetector.isLikelyPaywalled(urlString: "https://notnytimes.com/a"),
                       "后缀匹配必须带点，不能被伪装域名命中")
        XCTAssertFalse(PaywallDetector.isLikelyPaywalled(urlString: "nytimes.com/a"), "没有 host 的裸串不算")
        XCTAssertFalse(PaywallDetector.isLikelyPaywalled(urlString: nil))
        XCTAssertFalse(PaywallDetector.isLikelyPaywalled(urlString: ""))
    }
}
