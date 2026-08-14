import Foundation
import GRDB

/// 数据库门面。打开失败直接 fatal（工程原则：不变量破坏 fail fast）。
final class AppDatabase: Sendable {
    let pool: DatabasePool

    init(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // 待恢复的备份必须在连接池打开之前换上去（M11）
        Backup.applyPendingRestore(dbPath: path)
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    static func defaultPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("BiFeed/bifeed.sqlite").path
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "folder") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
            }
            try db.create(table: "feed") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
                t.column("siteURL", .text)
                t.column("folderId", .integer).references("folder", onDelete: .setNull)
                t.column("addedAt", .datetime).notNull()
                t.column("lastFetchedAt", .datetime)
                t.column("etag", .text)
                t.column("lastModified", .text)
                t.column("fetchError", .text)
                t.column("autoTranslate", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "article") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("feedId", .integer).notNull().references("feed", onDelete: .cascade)
                t.column("guid", .text).notNull()
                t.column("url", .text)
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("publishedAt", .datetime)
                t.column("summary", .text).notNull()
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isStarred", .boolean).notNull().defaults(to: false)
                t.uniqueKey(["feedId", "guid"])
            }
            try db.create(index: "idx_article_feed_published", on: "article", columns: ["feedId", "publishedAt"])
            try db.create(index: "idx_article_published", on: "article", columns: ["publishedAt"])
            try db.create(table: "articleContent") { t in
                t.primaryKey("articleId", .integer).references("article", onDelete: .cascade)
                t.column("html", .text).notNull()
            }
            try db.create(table: "translation") { t in
                t.column("articleId", .integer).notNull().references("article", onDelete: .cascade)
                t.column("blockIndex", .integer).notNull()
                t.column("targetLang", .text).notNull()
                t.column("text", .text).notNull()
                t.primaryKey(["articleId", "blockIndex", "targetLang"])
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "article") { t in
                t.add(column: "commentsURL", .text)
            }
            try db.create(table: "forumThread") { t in
                t.primaryKey("articleId", .integer).references("article", onDelete: .cascade)
                t.column("json", .text).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            // translation 表重建：主键扩成 (articleId, blockIndex, targetLang, engine)，
            // 新增 sourceHash 做失效判定。老数据 engine='apple'、sourceHash=''——
            // 空 hash 必然 miss，老缓存一次性重翻，可接受。
            try db.execute(sql: """
                CREATE TABLE translation_new (
                    articleId INTEGER NOT NULL REFERENCES article ON DELETE CASCADE,
                    blockIndex INTEGER NOT NULL,
                    targetLang TEXT NOT NULL,
                    engine TEXT NOT NULL DEFAULT 'apple',
                    sourceHash TEXT NOT NULL DEFAULT '',
                    text TEXT NOT NULL,
                    PRIMARY KEY (articleId, blockIndex, targetLang, engine)
                )
                """)
            try db.execute(sql: """
                INSERT INTO translation_new (articleId, blockIndex, targetLang, engine, sourceHash, text)
                SELECT articleId, blockIndex, targetLang, 'apple', '', text FROM translation
                """)
            try db.execute(sql: "DROP TABLE translation")
            try db.execute(sql: "ALTER TABLE translation_new RENAME TO translation")
        }
        m.registerMigration("v3") { db in
            try db.execute(sql: "ALTER TABLE article ADD COLUMN readingProgress REAL NOT NULL DEFAULT 0")
        }
        m.registerMigration("v4") { db in
            // 全文抓取缓存：NULL = 未抓取过
            try db.execute(sql: "ALTER TABLE articleContent ADD COLUMN extractedHTML TEXT")
        }
        m.registerMigration("v5") { db in
            // 死源检测 + 内容指纹（FetchScheduler 维护这三列，成功清零/失败自增）
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN failCount INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN lastSuccessAt DATETIME")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN bodyHash TEXT")
            // 关键词静音规则：scopeFeedId NULL = 全局规则
            try db.execute(sql: """
                CREATE TABLE muteRule (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pattern TEXT NOT NULL,
                    scopeFeedId INTEGER REFERENCES feed ON DELETE CASCADE,
                    titleOnly BOOLEAN NOT NULL DEFAULT 1,
                    createdAt DATETIME NOT NULL
                )
                """)
            // 命中静音的文章仍入库：isMuted=1，不计未读、默认不显示
            try db.execute(sql: "ALTER TABLE article ADD COLUMN isMuted BOOLEAN NOT NULL DEFAULT 0")
            // contentless FTS5：行由入库代码同步写（applyFetchSuccess，rowid=article.id）。
            // contentless 表不支持 DELETE，purge 后的残留行靠搜索时 JOIN 回 article 自然滤掉；
            // article.id 是 AUTOINCREMENT，rowid 不会复用，残留行不会与新文章撞号。
            try db.execute(sql: """
                CREATE VIRTUAL TABLE articleSearch USING fts5(title, summary, content='', tokenize='unicode61')
                """)
            // 存量文章初始回填
            try db.execute(sql: "INSERT INTO articleSearch(rowid, title, summary) SELECT id, title, summary FROM article")
        }
        m.registerMigration("v6") { db in
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN lastHTTPStatus INTEGER")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN nextFetchAt DATETIME")
        }
        m.registerMigration("v7-mute-rules") { db in
            try db.execute(sql: "ALTER TABLE muteRule ADD COLUMN matchType TEXT NOT NULL DEFAULT 'contains'")
            try db.execute(sql: "ALTER TABLE muteRule ADD COLUMN field TEXT NOT NULL DEFAULT 'title'")
            try db.execute(sql: "ALTER TABLE muteRule ADD COLUMN scopeFolderId INTEGER REFERENCES folder ON DELETE CASCADE")
            try db.execute(sql: "ALTER TABLE muteRule ADD COLUMN exceptions TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE muteRule ADD COLUMN action TEXT NOT NULL DEFAULT 'hide'")
            try db.execute(sql: "UPDATE muteRule SET field = 'all' WHERE titleOnly = 0")
            try db.execute(sql: "ALTER TABLE article ADD COLUMN categories TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE article ADD COLUMN isCollapsed BOOLEAN NOT NULL DEFAULT 0")
        }
        m.registerMigration("v7-dedup") { db in
            try db.execute(sql: "ALTER TABLE article ADD COLUMN normalizedURL TEXT")
            for row in try Row.fetchAll(db, sql: "SELECT id, url FROM article WHERE url IS NOT NULL") {
                try db.execute(sql: "UPDATE article SET normalizedURL = ? WHERE id = ?",
                               arguments: [URLNormalizer.normalized(row["url"]), row["id"] as Int64])
            }
            try db.create(index: "idx_article_normalized_url", on: "article", columns: ["normalizedURL"])
        }
        m.registerMigration("v8-full-text") { db in
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN fullTextMode TEXT NOT NULL DEFAULT 'auto'")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN fullTextSelector TEXT")
        }
        m.registerMigration("v9-workflow") { db in
            try db.execute(sql: "ALTER TABLE folder ADD COLUMN showsUnreadBadge BOOLEAN NOT NULL DEFAULT 1")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN showsUnreadBadge BOOLEAN NOT NULL DEFAULT 1")
            // NULL = 跟随全局设置；0 天在 purge 里与全局同义（不按时间清理）
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN keepCount INTEGER")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN keepDays INTEGER")
        }
        m.registerMigration("v10-search") { db in
            // FTS5 重建：加 body 列（正文纯文本），并开 contentless_delete —— 有了它 purge
            // 才能同步删索引行，v5 注释里"残留行靠 JOIN 滤掉"的将就做法到此为止。
            // contentless_delete 需要 SQLite ≥ 3.43；应用最低 macOS 15 自带 3.43.2。
            try db.execute(sql: "DROP TABLE articleSearch")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE articleSearch USING fts5(
                    title, summary, body, content='', contentless_delete=1, tokenize='unicode61')
                """)
            let rows = try Row.fetchAll(db, sql: """
                SELECT article.id AS id, article.title AS title, article.summary AS summary,
                       COALESCE(articleContent.extractedHTML, articleContent.html, '') AS body
                FROM article LEFT JOIN articleContent ON articleContent.articleId = article.id
                """)
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO articleSearch(rowid, title, summary, body) VALUES (?, ?, ?, ?)",
                    arguments: [row["id"] as Int64, row["title"], row["summary"],
                                HTMLTools.plainText(row["body"])])
            }
            // 保存的搜索。scopeId 按 scopeKind 指向 feed 或 folder，一列指两张表所以不加外键；
            // 目标被删后 resolve 回落到「全部文章」，不留死链接。
            try db.execute(sql: """
                CREATE TABLE savedSearch (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    query TEXT NOT NULL,
                    scopeKind TEXT NOT NULL,
                    scopeId INTEGER,
                    window TEXT NOT NULL DEFAULT 'any',
                    createdAt DATETIME NOT NULL
                )
                """)
        }
        m.registerMigration("v11-saved-filter") { db in
            // 保存搜索记住保存时刻的列表过滤（"all" | "unread" | "starred"）
            try db.execute(sql: "ALTER TABLE savedSearch ADD COLUMN filter TEXT NOT NULL DEFAULT 'all'")
        }
        m.registerMigration("v12-fetch-config") { db in
            // 按源抓取配置。三列都是 NULL = 用默认（默认 UA / 无认证 / 跟随全局间隔）。
            // Basic 密码有意不落库：只进钥匙串（KeychainStore.basicAccount），
            // 所以数据库文件与 OPML 备份里都不会出现明文口令。
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN userAgent TEXT")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN basicUser TEXT")
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN refreshMinutes INTEGER")
        }
        m.registerMigration("v13-youtube") { db in
            // 按源过滤 Shorts（需求 18）。只影响之后新抓的条目，已入库的不回扫。
            try db.execute(sql: "ALTER TABLE feed ADD COLUMN filterShorts BOOLEAN NOT NULL DEFAULT 0")
        }
        return m
    }
}

/// applyFetchSuccess 的结果：新增条数 + 被首批已读策略标掉的 id（撤销名单，无策略时为空）。
struct FetchApplyResult: Sendable {
    var inserted: Int
    var initialReadIds: [Int64]
}

// MARK: - 写操作

extension AppDatabase {
    @discardableResult
    func addFolder(name: String) async throws -> Folder {
        try await pool.write { db in
            var f = Folder(id: nil, name: name)
            try f.insert(db)
            return f
        }
    }

    func renameFolder(id: Int64, to name: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    func deleteFolder(id: Int64) async throws {
        try await pool.write { db in
            _ = try Folder.deleteOne(db, key: id) // feed.folderId 外键 SET NULL
        }
    }

    /// 全文策略取设置里的全局默认（只对新增订阅生效，已有订阅不动）。
    @discardableResult
    func addFeed(url: String, title: String, siteURL: String?, folderId: Int64?) async throws -> Feed {
        let mode = FullTextMode(
            rawValue: UserDefaults.standard.string(forKey: SettingsKey.defaultFullTextMode) ?? "") ?? .auto
        return try await pool.write { db in
            var f = Feed(id: nil, url: url, title: title, siteURL: siteURL,
                         folderId: folderId, addedAt: Date(), fullTextMode: mode)
            try f.insert(db)
            return f
        }
    }

    func deleteFeed(id: Int64) async throws {
        try await pool.write { db in _ = try Feed.deleteOne(db, key: id) }
        // 退订即销毁凭据：钥匙串条目不随数据库行走，漏删就会永远留在系统里
        KeychainStore.set(account: KeychainStore.basicAccount(feedId: id), value: "")
    }

    func renameFeed(id: Int64, to title: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE feed SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    /// 死源改址（需求 7 第二级）：换地址，并清掉一切绑在旧地址上的状态——
    /// 条件请求头和内容指纹属于旧资源，留着会让新地址第一次抓取就被误判成"没变"。
    /// feedId 不变，历史文章原样留在这个源下。
    /// 清掉条件请求与内容指纹，下次抓取必然拿全量正文而不是 304 / 指纹相同就跳过。
    /// 顺带清错误与退避，让重载立刻能跑。文章不动——按 (feedId, guid) 去重，重抓不会产生副本。
    func resetFetchState(feedId: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE feed SET etag = NULL, lastModified = NULL, bodyHash = NULL,
                    fetchError = NULL, lastHTTPStatus = NULL, nextFetchAt = NULL,
                    failCount = 0, lastFetchedAt = NULL
                WHERE id = ?
                """, arguments: [feedId])
        }
    }

    /// 清空一个源已入库的文章，为「清空并重新载入」用。星标默认豁免。
    /// 正文、译文、楼层缓存随外键级联删除；FTS 索引没有外键，必须显式删同一批 rowid。
    /// 返回删除条数。
    @discardableResult
    func clearArticles(feedId: Int64, keepStarred: Bool = true) async throws -> Int {
        try await pool.write { db in
            let condition = keepStarred ? "feedId = ? AND isStarred = 0" : "feedId = ?"
            let doomed = try Int64.fetchAll(
                db, sql: "SELECT id FROM article WHERE \(condition)", arguments: [feedId])
            guard !doomed.isEmpty else { return 0 }
            let list = doomed.map(String.init).joined(separator: ",")
            try db.execute(sql: "DELETE FROM article WHERE id IN (\(list))")
            try db.execute(sql: "DELETE FROM articleSearch WHERE rowid IN (\(list))")
            return doomed.count
        }
    }

    func relocateFeed(id: Int64, to url: String) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE feed SET url = ?, etag = NULL, lastModified = NULL, bodyHash = NULL,
                    fetchError = NULL, lastHTTPStatus = NULL, nextFetchAt = NULL, failCount = 0
                WHERE id = ?
                """, arguments: [url, id])
        }
    }

    func moveFeed(id: Int64, toFolder folderId: Int64?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE feed SET folderId = ? WHERE id = ?", arguments: [folderId, id])
        }
    }

    func setFullTextPolicy(feedId: Int64, mode: FullTextMode, selector: String?) async throws {
        let trimmed = selector?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await pool.write { db in
            try db.execute(sql: "UPDATE feed SET fullTextMode = ?, fullTextSelector = ? WHERE id = ?",
                           arguments: [mode.rawValue, trimmed?.isEmpty == true ? nil : trimmed, feedId])
        }
    }

    /// 按源抓取配置。空串一律存成 NULL（= 用默认），UI 靠清空输入框关掉覆盖。
    func setFetchConfig(feedId: Int64, userAgent: String?, basicUser: String?,
                        refreshMinutes: Int?) async throws {
        let clean = { (s: String?) -> String? in
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines)
            return t?.isEmpty == false ? t : nil
        }
        let (ua, user) = (clean(userAgent), clean(basicUser))
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE feed SET userAgent = ?, basicUser = ?, refreshMinutes = ? WHERE id = ?",
                arguments: [ua, user, refreshMinutes, feedId])
        }
    }

    func setUnreadBadge(feedId: Int64, _ shown: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE feed SET showsUnreadBadge = ? WHERE id = ?",
                           arguments: [shown, feedId])
        }
    }

    func setUnreadBadge(folderId: Int64, _ shown: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE folder SET showsUnreadBadge = ? WHERE id = ?",
                           arguments: [shown, folderId])
        }
    }

    func setFilterShorts(feedId: Int64, _ on: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE feed SET filterShorts = ? WHERE id = ?",
                           arguments: [on, feedId])
        }
    }

    /// nil = 跟随全局设置。
    func setRetention(feedId: Int64, keepCount: Int?, keepDays: Int?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE feed SET keepCount = ?, keepDays = ? WHERE id = ?",
                           arguments: [keepCount, keepDays, feedId])
        }
    }

    /// 抓取成功：更新条件请求头与时间，清错误；插入新文章（按 (feedId, guid) 去重，旧文不覆盖）。
    /// 规则动作由调用方在入库前用 MuteRules.evaluate 算好。
    /// initialPolicy 非 nil = 这是本源的首批文章（调用方按 lastSuccessAt 判定），按策略预设已读状态。
    @discardableResult
    func applyFetchSuccess(feedId: Int64, etag: String?, lastModified: String?,
                           items: [MuteEvaluation],
                           initialPolicy: InitialReadPolicy? = nil) async throws -> FetchApplyResult {
        try await pool.write { db in
            // lastSuccessAt 在这里也写：订阅路径不经过调度器的 markHealthy，
            // 不写的话下一轮刷新会把订阅后的新文章误判成"首批"再套一次已读策略。
            try db.execute(sql: """
                UPDATE feed SET lastFetchedAt = ?, etag = ?, lastModified = ?, fetchError = NULL,
                    lastHTTPStatus = 200, nextFetchAt = NULL, lastSuccessAt = ?
                WHERE id = ?
                """, arguments: [Date(), etag, lastModified, Date(), feedId])
            var inserted = 0
            var insertedIds: [Int64] = []
            for evaluated in items {
                let item = evaluated.item
                let action = evaluated.action
                try db.execute(
                    sql: """
                    INSERT INTO article
                        (feedId, guid, url, title, author, publishedAt, summary, isRead,
                         isStarred, commentsURL, isMuted, categories, isCollapsed, normalizedURL)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    ON CONFLICT(feedId, guid) DO NOTHING
                    """,
                    arguments: [feedId, item.guid, item.url, item.title, item.author, item.publishedAt,
                                item.summaryText, action == .markRead, item.commentsURL,
                                action == .hide, item.categories.joined(separator: "\n"),
                                action == .collapse, URLNormalizer.normalized(item.url)])
                if db.changesCount > 0 {
                    inserted += 1
                    let rowid = db.lastInsertedRowID
                    insertedIds.append(rowid)
                    try ArticleContent(articleId: rowid, html: item.contentHTML).insert(db)
                    // FTS 索引与文章同事务落库；rowid=article.id 是 JOIN 回列表的依据。
                    // body 存纯文本：索引 HTML 会把标签名和属性变成可搜的词。
                    try db.execute(
                        sql: "INSERT INTO articleSearch(rowid, title, summary, body) VALUES (?, ?, ?, ?)",
                        arguments: [rowid, item.title, item.summaryText,
                                    HTMLTools.plainText(item.contentHTML)])
                } else if let comments = item.commentsURL {
                    // v2 迁移前入库的旧文章 commentsURL 为 NULL（HN 论坛识别靠它），
                    // 借每次刷新对仍在 feed 窗口内的旧行做一次性回填。
                    try db.execute(
                        sql: "UPDATE article SET commentsURL = ? WHERE feedId = ? AND guid = ? AND commentsURL IS NULL",
                        arguments: [comments, feedId, item.guid])
                }
            }
            return FetchApplyResult(
                inserted: inserted,
                initialReadIds: try Self.applyInitialReadPolicy(
                    db, policy: initialPolicy, insertedIds: insertedIds))
        }
    }

    /// 新增订阅的首批文章：全未读（默认）、全已读、或只留最近 N 条未读。
    /// 静音规则已在入库时定过 isRead，这里只往「已读」方向叠加，不会把它改回未读。
    /// 返回本次真正被标已读的 id（撤销名单），静音规则本来就标读的不算在内。
    private static func applyInitialReadPolicy(_ db: Database, policy: InitialReadPolicy?,
                                               insertedIds: [Int64]) throws -> [Int64] {
        guard let policy, !insertedIds.isEmpty else { return [] }
        let list = insertedIds.map(String.init).joined(separator: ",")
        var condition = "id IN (\(list)) AND isRead = 0"
        var arguments: StatementArguments = []
        switch policy {
        case .allUnread:
            return []
        case .allRead:
            break
        case .keepRecent(let count):
            condition += """
                 AND id NOT IN (
                    SELECT id FROM article WHERE id IN (\(list))
                    ORDER BY publishedAt IS NULL, publishedAt DESC, id DESC LIMIT ?
                )
                """
            arguments = [count]
        }
        let doomed = try Int64.fetchAll(
            db, sql: "SELECT id FROM article WHERE \(condition)", arguments: arguments)
        guard !doomed.isEmpty else { return [] }
        try db.execute(
            sql: "UPDATE article SET isRead = 1 WHERE id IN (\(doomed.map(String.init).joined(separator: ",")))")
        return doomed
    }

    func applyFetchNotModified(feedId: Int64, status: Int = 304) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE feed SET lastFetchedAt = ?, fetchError = NULL,
                    lastHTTPStatus = ?, nextFetchAt = NULL
                WHERE id = ?
                """,
                           arguments: [Date(), status, feedId])
        }
    }

    func applyFetchFailure(feedId: Int64, message: String, status: Int?, nextFetchAt: Date?,
                           incrementFailure: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE feed SET lastFetchedAt = ?, fetchError = ?, lastHTTPStatus = ?, nextFetchAt = ?,
                    failCount = failCount + ?
                WHERE id = ?
                """, arguments: [Date(), message, status, nextFetchAt, incrementFailure ? 1 : 0, feedId])
        }
    }

    func setRead(articleId: Int64, _ read: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE article SET isRead = ? WHERE id = ?", arguments: [read, articleId])
        }
    }

    func setStarred(articleId: Int64, _ starred: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE article SET isStarred = ? WHERE id = ?", arguments: [starred, articleId])
        }
    }

    func setReadingProgress(articleId: Int64, _ value: Double) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE article SET readingProgress = ? WHERE id = ?", arguments: [value, articleId])
        }
    }

    /// 当前范围全部标记已读。返回受影响的 id，供「撤销已读」用。
    @discardableResult
    func markAllRead(scope: SidebarSelection) async throws -> [Int64] {
        try await pool.write { db in
            let condition: String
            var args: [any DatabaseValueConvertible] = []
            switch scope {
            case .all, .allUnread:
                condition = "isRead = 0"
            case .today:
                // 与 ArticleListItem.fetchAll 的 .today 条件同口径（本地时区自然日）
                condition = "isRead = 0 AND date(publishedAt, 'localtime') = date('now', 'localtime')"
            case .starred:
                condition = "isRead = 0 AND isStarred = 1"
            case .muted:
                condition = "isRead = 0 AND isMuted = 1"
            case .folder(let fid):
                condition = "isRead = 0 AND feedId IN (SELECT id FROM feed WHERE folderId = ?)"
                args.append(fid)
            case .feed(let fid):
                condition = "isRead = 0 AND feedId = ?"
                args.append(fid)
            case .savedSearch:
                // 保存的搜索没有单一 SQL 范围；列表视图改用 markRead(ids:) 处理可见条目。
                return []
            }
            // 先取受影响 id 再改：撤销需要精确名单，"全部标未读"会波及历史已读
            let ids = try Int64.fetchAll(
                db, sql: "SELECT id FROM article WHERE \(condition)",
                arguments: StatementArguments(args))
            try db.execute(sql: "UPDATE article SET isRead = 1 WHERE \(condition)",
                           arguments: StatementArguments(args))
            return ids
        }
    }

    /// 指定文章标为已读（「从这里往下全标已读」用）。返回本次真正改动的 id，供撤销用。
    @discardableResult
    func markRead(ids: [Int64]) async throws -> [Int64] {
        guard !ids.isEmpty else { return [] }
        return try await pool.write { db in
            let list = ids.map(String.init).joined(separator: ",")
            let changed = try Int64.fetchAll(
                db, sql: "SELECT id FROM article WHERE isRead = 0 AND id IN (\(list))")
            try db.execute(sql: "UPDATE article SET isRead = 1 WHERE id IN (\(list))")
            return changed
        }
    }

    /// 撤销「全部标为已读」：只回退当次名单里的文章。
    func markUnread(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await pool.write { db in
            let list = ids.map(String.init).joined(separator: ",")
            try db.execute(sql: "UPDATE article SET isRead = 0 WHERE id IN (\(list))")
        }
    }

    /// 保留策略（设计文档需求 9）：每源保留最近 keepCount 条且不早于 keepDays 天；星标豁免。
    /// 参数是全局默认；feed.keepCount / feed.keepDays 非空时按源覆盖。keepDays = 0 表示不按时间清理。
    func purge(keepCount: Int, keepDays: Int) async throws {
        try await pool.write { db in
            let overflow = try Int64.fetchAll(db, sql: """
                SELECT id FROM (
                    SELECT article.id AS id, COALESCE(feed.keepCount, ?) AS keep,
                        ROW_NUMBER() OVER (
                            PARTITION BY article.feedId
                            ORDER BY article.publishedAt IS NULL, article.publishedAt DESC, article.id DESC
                        ) AS rn
                    FROM article JOIN feed ON feed.id = article.feedId
                    WHERE article.isStarred = 0
                ) WHERE rn > keep
                """, arguments: [keepCount])
            // julianday 显式按时间比较，不依赖日期文本的字典序
            let expired = try Int64.fetchAll(db, sql: """
                SELECT article.id FROM article JOIN feed ON feed.id = article.feedId
                WHERE article.isStarred = 0 AND article.publishedAt IS NOT NULL
                  AND COALESCE(feed.keepDays, ?) > 0
                  AND julianday(article.publishedAt) < julianday('now') - COALESCE(feed.keepDays, ?)
                """, arguments: [keepDays, keepDays])
            let doomed = Set(overflow).union(expired)
            guard !doomed.isEmpty else { return }
            let list = doomed.map(String.init).joined(separator: ",")
            try db.execute(sql: "DELETE FROM article WHERE id IN (\(list))")
            // contentless_delete（v10）之后索引行可以真删，搜索不再靠 JOIN 滤残留
            try db.execute(sql: "DELETE FROM articleSearch WHERE rowid IN (\(list))")
        }
    }
}

// MARK: - 读操作

extension AppDatabase {
    func feedsForRefresh() async throws -> [Feed] {
        try await pool.read { db in try Feed.fetchAll(db) }
    }

    func feed(id: Int64) async throws -> Feed? {
        try await pool.read { db in try Feed.fetchOne(db, key: id) }
    }

    /// 文章不存在（已被 purge）返回 0，等价于"没有进度"。
    func readingProgress(articleId: Int64) async throws -> Double {
        try await pool.read { db in
            try Double.fetchOne(
                db, sql: "SELECT readingProgress FROM article WHERE id = ?", arguments: [articleId]) ?? 0
        }
    }

    /// 阅读器一次性取到需要的全部数据（单行 + 正文，不进列表查询）。
    func readerData(articleId: Int64) async throws -> ReaderData? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT article.*, feed.title AS feedTitle,
                       feed.fullTextMode, feed.fullTextSelector
                FROM article JOIN feed ON feed.id = article.feedId
                WHERE article.id = ?
                """, arguments: [articleId]) else { return nil }
            let contentRow = try Row.fetchOne(
                db, sql: "SELECT html, extractedHTML FROM articleContent WHERE articleId = ?",
                arguments: [articleId])
            let mode = FullTextMode(rawValue: row["fullTextMode"]) ?? .auto
            return ReaderData(
                article: try Article(row: row),
                feedTitle: row["feedTitle"],
                html: contentRow?["html"] ?? "",
                extractedHTML: mode == .never ? nil : contentRow?["extractedHTML"],
                fullTextMode: mode,
                fullTextSelector: row["fullTextSelector"])
        }
    }
}

