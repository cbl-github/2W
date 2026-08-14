import Foundation
import GRDB

enum FullTextMode: String, Codable, CaseIterable, Sendable {
    case auto
    case always
    case never

    var label: String {
        switch self {
        case .auto: "自动"
        case .always: "总是抓取"
        case .never: "从不抓取"
        }
    }
}

struct Folder: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "folder"
    var id: Int64?
    var name: String
    /// 关闭后本组所有订阅都不计入未读徽标（分组行与总数都不显示）。
    var showsUnreadBadge: Bool = true

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct Feed: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "feed"
    var id: Int64?
    var url: String
    var title: String
    var siteURL: String?
    var folderId: Int64?
    var addedAt: Date
    var lastFetchedAt: Date?
    var etag: String?
    var lastModified: String?
    var fetchError: String?
    /// 连续抓取失败次数：>= 3 时自动轮询跳过此源（死源检测）；手动刷新不受限，成功清零。
    var failCount: Int = 0
    var lastSuccessAt: Date?
    /// 上次成功响应体的 SHA256 全 hex：相同即内容未变，跳过解析。
    var bodyHash: String?
    /// 最近一次 HTTP 状态；传输层失败为 nil。
    var lastHTTPStatus: Int?
    /// 暂时错误的下次自动尝试时间；手动刷新不受限制。
    var nextFetchAt: Date?
    var fullTextMode: FullTextMode = .auto
    var fullTextSelector: String?
    /// 关闭后此源不计入任何未读徽标（高频源不淹没总数）；不影响列表与"全部标为已读"。
    var showsUnreadBadge: Bool = true
    /// 保留覆盖：nil = 跟随设置里的全局值。
    var keepCount: Int?
    var keepDays: Int?
    /// 抓取覆盖：nil = 用默认 UA。
    var userAgent: String?
    /// HTTP Basic 用户名；nil = 不带认证。密码不落库，见 KeychainStore.basicAccount。
    var basicUser: String?
    /// 自动刷新间隔覆盖（分钟）：nil = 跟随全局。
    var refreshMinutes: Int?
    /// 只对 YouTube 源有意义：开着时 Shorts 条目直接不入库（需求 18）。
    var filterShorts: Bool = false

    /// 已因硬错误停止自动重试。判定必须与调度器同一个函数，否则 YouTube 偶发 404 的
    /// 容忍期（需求 18）内，界面会显示"已停止"而后台其实还在退避重试。
    var isHardErrored: Bool {
        guard let status = lastHTTPStatus else { return false }
        return FetchScheduler.failureKind(
            host: URL(string: url)?.host(), code: status, failCount: failCount) == .hard
    }

    /// 只有 http(s) 的源才去抓、才导出 OPML。手动保存的容器源是 bifeed://（不该发请求，
    /// 别的阅读器也订不了），任何脏数据地址同样在这里被挡住。
    var isFetchable: Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct Article: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "article"
    var id: Int64?
    var feedId: Int64
    var guid: String
    var url: String?
    var title: String
    var author: String?
    var publishedAt: Date?
    var summary: String
    var isRead: Bool = false
    var isStarred: Bool = false
    var commentsURL: String?

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 正文单独一张表：列表查询永不触碰大字段（设计文档 §4 机制 1）。
struct ArticleContent: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "articleContent"
    var articleId: Int64
    var html: String
}

/// 译文缓存，按 (文章, 段落序号, 目标语言, 引擎) 唯一。
/// sourceHash 是段落原文的 SHA256 全 hex：原文变了缓存即失效。
struct CachedTranslation: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "translation"
    var articleId: Int64
    var blockIndex: Int
    var targetLang: String
    var engine: String
    var sourceHash: String
    var text: String
}
