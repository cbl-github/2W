import XCTest
@testable import BiFeed

final class DatabaseTests: XCTestCase {
    func testUpsertDedupsByGuidAndStoresContent() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://x.example/rss", title: "X", siteURL: nil, folderId: nil)
        let item = ParsedItem(
            guid: "g1", url: "https://x.example/1", title: "Hello", author: nil,
            publishedAt: Date(), contentHTML: "<p>body</p>", summaryText: "body")

        let first = try await db.applyFetchSuccess(feedId: feed.id!, etag: "e1", lastModified: nil, items: [MuteEvaluation(item: item, action: nil)])
        let second = try await db.applyFetchSuccess(feedId: feed.id!, etag: "e1", lastModified: nil, items: [MuteEvaluation(item: item, action: nil)])
        XCTAssertEqual(first.inserted, 1)
        XCTAssertEqual(second.inserted, 0, "同 guid 不重复入库")

        let (count, html, storedFeed) = try await db.pool.read { d in
            (try Article.fetchCount(d),
             try String.fetchOne(d, sql: "SELECT html FROM articleContent"),
             try Feed.fetchOne(d, key: feed.id!))
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(html, "<p>body</p>")
        XCTAssertEqual(storedFeed?.etag, "e1")
        XCTAssertNotNil(storedFeed?.lastSuccessAt, "订阅路径也要落成功时间，否则首批策略会重复套用")
    }

