import GRDB
import XCTest
@testable import BiFeed

final class FeedCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ title: String, staleDays: Int?, recent: Int = 0, read: Int = 0,
                     readIdle: Int? = 0, status: Int? = nil, error: String? = nil) -> FeedHealthRow {
        var feed = Feed(id: Int64(abs(title.hashValue % 100_000)), url: "https://\(title).example/rss",
                        title: title, siteURL: nil, folderId: nil, addedAt: now)
        feed.lastHTTPStatus = status
        feed.fetchError = error
        return FeedHealthRow(
            feed: feed, recentCount: recent, recentReadCount: read, mutedCount: 0,
            lastPublishedAt: staleDays.map { now.addingTimeInterval(-Double($0) * 86400) },
            lastReadPublishedAt: readIdle.map { now.addingTimeInterval(-Double($0) * 86400) })
    }

    func testStaleWindowFiltersByDays() {
        let fresh = row("fresh", staleDays: 1)
        let week = row("week", staleDays: 8)
        let month = row("month", staleDays: 40)
        let never = row("never", staleDays: nil)

        var filter = FeedCleanupFilter(notUpdated: .d7)
        XCTAssertFalse(filter.matches(fresh, now: now))
        XCTAssertTrue(filter.matches(week, now: now))
        XCTAssertTrue(filter.matches(month, now: now))
        XCTAssertTrue(filter.matches(never, now: now), "从未更新比任何天数都糟，任何档位都列出")

        filter.notUpdated = .d30
        XCTAssertFalse(filter.matches(week, now: now))
        XCTAssertTrue(filter.matches(month, now: now))

        filter.notUpdated = .any
        XCTAssertTrue(filter.matches(fresh, now: now), "不限档位下全部通过")
    }

    func testNotReadAndFailingFilters() {
        let readToday = row("read", staleDays: 1, recent: 12, read: 3, readIdle: 0)
        let readLongAgo = row("stale", staleDays: 1, recent: 12, read: 1, readIdle: 20)
        let neverRead = row("never", staleDays: 1, recent: 12, read: 0, readIdle: nil)

        let notRead7 = FeedCleanupFilter(notRead: .d7)
        XCTAssertFalse(notRead7.matches(readToday, now: now))
        XCTAssertTrue(notRead7.matches(readLongAgo, now: now))
        XCTAssertTrue(notRead7.matches(neverRead, now: now), "从未读过在任何档位都命中")

        let notRead30 = FeedCleanupFilter(notRead: .d30)
        XCTAssertFalse(notRead30.matches(readLongAgo, now: now), "20 天不够 30 天档")

        let onlyFailing = FeedCleanupFilter(failing: true)
        XCTAssertFalse(onlyFailing.matches(readToday, now: now))
        XCTAssertTrue(onlyFailing.matches(row("dead", staleDays: 5, status: 404), now: now))
        XCTAssertTrue(onlyFailing.matches(row("bad", staleDays: 5, error: "超时"), now: now))
    }

    func testConditionsCombineWithAnd() {
        let filter = FeedCleanupFilter(notUpdated: .d30, notRead: .d15)
        XCTAssertTrue(filter.matches(row("both", staleDays: 40, readIdle: 20), now: now))
        XCTAssertFalse(filter.matches(row("updatedRecently", staleDays: 2, readIdle: 20), now: now))
        XCTAssertFalse(filter.matches(row("readRecently", staleDays: 40, readIdle: 1), now: now))
    }

    func testSortPutsWorstFirst() {
        let sorted = FeedCleanupFilter.sorted(
            [row("b", staleDays: 3), row("never", staleDays: nil), row("a", staleDays: 3),
             row("old", staleDays: 90)], now: now)
        XCTAssertEqual(sorted.map(\.title), ["never", "old", "a", "b"],
                       "从未更新排最前，其次按停更天数，最后按名称")
    }

    func testUnsubscribeRemovesFeedAndArticles() async throws {
        let db = try makeTempDB()
        let doomed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let kept = try await db.addFeed(url: "https://b.example/rss", title: "B", siteURL: nil, folderId: nil)
        let item = ParsedItem(guid: "g1", url: nil, title: "t", author: nil,
                              publishedAt: Date(), contentHTML: "", summaryText: "")
        try await db.applyFetchSuccess(feedId: doomed.id!, etag: nil, lastModified: nil,
                                       items: [MuteEvaluation(item: item, action: nil)])
        try await db.applyFetchSuccess(feedId: kept.id!, etag: nil, lastModified: nil,
                                       items: [MuteEvaluation(item: item, action: nil)])

        try await db.deleteFeed(id: doomed.id!)

        let (feeds, articles) = try await db.pool.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM feed") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM article") ?? -1)
        }
        XCTAssertEqual(feeds, 1)
        XCTAssertEqual(articles, 1, "退订连带删掉该源的文章，别的源不受影响")
    }

    func testUnsubscribeKeepingStarredMovesThemToArchive() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        func item(_ guid: String) -> ParsedItem {
            ParsedItem(guid: guid, url: nil, title: guid, author: nil,
                       publishedAt: Date(), contentHTML: "<p>正文</p>", summaryText: "")
        }
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("keep"), action: nil),
                    MuteEvaluation(item: item("drop"), action: nil)])
        let starred = try await db.pool.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM article WHERE title = 'keep'")!
        }
        try await db.setStarred(articleId: starred, true)

        try await db.deleteFeed(id: feed.id!, keepStarred: true)

        let (titles, feedTitles) = try await db.pool.read { d in
            (try String.fetchAll(d, sql: "SELECT title FROM article"),
             try String.fetchAll(d, sql: "SELECT title FROM feed"))
        }
        XCTAssertEqual(titles, ["keep"], "星标搬走保留，未标记的随订阅删除")
        XCTAssertEqual(feedTitles, [AppDatabase.starredArchiveTitle], "原订阅已删，归档容器源已建")

        // 归档容器不该出现在侧栏订阅列表，也不该进健康表被误退订
        let sidebar = try await db.pool.read { try SidebarData.fetch($0) }
        XCTAssertTrue(sidebar.visibleFeeds.isEmpty, "归档容器不出现在订阅列表")
        let health = try await db.pool.read { try FeedHealthRow.fetchAll($0) }
        XCTAssertTrue(health.isEmpty, "容器源不进健康表")

        // 正文没跟丢：搬迁只改 feedId，articleContent 按 articleId 关联
        let body = try await db.pool.read {
            try String.fetchOne($0, sql: "SELECT html FROM articleContent WHERE articleId = ?",
                                arguments: [starred])
        }
        XCTAssertEqual(body, "<p>正文</p>")
    }

    func testUnsubscribeWithoutKeepingStarredDeletesEverything() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: ParsedItem(
                guid: "g", url: nil, title: "t", author: nil, publishedAt: Date(),
                contentHTML: "", summaryText: ""), action: nil)])
        let only = try await db.pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM article")! }
        try await db.setStarred(articleId: only, true)

        try await db.deleteFeed(id: feed.id!, keepStarred: false)

        let (articles, feeds) = try await db.pool.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM article") ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM feed") ?? -1)
        }
        XCTAssertEqual(articles, 0, "不保留星标就是全删")
        XCTAssertEqual(feeds, 0, "也不该顺手建出归档容器源")
    }

    /// 手动保存的容器源永远不会"更新"，一旦进了批量退订面板，
    /// 按「未更新 30 天」一筛就会被列出来——勾错一次用户存的网页全没。
    func testContainerFeedsAreNotOfferedForUnsubscribe() async throws {
        let db = try makeTempDB()
        _ = try await db.addFeed(url: "https://real.example/rss", title: "真实源", siteURL: nil, folderId: nil)
        _ = try await SavedPages.containerFeed(db)

        let health = try await db.pool.read { try FeedHealthRow.fetchAll($0) }
        XCTAssertEqual(health.map(\.title), ["真实源"], "容器源不进批量退订的候选列表")

        let sidebar = try await db.pool.read { try SidebarData.fetch($0) }
        XCTAssertEqual(sidebar.visibleFeeds.map(\.title).sorted(), ["手动保存", "真实源"],
                       "手动保存仍然显示在侧栏，那是用户主动放东西的地方")
    }
}
