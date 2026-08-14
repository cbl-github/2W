import GRDB
import XCTest
@testable import BiFeed

final class FetchReliabilityTests: XCTestCase {
    func testRetryAfterSupportsSecondsAndHTTPDate() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(FeedFetcher.retryAfter("120", now: now), now.addingTimeInterval(120))

        let date = try XCTUnwrap(FeedFetcher.retryAfter("Wed, 15 Nov 2023 00:00:00 GMT", now: now))
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_006_400, accuracy: 1)
        XCTAssertNil(FeedFetcher.retryAfter("later", now: now))
    }

    func testHostGroupsKeepSameDomainSerial() {
        let feeds = [feed("https://a.example/one"), feed("https://b.example/rss"),
                     feed("https://a.example/two")]
        let groups = FetchScheduler.hostGroups(feeds)
        XCTAssertEqual(groups.map { $0.map(\.url) }, [
            ["https://a.example/one", "https://a.example/two"],
            ["https://b.example/rss"],
        ])
    }

    func testTransientBackoffStartsAtFiveMinutesAndCapsAtSixHours() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(FetchScheduler.retryDate(afterFailureCount: 0, now: now),
                       now.addingTimeInterval(5 * 60))
        XCTAssertEqual(FetchScheduler.retryDate(afterFailureCount: 1, now: now),
                       now.addingTimeInterval(10 * 60))
        XCTAssertEqual(FetchScheduler.retryDate(afterFailureCount: 99, now: now),
                       now.addingTimeInterval(6 * 3600))
    }

    func testDueUsesPerFeedIntervalWhenSet() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let twentyMinutesAgo = now.addingTimeInterval(-20 * 60)

        XCTAssertTrue(FetchScheduler.isDue(lastFetchedAt: nil, feedMinutes: nil,
                                           globalMinutes: 120, now: now),
                      "没抓过的源永远到期")
        // 无覆盖：全局 30 分钟未到
        XCTAssertFalse(FetchScheduler.isDue(lastFetchedAt: twentyMinutesAgo, feedMinutes: nil,
                                            globalMinutes: 30, now: now))
        XCTAssertTrue(FetchScheduler.isDue(lastFetchedAt: twentyMinutesAgo, feedMinutes: nil,
                                           globalMinutes: 15, now: now))
        // 有覆盖：全局被忽略，两个方向都要生效
        XCTAssertTrue(FetchScheduler.isDue(lastFetchedAt: twentyMinutesAgo, feedMinutes: 15,
                                           globalMinutes: 120, now: now))
        XCTAssertFalse(FetchScheduler.isDue(lastFetchedAt: twentyMinutesAgo, feedMinutes: 60,
                                            globalMinutes: 15, now: now))
        // 边界：刚好到点算到期
        XCTAssertTrue(FetchScheduler.isDue(lastFetchedAt: twentyMinutesAgo, feedMinutes: 20,
                                           globalMinutes: 120, now: now))
    }

    /// 到期判定只管间隔；nextFetchAt 退避与 404/410 是 refreshOne 里另一层，两者叠加。
    func testBackoffStillBlocksWhenIntervalElapsed() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var f = feed("https://a.example/rss")
        f.lastFetchedAt = now.addingTimeInterval(-60 * 60)
        f.nextFetchAt = now.addingTimeInterval(30 * 60)
        XCTAssertTrue(FetchScheduler.isDue(lastFetchedAt: f.lastFetchedAt, feedMinutes: nil,
                                           globalMinutes: 30, now: now))
        XCTAssertTrue(f.nextFetchAt! > now, "间隔到了但退避未到，refreshOne 仍会跳过")
    }

    func testBasicAuthHeaderIsBase64OfUserColonPassword() {
        XCTAssertEqual(FeedFetcher.basicAuthHeader(user: "alice", password: "s3cret"),
                       "Basic YWxpY2U6czNjcmV0")
        // 密码可空（有站点只认用户名），用户名空即不认证
        XCTAssertEqual(FeedFetcher.basicAuthHeader(user: "alice", password: nil), "Basic YWxpY2U6")
        XCTAssertNil(FeedFetcher.basicAuthHeader(user: nil, password: "s3cret"))
        XCTAssertNil(FeedFetcher.basicAuthHeader(user: "", password: "s3cret"))
    }

    func testV12MigrationAppliesOnV11Database() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v11-saved-filter")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO feed (url, title, addedAt) VALUES ('https://a.example/rss', 'A', ?)",
                           arguments: [Date()])
        }

        try AppDatabase.migrator.migrate(queue)

        let feed = try queue.read { db in try Feed.fetchOne(db, sql: "SELECT * FROM feed") }
        XCTAssertNotNil(feed, "存量行不能被迁移丢掉")
        XCTAssertNil(feed?.userAgent)
        XCTAssertNil(feed?.basicUser)
        XCTAssertNil(feed?.refreshMinutes, "NULL = 跟随全局间隔")
    }

    private func feed(_ url: String) -> Feed {
        Feed(id: nil, url: url, title: url, siteURL: nil, folderId: nil, addedAt: Date())
    }

    // MARK: - 手动刷新不受任何拦截（Paul 实测：退避中的源必须逐个右键刷新）

    func testManualRefreshNeverSkips() {
        let future = Date(timeIntervalSinceNow: 3600)
        // 退避中
        XCTAssertFalse(FetchScheduler.shouldSkip(
            manual: true, host: "a.example", lastHTTPStatus: 500,
            failCount: 3, nextFetchAt: future))
        // 硬错误
        XCTAssertFalse(FetchScheduler.shouldSkip(
            manual: true, host: "a.example", lastHTTPStatus: 404,
            failCount: 9, nextFetchAt: nil))
        // 两者同时
        XCTAssertFalse(FetchScheduler.shouldSkip(
            manual: true, host: "a.example", lastHTTPStatus: 410,
            failCount: 9, nextFetchAt: future))
    }

    func testAutomaticRefreshRespectsBackoffAndHardErrors() {
        let future = Date(timeIntervalSinceNow: 3600)
        let past = Date(timeIntervalSinceNow: -3600)
        XCTAssertTrue(FetchScheduler.shouldSkip(
            manual: false, host: "a.example", lastHTTPStatus: 500,
            failCount: 3, nextFetchAt: future), "退避未到期不刷")
        XCTAssertTrue(FetchScheduler.shouldSkip(
            manual: false, host: "a.example", lastHTTPStatus: 404,
            failCount: 9, nextFetchAt: nil), "硬错误停自动重试")
        XCTAssertFalse(FetchScheduler.shouldSkip(
            manual: false, host: "a.example", lastHTTPStatus: 500,
            failCount: 3, nextFetchAt: past), "退避到期了就刷")
        XCTAssertFalse(FetchScheduler.shouldSkip(
            manual: false, host: "a.example", lastHTTPStatus: 200,
            failCount: 0, nextFetchAt: nil), "健康源照常刷")
        XCTAssertFalse(FetchScheduler.shouldSkip(
            manual: false, host: "www.youtube.com", lastHTTPStatus: 404,
            failCount: 1, nextFetchAt: nil), "YouTube 的 404 在容忍期内不算硬错误")
    }
}