    func testListQueryScopesAndOrder() async throws {
        let db = try makeTempDB()
        let folder = try await db.addFolder(name: "F")
        let f1 = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: folder.id)
        let f2 = try await db.addFeed(url: "https://b.example/rss", title: "B", siteURL: nil, folderId: nil)
        func item(_ g: String, _ daysAgo: Double) -> ParsedItem {
            ParsedItem(guid: g, url: nil, title: g, author: nil,
                       publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86400),
                       contentHTML: "", summaryText: "")
        }
        try await db.applyFetchSuccess(feedId: f1.id!, etag: nil, lastModified: nil, items: [MuteEvaluation(item: item("old", 3), action: nil), MuteEvaluation(item: item("new", 1), action: nil)])
        try await db.applyFetchSuccess(feedId: f2.id!, etag: nil, lastModified: nil, items: [MuteEvaluation(item: item("other", 2), action: nil)])

        let all = try await db.pool.read { d in try ArticleListItem.fetchAll(d, scope: .all, search: nil) }
        XCTAssertEqual(all.map(\.title), ["new", "other", "old"], "按时间倒序")

        let folderScoped = try await db.pool.read { d in try ArticleListItem.fetchAll(d, scope: .folder(folder.id!), search: nil) }
        XCTAssertEqual(folderScoped.map(\.title), ["new", "old"])

        let searched = try await db.pool.read { d in try ArticleListItem.fetchAll(d, scope: .all, search: "oth") }
        XCTAssertEqual(searched.map(\.title), ["other"], "搜索叠加在范围之上")
    }

    func testPurgeKeepsStarredAndRecent() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://x.example/rss", title: "X", siteURL: nil, folderId: nil)
        var items: [ParsedItem] = []
        for i in 0..<10 {
            items.append(ParsedItem(
                guid: "g\(i)", url: nil, title: "t\(i)", author: nil,
                publishedAt: Date(timeIntervalSinceNow: -Double(i) * 3600),
                contentHTML: "<p>\(i)</p>", summaryText: ""))
        }
        try await db.applyFetchSuccess(feedId: feed.id!, etag: nil, lastModified: nil, items: items.map { MuteEvaluation(item: $0, action: nil) })

        let starredId = try await db.pool.read { d in
            try Int64.fetchOne(d, sql: "SELECT id FROM article WHERE title = 't9'")!
        }
        try await db.setStarred(articleId: starredId, true)

        try await db.purge(keepCount: 3, keepDays: 0)
        let titles = try await db.pool.read { d in
            try String.fetchAll(d, sql: "SELECT title FROM article ORDER BY publishedAt DESC")
        }
        XCTAssertEqual(titles, ["t0", "t1", "t2", "t9"], "留最近 3 条 + 星标那条；级联删掉的正文也应消失")

        let contentCount = try await db.pool.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM articleContent") ?? -1
        }
        XCTAssertEqual(contentCount, 4)
    }

    func testFeedParsingRSS() throws {
        let rss = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0"><channel><title>Blog</title><link>https://blog.example</link>
        <item><title>Post &amp; One</title><link>https://blog.example/1</link>
        <guid>tag:1</guid><pubDate>Wed, 13 Aug 2025 08:00:00 GMT</pubDate>
        <category>Tech</category>
        <description>&lt;p&gt;Summary here&lt;/p&gt;</description></item>
        </channel></rss>
        """
        let parsed = try FeedParsing.parse(data: Data(rss.utf8), fallbackTitle: "fb")
        XCTAssertEqual(parsed.title, "Blog")
        XCTAssertEqual(parsed.items.count, 1)
        XCTAssertEqual(parsed.items[0].guid, "tag:1")
        XCTAssertEqual(parsed.items[0].title, "Post & One")
        XCTAssertEqual(parsed.items[0].summaryText, "Summary here")
        XCTAssertEqual(parsed.items[0].categories, ["Tech"])
        XCTAssertNotNil(parsed.items[0].publishedAt)
    }

    func testDuplicateGuidsUseStableContentFingerprints() throws {
        let rss = """
        <rss version="2.0"><channel><title>X</title><link>https://x.example</link>
        <item><guid>same</guid><title>One</title><link>https://x.example/1</link>
        <description>&lt;img src="/one.png"&gt;</description></item>
        <item><guid>same</guid><title>Two</title><link>https://x.example/2</link>
        <description>Two</description></item>
        </channel></rss>
        """
        let parsed = try FeedParsing.parse(data: Data(rss.utf8), fallbackTitle: "X")
        XCTAssertEqual(Set(parsed.items.map(\.guid)).count, 2)
        XCTAssertTrue(parsed.items[0].contentHTML.contains("https://x.example/one.png"))
    }

    func testThrottlingFailureDoesNotIncreaseFailCount() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(
            url: "https://x.example/rss", title: "X", siteURL: nil, folderId: nil)
        let retry = Date(timeIntervalSinceNow: 600)
        try await db.applyFetchFailure(
            feedId: feed.id!, message: "HTTP 429", status: 429,
            nextFetchAt: retry, incrementFailure: false)

        let stored = try await db.feed(id: feed.id!)
        XCTAssertEqual(stored?.failCount, 0)
        XCTAssertEqual(stored?.lastHTTPStatus, 429)
        XCTAssertEqual(try XCTUnwrap(stored?.nextFetchAt).timeIntervalSince1970,
                       retry.timeIntervalSince1970, accuracy: 0.001)
    }

    func testExactCrossFeedURLsCollapseOnlyInAggregateViews() async throws {
        let db = try makeTempDB()
        let firstFeed = try await db.addFeed(
            url: "https://one.example/rss", title: "One", siteURL: nil, folderId: nil)
        let secondFeed = try await db.addFeed(
            url: "https://two.example/rss", title: "Two", siteURL: nil, folderId: nil)
        let first = ParsedItem(
            guid: "one", url: "https://NEWS.example/story/?utm_source=rss", title: "First copy",
            author: nil, publishedAt: Date(), contentHTML: "", summaryText: "")
        let second = ParsedItem(
            guid: "two", url: "https://news.example/story", title: "Second copy",
            author: nil, publishedAt: Date(), contentHTML: "", summaryText: "")
        try await db.applyFetchSuccess(
            feedId: firstFeed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: first, action: nil)])
        try await db.applyFetchSuccess(
            feedId: secondFeed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: second, action: nil)])

        let all = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: nil)
        }
        XCTAssertEqual(all.map(\.title), ["First copy"])
        XCTAssertEqual(all.first?.duplicateCount, 1)

        let secondScope = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .feed(secondFeed.id!), search: nil)
        }
        XCTAssertEqual(secondScope.map(\.title), ["Second copy"])

        try await db.setRead(articleId: all[0].id, true)
        let unread = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: nil, filter: "unread")
        }
        XCTAssertEqual(unread.map(\.title), ["Second copy"],
                       "当前筛选里仍要选出一个 canonical")
    }
}
