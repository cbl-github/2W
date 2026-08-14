import GRDB
import XCTest
@testable import BiFeed

/// M10：未读徽标、按源保留、读到这里为止、首批已读策略、正文搜索与保存搜索。
final class WorkflowTests: XCTestCase {
    private func item(_ guid: String, hoursAgo: Double = 0, title: String? = nil,
                      body: String = "") -> ParsedItem {
        ParsedItem(guid: guid, url: nil, title: title ?? guid, author: nil,
                   publishedAt: Date(timeIntervalSinceNow: -hoursAgo * 3600),
                   contentHTML: body, summaryText: "")
    }

    func testDisabledBadgeExcludesFeedFromUnreadCounts() async throws {
        let db = try makeTempDB()
        let folder = try await db.addFolder(name: "组")
        let noisy = try await db.addFeed(url: "https://noisy.example/rss", title: "吵",
                                         siteURL: nil, folderId: folder.id)
        let quiet = try await db.addFeed(url: "https://quiet.example/rss", title: "静",
                                         siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(feedId: noisy.id!, etag: nil, lastModified: nil,
                                       items: [MuteEvaluation(item: item("a"), action: nil),
                                               MuteEvaluation(item: item("b"), action: nil)])
        try await db.applyFetchSuccess(feedId: quiet.id!, etag: nil, lastModified: nil,
                                       items: [MuteEvaluation(item: item("c"), action: nil)])

        var data = try await db.pool.read { try SidebarData.fetch($0) }
        XCTAssertEqual(data.totalUnread, 3)

        try await db.setUnreadBadge(feedId: noisy.id!, false)
        data = try await db.pool.read { try SidebarData.fetch($0) }
        XCTAssertEqual(data.totalUnread, 1, "关掉徽标的源不计入总数")
        XCTAssertEqual(data.unreadBadge(for: data.feeds.first { $0.id == noisy.id }!), 0)
        XCTAssertEqual(data.unreadBadge(inFolder: folder.id!), 0)

        // 分组整组关掉：组里的源即使自己开着也不计数
        try await db.setUnreadBadge(feedId: noisy.id!, true)
        try await db.setUnreadBadge(folderId: folder.id!, false)
        data = try await db.pool.read { try SidebarData.fetch($0) }
        XCTAssertEqual(data.totalUnread, 1)
        XCTAssertEqual(data.unreadBadge(for: data.feeds.first { $0.id == noisy.id }!), 0)

        let list = try await db.pool.read { try ArticleListItem.fetchAll($0, scope: .all, search: nil) }
        XCTAssertEqual(list.count, 3, "徽标只改计数，不改列表内容")
    }

    func testPerFeedRetentionOverridesGlobal() async throws {
        let db = try makeTempDB()
        let capped = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let normal = try await db.addFeed(url: "https://b.example/rss", title: "B", siteURL: nil, folderId: nil)
        let items = (0..<6).map { MuteEvaluation(item: item("g\($0)", hoursAgo: Double($0)), action: nil) }
        try await db.applyFetchSuccess(feedId: capped.id!, etag: nil, lastModified: nil, items: items)
        try await db.applyFetchSuccess(feedId: normal.id!, etag: nil, lastModified: nil, items: items)
        try await db.setRetention(feedId: capped.id!, keepCount: 2, keepDays: nil)

        try await db.purge(keepCount: 5, keepDays: 0)
        let counts = try await db.pool.read { d in
            (try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM article WHERE feedId = ?",
                              arguments: [capped.id!]) ?? -1,
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM article WHERE feedId = ?",
                              arguments: [normal.id!]) ?? -1)
        }
        XCTAssertEqual(counts.0, 2, "按源覆盖优先于全局")
        XCTAssertEqual(counts.1, 5, "没有覆盖的源仍用全局值")
    }

    func testPerFeedKeepDaysOverridesGlobal() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("new", hoursAgo: 1), action: nil),
                    MuteEvaluation(item: item("old", hoursAgo: 24 * 10), action: nil)])
        try await db.setRetention(feedId: feed.id!, keepCount: nil, keepDays: 3)

        try await db.purge(keepCount: 500, keepDays: 0) // 全局不按时间清理
        let titles = try await db.pool.read { try String.fetchAll($0, sql: "SELECT title FROM article") }
        XCTAssertEqual(titles, ["new"])
    }

    func testPurgeAlsoDropsSearchIndexRows() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("keep", hoursAgo: 1), action: nil),
                    MuteEvaluation(item: item("drop", hoursAgo: 24 * 400), action: nil)])
        try await db.purge(keepCount: 500, keepDays: 30)
        let indexed = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM articleSearch") ?? -1
        }
        XCTAssertEqual(indexed, 1, "contentless_delete 让索引行随文章一起消失")
    }

    func testMarkReadReturnsOnlyPreviouslyUnread() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("a"), action: nil),
                    MuteEvaluation(item: item("b"), action: nil)])
        let ids = try await db.pool.read { try Int64.fetchAll($0, sql: "SELECT id FROM article ORDER BY id") }
        try await db.setRead(articleId: ids[0], true)

        let changed = try await db.markRead(ids: ids)
        XCTAssertEqual(changed, [ids[1]], "撤销名单不包含用户本来就读过的文章")
        let unread = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article WHERE isRead = 0") ?? -1
        }
        XCTAssertEqual(unread, 0)
    }

    func testInitialReadPolicyKeepsRecentUnread() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let items = (0..<5).map { MuteEvaluation(item: item("g\($0)", hoursAgo: Double($0)), action: nil) }
        try await db.applyFetchSuccess(feedId: feed.id!, etag: nil, lastModified: nil,
                                       items: items, initialPolicy: .keepRecent(2))

        let unread = try await db.pool.read {
            try String.fetchAll($0, sql: "SELECT title FROM article WHERE isRead = 0 ORDER BY publishedAt DESC")
        }
        XCTAssertEqual(unread, ["g0", "g1"], "只有最新的两条留作未读")
    }

    /// 撤销名单必须与真正被改动的行一致，否则撤销会把用户本来就读过的文章翻回未读。
    func testInitialReadPolicyReportsWhatItMarked() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let items = (0..<5).map { MuteEvaluation(item: item("g\($0)", hoursAgo: Double($0)), action: nil) }
        let result = try await db.applyFetchSuccess(feedId: feed.id!, etag: nil, lastModified: nil,
                                                    items: items, initialPolicy: .keepRecent(2))

        XCTAssertEqual(result.inserted, 5)
        let read = try await db.pool.read {
            try Int64.fetchAll($0, sql: "SELECT id FROM article WHERE isRead = 1 ORDER BY id")
        }
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(result.initialReadIds.sorted(), read)

        try await db.markUnread(ids: result.initialReadIds)
        let unread = try await db.pool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article WHERE isRead = 0") ?? -1
        }
        XCTAssertEqual(unread, 5, "撤销后全部回到未读")
    }

    func testInitialReadPolicyOnlyAppliesToInsertedItems() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(feedId: feed.id!, etag: nil, lastModified: nil,
                                       items: [MuteEvaluation(item: item("old"), action: nil)])
        // 第二批：老条目已在库里，只有新条目受策略影响
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("old"), action: nil),
                    MuteEvaluation(item: item("fresh"), action: nil)],
            initialPolicy: .allRead)
        let unread = try await db.pool.read {
            try String.fetchAll($0, sql: "SELECT title FROM article WHERE isRead = 0")
        }
        XCTAssertEqual(unread, ["old"])
    }

    func testSearchMatchesArticleBody() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("one", title: "Title one",
                                              body: "<p>peculiar detail inside</p>"), action: nil),
                    MuteEvaluation(item: item("two", title: "Title two"), action: nil)])

        let hits = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "peculiar")
        }
        XCTAssertEqual(hits.map(\.title), ["Title one"], "正文里的词也能搜到")

        let noTagHits = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "peculiar detail")
        }
        XCTAssertEqual(noTagHits.count, 1)
    }

    /// unicode61 不切分 CJK，中文词永远走 LIKE 路径——正文必须在那条路径上也能搜到。
    func testChineseSearchReachesArticleBody() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("one", title: "标题一",
                                              body: "<p>正文里提到了机械键盘</p>"), action: nil),
                    MuteEvaluation(item: item("two", title: "标题二"), action: nil)])

        let hits = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "机械键盘")
        }
        XCTAssertEqual(hits.map(\.title), ["标题一"])
    }

    /// 抓来的全文只存在 extractedHTML 里，LIKE 路径也要覆盖它。
    func testChineseSearchReachesExtractedFullText() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("one", title: "摘要源", body: "<p>只有一段</p>"), action: nil)])
        let id = try await db.pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM article")! }
        try await db.storeExtractedHTML(articleId: id, "<p>全文里才有的词：光刻机</p>")

        let hits = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "光刻机")
        }
        XCTAssertEqual(hits.map(\.title), ["摘要源"])
    }

    func testExtractedFullTextEntersSearchIndex() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("one", title: "Snippet", body: "<p>teaser</p>"), action: nil)])
        let id = try await db.pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM article")! }

        try await db.storeExtractedHTML(articleId: id, "<p>whole article mentions kryptonite</p>")
        let hits = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "kryptonite")
        }
        XCTAssertEqual(hits.map(\.title), ["Snippet"])
    }

    func testSearchWindowLimitsByPublishDate() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("recent", hoursAgo: 2, title: "swift recent"), action: nil),
                    MuteEvaluation(item: item("aged", hoursAgo: 24 * 60, title: "swift aged"), action: nil)])

        let all = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "swift")
        }
        XCTAssertEqual(all.count, 2)
        let recent = try await db.pool.read {
            try ArticleListItem.fetchAll($0, scope: .all, search: "swift",
                                         since: SearchWindow.month.since())
        }
        XCTAssertEqual(recent.map(\.title), ["swift recent"])
    }

    func testSavedSearchResolvesAndSurvivesDeletedScope() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let saved = try await SavedSearches.add(db, name: "关注", query: "swift",
                                                scope: .feed(feed.id!), window: .week, filter: "all")
        let resolved = try XCTUnwrap(SavedSearches.resolve(db, id: saved.id!))
        XCTAssertEqual(resolved.scope, .feed(feed.id!))
        XCTAssertEqual(resolved.saved.searchWindow, .week)

        try await db.deleteFeed(id: feed.id!)
        let orphan = try XCTUnwrap(SavedSearches.resolve(db, id: saved.id!))
        XCTAssertEqual(orphan.scope, .all, "范围目标被删后回落到全部文章")

        try await SavedSearches.delete(db, id: saved.id!)
        let remaining = try await db.pool.read { try SavedSearches.fetchAll($0) }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSavedSearchRemembersListFilter() async throws {
        let db = try makeTempDB()
        let saved = try await SavedSearches.add(db, name: "未读里的 swift", query: "swift",
                                                scope: .all, window: .any, filter: "unread")
        let resolved = try XCTUnwrap(SavedSearches.resolve(db, id: saved.id!))
        XCTAssertEqual(resolved.saved.filter, "unread")
    }

    /// 真实库停在 v10：v11 必须能在它之上干净应用，老行回落到 all。
    func testSavedFilterMigrationAppliesOnV10Database() throws {
        let path = NSTemporaryDirectory() + "bifeed-test-\(UUID().uuidString)/t.sqlite"
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: path)
        try AppDatabase.migrator.migrate(pool, upTo: "v10-search")
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO savedSearch (name, query, scopeKind, scopeId, window, createdAt)
                VALUES ('旧条目', 'swift', 'all', NULL, 'any', ?)
                """, arguments: [Date()])
        }

        try AppDatabase.migrator.migrate(pool)
        let saved = try pool.read { try SavedSearches.fetchAll($0) }
        XCTAssertEqual(saved.map(\.filter), ["all"])
    }

    // MARK: - 订阅重载

    func testResetFetchStateForcesFullRefetch() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: "e1", lastModified: "Mon, 01 Jan 2026 00:00:00 GMT",
            items: [MuteEvaluation(item: item("a"), action: nil)])
        try await db.applyFetchFailure(
            feedId: feed.id!, message: "HTTP 500", status: 500,
            nextFetchAt: Date(timeIntervalSinceNow: 3600), incrementFailure: true)

        try await db.resetFetchState(feedId: feed.id!)

        let fetched = try await db.feed(id: feed.id!)
        let stored = try XCTUnwrap(fetched)
        XCTAssertNil(stored.etag, "条件请求头必须清掉，否则服务器回 304 就白重载了")
        XCTAssertNil(stored.lastModified)
        XCTAssertNil(stored.bodyHash)
        XCTAssertNil(stored.nextFetchAt)
        XCTAssertNil(stored.lastHTTPStatus)
        XCTAssertNil(stored.fetchError)
        XCTAssertEqual(stored.failCount, 0)

        let kept = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM article") }
        XCTAssertEqual(kept, 1, "重新载入不动已有文章")
    }

    func testClearArticlesKeepsStarredAndDropsIndex() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let other = try await db.addFeed(url: "https://b.example/rss", title: "B", siteURL: nil, folderId: nil)
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("keep", title: "留下"), action: nil),
                    MuteEvaluation(item: item("drop", title: "删掉"), action: nil)])
        try await db.applyFetchSuccess(
            feedId: other.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item("other", title: "别的源"), action: nil)])
        let starred = try await db.pool.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM article WHERE title = '留下'")!
        }
        try await db.setStarred(articleId: starred, true)

        let removed = try await db.clearArticles(feedId: feed.id!)
        XCTAssertEqual(removed, 1)

        let (titles, indexed) = try await db.pool.read { d in
            (try String.fetchAll(d, sql: "SELECT title FROM article ORDER BY title"),
             try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM articleSearch") ?? -1)
        }
        XCTAssertEqual(titles, ["别的源", "留下"], "星标留下，别的源不受影响")
        XCTAssertEqual(indexed, 2, "索引行跟着删，不留孤儿")
    }
}
