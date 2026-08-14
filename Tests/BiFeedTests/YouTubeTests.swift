import GRDB
import XCTest
@testable import BiFeed

/// 需求 18 的 YouTube 专项：频道地址转换、Shorts 过滤、404 分类、v13 迁移。
/// 全部喂样本，不打真实网络。
final class YouTubeTests: XCTestCase {

    // MARK: - A. 频道地址 → feed 地址

    func testChannelURLBuildsFeedURLDirectly() {
        XCTAssertEqual(YouTube.channelTarget("https://www.youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ"),
                       .feed(URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ")!))
        // 没有 scheme 也要认
        XCTAssertEqual(YouTube.channelTarget("youtube.com/channel/UCBJycsmduvYEL83R_U4JriQ"),
                       .feed(URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ")!))
    }

    func testHandleAndVanityURLsNeedChannelPage() {
        XCTAssertEqual(YouTube.channelTarget("https://www.youtube.com/@mkbhd"),
                       .page(URL(string: "https://www.youtube.com/@mkbhd")!))
        XCTAssertEqual(YouTube.channelTarget("youtube.com/c/veritasium"),
                       .page(URL(string: "https://youtube.com/c/veritasium")!))
        XCTAssertEqual(YouTube.channelTarget("youtube.com/user/vlogbrothers"),
                       .page(URL(string: "https://youtube.com/user/vlogbrothers")!))
        // 裸 handle：补成频道页地址
        XCTAssertEqual(YouTube.channelTarget("  @mkbhd  "),
                       .page(URL(string: "https://www.youtube.com/@mkbhd")!))
    }

    func testNonChannelInputsFallThroughToNormalResolution() {
        XCTAssertNil(YouTube.channelTarget("https://example.com/@mkbhd"), "别的站点的 @ 路径不是频道")
        XCTAssertNil(YouTube.channelTarget("https://example.com/feed"))
        XCTAssertNil(YouTube.channelTarget("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTube.channelTarget(
            "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ"),
                     "已经是 feed 地址，原样交给通用流程")
        XCTAssertNil(YouTube.channelTarget("notyoutube.com/@x"))
        XCTAssertNil(YouTube.channelTarget("mailto:hi@example.com"))
    }

    func testChannelIDFromEmbeddedJSON() {
        let html = """
            <!DOCTYPE html><html><head><title>MKBHD</title></head><body>
            <script>var ytInitialData = {"header":{"c4TabbedHeaderRenderer":\
            {"channelId":"UCBJycsmduvYEL83R_U4JriQ","title":"MKBHD"}}};</script>
            </body></html>
            """
        XCTAssertEqual(YouTube.channelID(inHTML: html), "UCBJycsmduvYEL83R_U4JriQ")
    }

    func testChannelIDFromCanonicalLink() {
        let html = """
            <!DOCTYPE html><html><head>
            <link rel="canonical" href="https://www.youtube.com/channel/UC295-dw_tDNtZXFeAPAW6Aw">
            </head><body>没有内嵌 JSON 的降级页面</body></html>
            """
        XCTAssertEqual(YouTube.channelID(inHTML: html), "UC295-dw_tDNtZXFeAPAW6Aw")
        XCTAssertNil(YouTube.channelID(inHTML: "<html><body>404</body></html>"),
                     "抓不到 id 时返回 nil，调用方落到「没有发现 feed」")
    }

    // MARK: - B. Shorts 过滤

    func testShortsDetectionOnlyMatchesYouTubeShortsPath() {
        XCTAssertTrue(YouTube.isShorts("https://www.youtube.com/shorts/abc123"))
        XCTAssertTrue(YouTube.isShorts("https://youtube.com/shorts/abc123?si=x"))
        XCTAssertFalse(YouTube.isShorts("https://www.youtube.com/watch?v=abc123"))
        XCTAssertFalse(YouTube.isShorts("https://example.com/shorts/abc123"), "别的站点同名路径不误伤")
        XCTAssertFalse(YouTube.isShorts(nil))
    }

    func testDropShortsOnlyWhenEnabled() {
        let items = [item("v1", "https://www.youtube.com/watch?v=1"),
                     item("s1", "https://www.youtube.com/shorts/2"),
                     item("v2", "https://www.youtube.com/watch?v=3")]
        XCTAssertEqual(FetchScheduler.dropShorts(items, enabled: true).map(\.guid), ["v1", "v2"])
        XCTAssertEqual(FetchScheduler.dropShorts(items, enabled: false).map(\.guid),
                       ["v1", "s1", "v2"], "开关关着一条都不丢")
    }

    func testFilteredShortsNeverReachTheDatabase() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1",
                                        title: "Y", siteURL: nil, folderId: nil)
        let items = [item("v1", "https://www.youtube.com/watch?v=1"),
                     item("s1", "https://www.youtube.com/shorts/2")]

        try await db.setFilterShorts(feedId: feed.id!, true)
        let stored = try await db.feed(id: feed.id!)
        XCTAssertEqual(stored?.filterShorts, true)

        let kept = FetchScheduler.dropShorts(items, enabled: stored?.filterShorts ?? false)
        try await db.applyFetchSuccess(feedId: feed.id!, etag: nil, lastModified: nil,
                                       items: kept.map { MuteEvaluation(item: $0, action: nil) })
        let guids = try await db.pool.read { d in
            try String.fetchAll(d, sql: "SELECT guid FROM article ORDER BY guid")
        }
        XCTAssertEqual(guids, ["v1"], "Shorts 不入库，不是静音")
    }

    // MARK: - D. 404 重试三次

    func testYouTube404BacksOffThreeTimesThenGoesHard() {
        let host = "www.youtube.com"
        for count in 1...3 {
            XCTAssertEqual(FetchScheduler.failureKind(host: host, code: 404, failCount: count),
                           .backoff, "第 \(count) 次 404 还当暂时错误")
        }
        XCTAssertEqual(FetchScheduler.failureKind(host: host, code: 404, failCount: 4), .hard,
                       "连续第 4 次 404 才停自动重试")
        XCTAssertEqual(FetchScheduler.failureKind(host: host, code: 410, failCount: 1), .hard,
                       "410 是明确的永久删除，不宽容")
    }

    func testNonYouTube404IsHardOnFirstFailure() {
        XCTAssertEqual(FetchScheduler.failureKind(host: "example.com", code: 404, failCount: 1), .hard)
        XCTAssertEqual(FetchScheduler.failureKind(host: nil, code: 404, failCount: 1), .hard)
        // 限流与普通错误的分类不受本批改动影响
        XCTAssertEqual(FetchScheduler.failureKind(host: "www.youtube.com", code: 429, failCount: 9),
                       .throttled)
        XCTAssertEqual(FetchScheduler.failureKind(host: "example.com", code: 403, failCount: 1),
                       .throttled)
        XCTAssertEqual(FetchScheduler.failureKind(host: "example.com", code: 500, failCount: 1),
                       .backoff)
    }

    // MARK: - E. UI 判定

    func testFeedURLRecognitionGatesTheYouTubeSection() {
        XCTAssertTrue(YouTube.isFeedURL("https://www.youtube.com/feeds/videos.xml?channel_id=UC1"))
        XCTAssertFalse(YouTube.isFeedURL("https://example.com/feed"))
    }

    /// 界面的"已停止自动重试"必须跟着调度器走，容忍期内不能提前挂红灯。
    func testHardErrorFlagFollowsTheSchedulerDuringYouTubeTolerance() {
        var feed = Feed(id: 1, url: "https://www.youtube.com/feeds/videos.xml?channel_id=UC1",
                        title: "Y", siteURL: nil, folderId: nil, addedAt: Date())
        feed.lastHTTPStatus = 404
        feed.failCount = 2
        XCTAssertFalse(feed.isHardErrored, "还在退避重试，界面不该说已停止")
        feed.failCount = 4
        XCTAssertTrue(feed.isHardErrored)

        var other = feed
        other.url = "https://example.com/rss"
        other.failCount = 1
        XCTAssertTrue(other.isHardErrored, "别的站点 404 首次即硬错误")
        other.lastHTTPStatus = nil
        XCTAssertFalse(other.isHardErrored)
    }

    // MARK: - 迁移

    func testV13MigrationAppliesOnV12Database() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v12-fetch-config")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO feed (url, title, addedAt) VALUES ('https://a.example/rss', 'A', ?)",
                           arguments: [Date()])
        }

        try AppDatabase.migrator.migrate(queue)

        let feed = try queue.read { db in try Feed.fetchOne(db, sql: "SELECT * FROM feed") }
        XCTAssertNotNil(feed, "存量行不能被迁移丢掉")
        XCTAssertEqual(feed?.filterShorts, false, "默认不过滤，行为不变")
    }

    private func item(_ guid: String, _ url: String) -> ParsedItem {
        ParsedItem(guid: guid, url: url, title: guid, author: nil, publishedAt: Date(),
                   contentHTML: "", summaryText: "")
    }
}
