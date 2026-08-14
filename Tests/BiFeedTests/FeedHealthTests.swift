import GRDB
import XCTest
@testable import BiFeed

/// M12：源健康统计、死源改址替换、静默停更判定。
final class FeedHealthTests: XCTestCase {
    private func item(_ guid: String, daysAgo: Double) -> ParsedItem {
        ParsedItem(guid: guid, url: nil, title: guid, author: nil,
                   publishedAt: Date(timeIntervalSinceNow: -daysAgo * 86400),
                   contentHTML: "", summaryText: "")
    }

    private func articleId(_ db: AppDatabase, guid: String) async throws -> Int64 {
        try await db.pool.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM article WHERE guid = ?", arguments: [guid])!
        }
    }

    func testHealthStatsCountRecentReadAndMuted() async throws {
        let db = try makeTempDB()
        let busy = try await db.addFeed(url: "https://busy.example/rss", title: "忙",
                                        siteURL: nil, folderId: nil)
        let empty = try await db.addFeed(url: "https://empty.example/rss", title: "空",
                                         siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: busy.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("fresh", daysAgo: 1), action: nil),
                    MuteEvaluation(item: item("recent", daysAgo: 5), action: nil),
                    MuteEvaluation(item: item("aged", daysAgo: 40), action: nil),
                    MuteEvaluation(item: item("noisy", daysAgo: 2), action: .hide)])
        try await db.setRead(articleId: try await articleId(db, guid: "fresh"), true)
        try await db.setRead(articleId: try await articleId(db, guid: "aged"), true)

        let rows = try await db.pool.read { try FeedHealthRow.fetchAll($0) }
        XCTAssertEqual(rows.count, 2, "没有文章的源也要出现在表里")
        let busyRow = try XCTUnwrap(rows.first { $0.id == busy.id })
        XCTAssertEqual(busyRow.recentCount, 2, "40 天前的不算，静音的不算")
        XCTAssertEqual(busyRow.recentReadCount, 1, "窗口外读过的不算进近 30 天已读")
        XCTAssertEqual(busyRow.mutedCount, 1)
        XCTAssertEqual(try XCTUnwrap(busyRow.lastPublishedAt).timeIntervalSinceNow,
                       -86400, accuracy: 600)
        XCTAssertEqual(busyRow.status, "正常")

        let emptyRow = try XCTUnwrap(rows.first { $0.id == empty.id })
        XCTAssertEqual([emptyRow.recentCount, emptyRow.recentReadCount, emptyRow.mutedCount],
                       [0, 0, 0])
        XCTAssertNil(emptyRow.lastPublishedAt)
    }

    func testHealthStatusFollowsSidebarJudgement() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://dead.example/rss", title: "死",
                                        siteURL: nil, folderId: nil)
        try await db.applyFetchFailure(feedId: feed.id!, message: "HTTP 410", status: 410,
                                       nextFetchAt: nil, incrementFailure: true)
        var row = try await db.pool.read { try FeedHealthRow.fetchAll($0)[0] }
        XCTAssertEqual(row.status, "硬错误 HTTP 410")

        try await db.applyFetchFailure(feedId: feed.id!, message: "超时", status: nil,
                                       nextFetchAt: Date(timeIntervalSinceNow: 3600),
                                       incrementFailure: true)
        row = try await db.pool.read { try FeedHealthRow.fetchAll($0)[0] }
        XCTAssertEqual(row.status, "暂缓中", "退避期内优先报暂缓，与侧栏图标同序")
    }

    func testRelocateClearsFetchStateAndKeepsArticles() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://old.example/rss", title: "搬家了",
                                        siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(feedId: feed.id!, etag: "W/\"1\"", lastModified: "Mon, 01 Jan 2026",
                                       items: [MuteEvaluation(item: item("a", daysAgo: 1), action: nil)])
        try await db.pool.write {
            try $0.execute(sql: "UPDATE feed SET bodyHash = 'deadbeef' WHERE id = ?", arguments: [feed.id!])
        }
        try await db.applyFetchFailure(feedId: feed.id!, message: "HTTP 404", status: 404,
                                       nextFetchAt: Date(timeIntervalSinceNow: 3600),
                                       incrementFailure: true)

        try await db.relocateFeed(id: feed.id!, to: "https://new.example/feed.xml")

        let reloaded = try await db.feed(id: feed.id!)
        let moved = try XCTUnwrap(reloaded)
        XCTAssertEqual(moved.url, "https://new.example/feed.xml")
        XCTAssertNil(moved.etag)
        XCTAssertNil(moved.lastModified)
        XCTAssertNil(moved.bodyHash)
        XCTAssertNil(moved.fetchError)
        XCTAssertNil(moved.lastHTTPStatus)
        XCTAssertNil(moved.nextFetchAt)
        XCTAssertEqual(moved.failCount, 0)
        XCTAssertEqual(moved.title, "搬家了", "改址不动名称与分组")

        let kept = try await db.pool.read {
            try String.fetchAll($0, sql: "SELECT title FROM article WHERE feedId = ?",
                                arguments: [feed.id!])
        }
        XCTAssertEqual(kept, ["a"], "feedId 不变，历史文章留在原处")
    }

    func testStaleDaysThreshold() {
        let now = Date()
        XCTAssertEqual(
            SidebarData.staleDays(latestPublishedAt: now.addingTimeInterval(-31 * 86400), now: now), 31)
        XCTAssertNil(
            SidebarData.staleDays(latestPublishedAt: now.addingTimeInterval(-29 * 86400), now: now))
        XCTAssertNil(
            SidebarData.staleDays(latestPublishedAt: now.addingTimeInterval(-30 * 86400), now: now),
            "整 30 天不算超过")
        XCTAssertNil(SidebarData.staleDays(latestPublishedAt: nil, now: now),
                     "一篇文章都没有的源不标停更")
    }

    func testSidebarDataCarriesLatestPublishedPerFeed() async throws {
        let db = try makeTempDB()
        let stale = try await db.addFeed(url: "https://stale.example/rss", title: "停",
                                         siteURL: nil, folderId: nil)
        let live = try await db.addFeed(url: "https://live.example/rss", title: "活",
                                        siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: stale.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("old", daysAgo: 90), action: nil),
                    MuteEvaluation(item: item("less-old", daysAgo: 60), action: nil)])
        try await db.applyFetchSuccess(
            feedId: live.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("new", daysAgo: 1), action: nil)])

        let data = try await db.pool.read { try SidebarData.fetch($0) }
        XCTAssertEqual(data.staleDays(for: data.feeds.first { $0.id == stale.id }!), 60,
                       "取最新一篇，不是最老一篇")
        XCTAssertNil(data.staleDays(for: data.feeds.first { $0.id == live.id }!))
    }
}