extension AppDatabase {
    /// HN 线程预取候选：有 HN 评论页链接、尚无线程缓存的最新文章。
    /// 只做 HN（Algolia 不限流）；V2EX 有 120 次/小时限流，保持点开才拉。
    func hnArticlesNeedingThreadPrefetch(limit: Int) async throws -> [Article] {
        try await pool.read { db in
            try Article.fetchAll(db, sql: """
                SELECT article.* FROM article
                LEFT JOIN forumThread ON forumThread.articleId = article.id
                WHERE article.commentsURL LIKE '%ycombinator.com%' AND forumThread.articleId IS NULL
                ORDER BY article.publishedAt IS NULL, article.publishedAt DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }
}

struct ReaderData {
    var article: Article
    var feedTitle: String
    /// 原文（feed 自带内容），永远保留——「恢复原文」不查库直接用它重渲染
    var html: String
    /// 全文抓取结果；非 nil 时模板优先渲染它
    var extractedHTML: String?
    var fullTextMode: FullTextMode
    var fullTextSelector: String?
    var commentsURL: String? { article.commentsURL }
}

// MARK: - 译文缓存

extension AppDatabase {
    func fetchTranslations(articleId: Int64, lang: String, engine: String) async throws -> [Int: (hash: String, text: String)] {
        try await pool.read { db in
            var result: [Int: (hash: String, text: String)] = [:]
            let rows = try Row.fetchAll(
                db, sql: """
                SELECT blockIndex, sourceHash, text FROM translation
                WHERE articleId = ? AND targetLang = ? AND engine = ?
                """,
                arguments: [articleId, lang, engine])
            for row in rows {
                let i: Int = row["blockIndex"]
                let hash: String = row["sourceHash"]
                let text: String = row["text"]
                result[i] = (hash: hash, text: text)
            }
            return result
        }
    }

    /// 主键 (articleId, blockIndex, targetLang, engine)，INSERT OR REPLACE 让重译覆盖旧译文。
    func storeTranslations(articleId: Int64, lang: String, engine: String, rows: [(i: Int, hash: String, text: String)]) async throws {
        try await pool.write { db in
            for r in rows {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO translation (articleId, blockIndex, targetLang, engine, sourceHash, text)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [articleId, r.i, lang, engine, r.hash, r.text])
            }
        }
    }
}

// MARK: - 全文抓取缓存

extension AppDatabase {
    /// 列为 NULL 或行不存在（文章已被 purge）都返回 nil = 未抓取过。
    func extractedHTML(articleId: Int64) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT extractedHTML FROM articleContent WHERE articleId = ?",
                arguments: [articleId])
        }
    }

    func fullTextState(articleId: Int64) async throws -> FullTextState? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT feed.fullTextMode, feed.fullTextSelector,
                       articleContent.extractedHTML IS NOT NULL AS hasFullText
                FROM article JOIN feed ON feed.id = article.feedId
                JOIN articleContent ON articleContent.articleId = article.id
                WHERE article.id = ?
                """, arguments: [articleId]) else { return nil }
            return FullTextState(
                mode: FullTextMode(rawValue: row["fullTextMode"]) ?? .auto,
                selector: row["fullTextSelector"], hasFullText: row["hasFullText"])
        }
    }

    /// articleContent 行随文章入库时创建（applyFetchSuccess），UPDATE 必然命中；
    /// 文章恰好被 purge 时静默无操作，缓存本就无处可挂。
    /// 抓到的全文同时替换 FTS 的 body：摘要源在抓全文前后可搜的范围不一样，索引要跟上。
    func storeExtractedHTML(articleId: Int64, _ html: String) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE articleContent SET extractedHTML = ? WHERE articleId = ?",
                arguments: [html, articleId])
            guard let row = try Row.fetchOne(
                db, sql: "SELECT title, summary FROM article WHERE id = ?", arguments: [articleId])
            else { return }
            try db.execute(sql: "DELETE FROM articleSearch WHERE rowid = ?", arguments: [articleId])
            try db.execute(
                sql: "INSERT INTO articleSearch(rowid, title, summary, body) VALUES (?, ?, ?, ?)",
                arguments: [articleId, row["title"], row["summary"], HTMLTools.plainText(html)])
        }
    }
}

struct FullTextState {
    var mode: FullTextMode
    var selector: String?
    var hasFullText: Bool
}
