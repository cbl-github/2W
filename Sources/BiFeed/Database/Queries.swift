import Foundation
import GRDB

enum SidebarSelection: Hashable {
    case all
    case today      // 今天发布（本地时区自然日）
    case allUnread  // 全部未读
    case starred
    case muted
    case folder(Int64)
    case feed(Int64)
    /// 保存的搜索。列表视图在查询前用 SavedSearches.resolve 换成上面的基础范围 + 搜索词，
    /// 所以它不会带着这个值进 fetchAll。
    case savedSearch(Int64)
}

/// 文章列表行：只含元数据列，永不 JOIN 出正文（设计文档 §4 机制 1）。
struct ArticleListItem: Codable, Identifiable, Hashable, FetchableRecord {
    var id: Int64
    var feedId: Int64
    var title: String
    var url: String?
    var publishedAt: Date?
    var summary: String
    var isRead: Bool
    var isStarred: Bool
    var isMuted: Bool
    var isCollapsed: Bool
    var duplicateCount: Int
    var feedTitle: String

    /// search 非空白时优先走 articleSearch（FTS5）MATCH，按 bm25 相关度排序；
    /// FTS 对引号、裸运算符等用户输入抛语法错误时回落 title/summary/feed.title 三列 LIKE
    /// （SQLite LIKE 对 ASCII 不区分大小写；% _ 经 ESCAPE 转成字面量）——这是规格内输入。
    /// filter 是读态三态过滤（"all" | "unread" | "starred"，SettingsKey.readFilter 的取值），
    /// 与 scope 条件 AND 叠加；默认值保持既有调用点（含测试）源兼容。
    /// sticky = 粘性未读集合：unread 过滤下这些 id 即使已读也保留在结果里（本轮浏览不消失）。
    /// since 非空 = 只要这个时间之后发布的文章（搜索的时间范围限定；无日期的文章被排除）。
    /// 静音文章只在 .muted 范围出现。
    static func fetchAll(_ db: Database, scope: SidebarSelection, search: String?,
                         filter: String = "all", sticky: Set<Int64> = [],
                         since: Date? = nil) throws -> [ArticleListItem] {
        let columns = """
            SELECT article.id, article.feedId, article.title, article.url,
                   article.publishedAt, article.summary, article.isRead, article.isStarred,
                   article.isMuted, article.isCollapsed,
                   CASE WHEN article.normalizedURL IS NULL THEN 0 ELSE
                       (SELECT COUNT(*) FROM article duplicate
                        WHERE duplicate.normalizedURL = article.normalizedURL) - 1
                   END AS duplicateCount,
                   feed.title AS feedTitle
            """
        let order = " ORDER BY article.publishedAt IS NULL, article.publishedAt DESC, article.id DESC"
        var conditions: [String] = []
        var arguments: [(any DatabaseValueConvertible)?] = []
        switch scope {
        case .all:
            break
        case .today:
            // publishedAt 由 GRDB 以 UTC 文本落库，date(…,'localtime') 转回本地自然日；NULL 自动排除
            conditions.append("date(article.publishedAt, 'localtime') = date('now', 'localtime')")
        case .allUnread:
            conditions.append(sticky.isEmpty
                ? "article.isRead = 0"
                : "(article.isRead = 0 OR article.id IN (\(sticky.sorted().map(String.init).joined(separator: ","))))")
        case .starred:
            conditions.append("article.isStarred = 1")
        case .muted:
            conditions.append("article.isMuted = 1")
        case .folder(let fid):
            conditions.append("feed.folderId = ?")
            arguments.append(fid)
        case .feed(let fid):
            conditions.append("article.feedId = ?")
            arguments.append(fid)
        case .savedSearch:
            break // 视图已解析成基础范围；真走到这里等价于「全部文章」
        }
        if scope != .muted { conditions.append("article.isMuted = 0") }
        if let since {
            conditions.append("article.publishedAt IS NOT NULL AND article.publishedAt >= ?")
            arguments.append(since)
        }
        switch filter {
        case "unread": conditions.append(sticky.isEmpty
                ? "article.isRead = 0"
                : "(article.isRead = 0 OR article.id IN (\(sticky.sorted().map(String.init).joined(separator: ","))))") // .allUnread 下重复无害（AND 幂等）
        case "starred": conditions.append("article.isStarred = 1")
        default: break
        }
        let term = (search ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty, let eligibility = dedupEligibility(scope: scope, filter: filter, sticky: sticky) {
            conditions.append("""
                (article.normalizedURL IS NULL OR article.id = (
                    SELECT MIN(duplicate.id) FROM article duplicate
                    WHERE duplicate.normalizedURL = article.normalizedURL AND \(eligibility)
                ))
                """)
        }
        if !term.isEmpty {
            // FTS 路径：articleSearch 只索引 title/summary（不含 feed.title），rowid=article.id JOIN 回列表列。
            // bm25 返回负值、越相关越小，升序即相关度降序。
            let ftsSQL = columns + """

                FROM articleSearch
                JOIN article ON article.id = articleSearch.rowid
                JOIN feed ON feed.id = article.feedId
                WHERE articleSearch MATCH ? AND \(conditions.joined(separator: " AND "))
                ORDER BY bm25(articleSearch)
                """
            // unicode61 不切分 CJK（整段连续汉字是一个 token），中文词用 FTS 基本搜不到；
            // 含 CJK 的词直接走 LIKE。ASCII 词按空格拆 token、双引号包裹 + 前缀星号，
            // 与 LIKE 的子串语义对齐（"oth" 能命中 "other"）。
            let hasCJK = term.unicodeScalars.contains { $0.value >= 0x2E80 }
            let ftsQuery = term.split(separator: " ").map {
                "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*"
            }.joined(separator: " ")
            if !hasCJK {
                do {
                    var ftsArguments: [(any DatabaseValueConvertible)?] = [ftsQuery]
                    ftsArguments.append(contentsOf: arguments)
                    return try fetchAll(db, sql: ftsSQL, arguments: StatementArguments(ftsArguments))
                } catch is DatabaseError {
                    // MATCH 语法错误（未配对引号、裸 AND/OR 等）——落到下方 LIKE 路径
                }
            }
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escaped)%"
            // 正文用子查询而不是 JOIN：大字段不进结果集，列表查询「永不 JOIN 正文列」的不变量保住。
            // ponytail: 中文走这条路时正文是全表扫描；等库大到搜索明显卡顿，再换 CJK 分词的 FTS。
            conditions.append("""
                (article.title LIKE ? ESCAPE '\\' OR article.summary LIKE ? ESCAPE '\\' \
                OR feed.title LIKE ? ESCAPE '\\' OR article.id IN (
                    SELECT articleId FROM articleContent
                    WHERE html LIKE ? ESCAPE '\\' OR extractedHTML LIKE ? ESCAPE '\\'
                ))
                """)
            arguments.append(contentsOf: [pattern, pattern, pattern, pattern, pattern])
        }
        let base = columns + "\n    FROM article JOIN feed ON feed.id = article.feedId"
        let whereClause = " WHERE " + conditions.joined(separator: " AND ")
        return try fetchAll(db, sql: base + whereClause + order, arguments: StatementArguments(arguments))
    }

