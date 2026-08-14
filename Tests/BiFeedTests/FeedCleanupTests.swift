import GRDB
import XCTest
@testable import BiFeed

final class FeedCleanupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ title: String, staleDays: Int?, recent: Int = 0, read: Int = 0,
                     status: Int? = nil, error: String? = nil) -> FeedHealthRow {
        var feed = Feed(id: Int64(abs(title.hashValue % 100_000)), url: "https://\(title).example/rss",
                        title: title, siteURL: nil, folderId: nil, addedAt: now)
        feed.lastHTTPStatus = status
        feed.fetchError = error
        return FeedHealthRow(
            feed: feed, recentCount: recent, recentReadCount: read, mutedCount: 0,
            lastPublishedAt: staleDays.map { now.addingTimeInterval(-Double($0) * 86400) })
    }

    func testStaleWindowFiltersByDays() {
        let fresh = row("fresh", staleDays: 1)
        let week = row("week", staleDays: 8)
        let month = row("month", staleDays: 40)
        let never = row("never", staleDays: nil)

        var filter = FeedCleanupFilter(stale: .d7)
        XCTAssertFalse(filter.matches(fresh, now: now))
        XCTAssertTrue(filter.matches(week, now: now))
        XCTAssertTrue(filter.matches(month, now: now))
        XCTAssertTrue(filter.matches(never, now: now), "从未更新比任何天数都糟，任何档位都列出")

        filter.stale = .d30
        XCTAssertFalse(filter.matches(week, now: now))
        XCTAssertTrue(filter.matches(month, now: now))

        filter.stale = .any
        XCTAssertTrue(filter.matches(fresh, now: now), "不限档位下全部通过")
    }

    func testIgnoredAndFailingFilters() {
        let ignored = row("ignored", staleDays: 1, recent: 12, read: 0)
        let readSome = row("read", staleDays: 1, recent: 12, read: 3)
        let silent = row("silent", staleDays: 60, recent: 0, read: 0)

        let onlyIgnored = FeedCleanupFilter(onlyIgnored: true)
        XCTAssertTrue(onlyIgnored.matches(ignored, now: now))
        XCTAssertFalse(onlyIgnored.matches(readSome, now: now))
        XCTAssertFalse(onlyIgnored.matches(silent, now: now), "没有新文章谈不上「没读」")

        let onlyFailing = FeedCleanupFilter(onlyFailing: true)
        XCTAssertFalse(onlyFailing.matches(ignored, now: now))
        XCTAssertTrue(onlyFailing.matches(row("dead", staleDays: 5, status: 404), now: now))
        XCTAssertTrue(onlyFailing.matches(row("bad", staleDays: 5, error: "超时"), now: now))
    }

    func testConditionsCombineWithAnd() {
        let filter = FeedCleanupFilter(stale: .d30, onlyIgnored: true)
        XCTAssertTrue(filter.matches(row("both", staleDays: 40, recent: 5, read: 0), now: now))
        XCTAssertFalse(filter.matches(row("staleOnly", staleDays: 40, recent: 5, read: 2), now: now))
        XCTAssertFalse(filter.matches(row("ignoredOnly", staleDays: 2, recent: 5, read: 0), now: now))
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
}