    /// 聚合范围折叠精确重复；单源/分组/搜索保留各自条目，避免跨范围的 canonical 把结果吃掉。
    private static func dedupEligibility(scope: SidebarSelection, filter: String,
                                         sticky: Set<Int64>) -> String? {
        var parts = ["duplicate.isMuted = 0"]
        let unread = sticky.isEmpty
            ? "duplicate.isRead = 0"
            : "(duplicate.isRead = 0 OR duplicate.id IN (\(sticky.sorted().map(String.init).joined(separator: ","))))"
        switch scope {
        case .all: break
        case .today:
            parts.append("date(duplicate.publishedAt, 'localtime') = date('now', 'localtime')")
        case .allUnread:
            parts.append(unread)
        case .starred:
            parts.append("duplicate.isStarred = 1")
        case .muted, .folder, .feed, .savedSearch:
            return nil
        }
        if filter == "unread" { parts.append(unread) }
        if filter == "starred" { parts.append("duplicate.isStarred = 1") }
        return parts.joined(separator: " AND ")
    }
}

/// 侧栏一次观察拿全：目录、订阅、未读计数、星标数、今日未读数。几条轻查询，任一变动整体刷新。
struct SidebarData {
    var folders: [Folder] = []
    var feeds: [Feed] = []
    var savedSearches: [SavedSearch] = []
    var unreadByFeed: [Int64: Int] = [:]
    var latestPublishedByFeed: [Int64: Date] = [:]
    var starredCount: Int = 0
    var mutedCount: Int = 0
    var totalUnreadCount: Int = 0
    var todayCount: Int = 0  // 今天发布且未读（徽章用未读口径，比全量计数更实用）

    /// 关掉未读徽标的源不参与任何未读计数：源自己关掉，或它所在分组整组关掉。
    /// 只影响计数与徽标，不影响列表内容和「全部标为已读」。
    private static let badgedFeeds = """
        article.feedId IN (
            SELECT feed.id FROM feed LEFT JOIN folder ON folder.id = feed.folderId
            WHERE feed.showsUnreadBadge = 1 AND COALESCE(folder.showsUnreadBadge, 1) = 1
        )
        """

    static func fetch(_ db: Database) throws -> SidebarData {
        var d = SidebarData()
        d.folders = try Folder.order(Column("name")).fetchAll(db)
        d.feeds = try Feed.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        d.savedSearches = try SavedSearches.fetchAll(db)
        // 计数一律排除静音文章（isMuted=1 不计未读，与列表口径一致）
        for row in try Row.fetchAll(db, sql: "SELECT feedId, COUNT(*) AS c FROM article WHERE isRead = 0 AND isMuted = 0 GROUP BY feedId") {
            d.unreadByFeed[row["feedId"]] = row["c"]
        }
        // 静默停更判定的数据：一条 GROUP BY 拿全部源的最新发布时间，不逐源查
        for row in try Row.fetchAll(db, sql: """
            SELECT feedId, MAX(publishedAt) AS latest FROM article
            WHERE publishedAt IS NOT NULL GROUP BY feedId
            """) {
            d.latestPublishedByFeed[row["feedId"]] = row["latest"]
        }
        d.starredCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM article
            WHERE isStarred = 1 AND isMuted = 0 AND (normalizedURL IS NULL OR id = (
                SELECT MIN(duplicate.id) FROM article duplicate
                WHERE duplicate.normalizedURL = article.normalizedURL
                  AND duplicate.isStarred = 1 AND duplicate.isMuted = 0
            ))
            """) ?? 0
        d.mutedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article WHERE isMuted = 1") ?? 0
        d.totalUnreadCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM article
            WHERE isRead = 0 AND isMuted = 0 AND \(badgedFeeds)
              AND (normalizedURL IS NULL OR id = (
                SELECT MIN(duplicate.id) FROM article duplicate
                WHERE duplicate.normalizedURL = article.normalizedURL
                  AND duplicate.isRead = 0 AND duplicate.isMuted = 0
            ))
            """) ?? 0
        d.todayCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM article
            WHERE isRead = 0 AND isMuted = 0 AND \(badgedFeeds)
              AND date(publishedAt, 'localtime') = date('now', 'localtime')
              AND (normalizedURL IS NULL OR id = (
                  SELECT MIN(duplicate.id) FROM article duplicate
                  WHERE duplicate.normalizedURL = article.normalizedURL
                    AND duplicate.isRead = 0 AND duplicate.isMuted = 0
                    AND date(duplicate.publishedAt, 'localtime') = date('now', 'localtime')
              ))
            """) ?? 0
        return d
    }

    var totalUnread: Int { totalUnreadCount }

    /// 徽标口径的未读数：源或其分组关掉徽标就返回 0（= 不显示）。
    func unreadBadge(for feed: Feed) -> Int {
        guard feed.showsUnreadBadge, folderShowsBadge(feed.folderId) else { return 0 }
        return unreadByFeed[feed.id ?? -1] ?? 0
    }

    func unreadBadge(inFolder folderId: Int64) -> Int {
        guard folderShowsBadge(folderId) else { return 0 }
        return feeds(inFolder: folderId)
            .filter(\.showsUnreadBadge)
            .reduce(0) { $0 + (unreadByFeed[$1.id ?? -1] ?? 0) }
    }

    private func folderShowsBadge(_ folderId: Int64?) -> Bool {
        guard let folderId else { return true }
        return folders.first { $0.id == folderId }?.showsUnreadBadge ?? true
    }

    var feedsWithoutFolder: [Feed] { feeds.filter { $0.folderId == nil } }
    func feeds(inFolder folderId: Int64) -> [Feed] { feeds.filter { $0.folderId == folderId } }

    func staleDays(for feed: Feed) -> Int? {
        Self.staleDays(latestPublishedAt: latestPublishedByFeed[feed.id ?? -1])
    }

    /// 静默停更（需求 7 第三级）：能抓通但久无新文章，只标注不标红。
    /// 返回距今天数，未超阈值或这个源一篇文章都没有都返回 nil。
    static func staleDays(latestPublishedAt: Date?, now: Date = Date(), threshold: Int = 30) -> Int? {
        guard let latestPublishedAt else { return nil }
        let days = Int(now.timeIntervalSince(latestPublishedAt) / 86400)
        return days > threshold ? days : nil
    }
}

/// 源健康面板一行（需求 20）。统计全部从现有列算，不加迁移。
struct FeedHealthRow: Identifiable, Hashable {
    var feed: Feed
    /// 近 30 天到达的文章数。静音条目自成一列，不进这两个计数——
    /// 「收到多少」和「我读了多少」必须是同一批文章，否则比值没有意义。
    var recentCount: Int = 0
    var recentReadCount: Int = 0
    var mutedCount: Int = 0
    var lastPublishedAt: Date?

    var id: Int64 { feed.id ?? -1 }
    var title: String { feed.title }
    /// Table 的排序键不能是 Optional（标准库没给 Optional 一致性）。
    var lastPublishedSort: Date { lastPublishedAt ?? .distantPast }

    /// 与侧栏状态图标同一套判定（SidebarView.feedRow）。
    var status: String {
        if feed.isHardErrored, let code = feed.lastHTTPStatus { return "硬错误 HTTP \(code)" }
        if let next = feed.nextFetchAt, next > Date() { return "暂缓中" }
        if let error = feed.fetchError { return error }
        return "正常"
    }

    /// 一条 GROUP BY 拿齐三个计数与最后发布时间，再与订阅表合并；没有文章的源也出现。
    static func fetchAll(_ db: Database,
                         since: Date = Date(timeIntervalSinceNow: -30 * 86400)) throws -> [FeedHealthRow] {
        var stats: [Int64: Row] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT feedId,
                SUM(CASE WHEN isMuted = 0 AND publishedAt >= ? THEN 1 ELSE 0 END) AS recent,
                SUM(CASE WHEN isMuted = 0 AND isRead = 1 AND publishedAt >= ? THEN 1 ELSE 0 END) AS recentRead,
                SUM(isMuted) AS muted,
                MAX(publishedAt) AS lastPublishedAt
            FROM article GROUP BY feedId
            """, arguments: [since, since]) {
            stats[row["feedId"]] = row
        }
        let feeds = try Feed.order(Column("title").collating(.localizedCaseInsensitiveCompare)).fetchAll(db)
        return feeds.map { feed in
            guard let row = stats[feed.id ?? -1] else { return FeedHealthRow(feed: feed) }
            return FeedHealthRow(
                feed: feed, recentCount: row["recent"], recentReadCount: row["recentRead"],
                mutedCount: row["muted"], lastPublishedAt: row["lastPublishedAt"])
        }
    }
}
