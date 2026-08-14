import Foundation
import GRDB

enum MuteMatchType: String, Codable, CaseIterable {
    case contains
    case regex

    var label: String { self == .contains ? "包含" : "正则" }
}

enum MuteRuleField: String, Codable, CaseIterable {
    case title, body, author, url, category, all

    var label: String {
        switch self {
        case .title: "标题"
        case .body: "正文"
        case .author: "作者"
        case .url: "URL"
        case .category: "分类标签"
        case .all: "全部字段"
        }
    }
}

enum MuteRuleAction: String, Codable, CaseIterable {
    case hide
    case markRead
    case collapse

    var label: String {
        switch self {
        case .hide: "隐藏"
        case .markRead: "标记已读"
        case .collapse: "折叠"
        }
    }
}

struct MuteRuleDraft {
    var pattern: String
    var matchType: MuteMatchType
    var field: MuteRuleField
    var scopeFeedId: Int64?
    var scopeFolderId: Int64?
    var exceptions: String
    var action: MuteRuleAction
}

/// 单条件静音规则。作用域三选一：全局（两个 scope 都为空）、分组或订阅。
struct MuteRule: Codable, Identifiable, Hashable, FetchableRecord {
    var id: Int64
    var pattern: String
    var scopeFeedId: Int64?
    /// v5 兼容列；v7 后只读 field。
    var titleOnly: Bool
    var createdAt: Date
    var matchType: MuteMatchType
    var field: MuteRuleField
    var scopeFolderId: Int64?
    /// 一行一个，不区分大小写；任一字段命中即放行。
    var exceptions: String
    var action: MuteRuleAction
}

struct MuteEvaluation {
    var item: ParsedItem
    var action: MuteRuleAction?
}

enum MuteRules {
    static func all(_ db: AppDatabase) async throws -> [MuteRule] {
        try await db.pool.read { try fetchAll($0) }
    }

    static func fetchAll(_ db: Database) throws -> [MuteRule] {
        try MuteRule.fetchAll(db, sql: "SELECT * FROM muteRule ORDER BY id")
    }

    /// 新规则立即回扫历史，返回该规则本次命中的文章数。
    static func add(_ db: AppDatabase, draft: MuteRuleDraft) async throws -> Int {
        if draft.matchType == .regex {
            _ = try NSRegularExpression(pattern: draft.pattern, options: .caseInsensitive)
        }
        return try await db.pool.write { db in
            try db.execute(sql: """
                INSERT INTO muteRule
                    (pattern, scopeFeedId, titleOnly, createdAt, matchType, field,
                     scopeFolderId, exceptions, action)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    draft.pattern, draft.scopeFeedId, draft.field == .title, Date(),
                    draft.matchType.rawValue, draft.field.rawValue, draft.scopeFolderId,
                    draft.exceptions, draft.action.rawValue,
                ])
            let rule = try MuteRule.fetchOne(
                db, sql: "SELECT * FROM muteRule WHERE id = ?", arguments: [db.lastInsertedRowID])!
            return try replay(db, addedRule: rule)
        }
    }

    /// 删除后重新计算隐藏/折叠；“标记已读”不反向改成未读，避免覆盖用户自己的阅读状态。
    static func delete(_ db: AppDatabase, id: Int64) async throws {
        try await db.pool.write { db in
            try db.execute(sql: "DELETE FROM muteRule WHERE id = ?", arguments: [id])
            _ = try replay(db)
        }
    }

    /// 把文章完整标题加入所有命中规则的例外词，并立即回扫。
    @discardableResult
    static func allow(_ db: AppDatabase, articleId: Int64) async throws -> Int {
        try await db.pool.write { db in
            guard let article = try storedArticle(db, id: articleId) else { return 0 }
            let rules = try fetchAll(db)
            let prepared = prepare(rules.filter { scopeMatches($0, feedId: article.feedId, folderId: article.folderId) })
            let candidate = article.candidate
            let matching = prepared.filter { matches($0, candidate: candidate) }
            let exception = article.title.replacing(/\s+/, with: " ")
            for preparedRule in matching {
                let old = preparedRule.rule.exceptions.trimmingCharacters(in: .whitespacesAndNewlines)
                let updated = old.isEmpty ? exception : "\(old)\n\(exception)"
                try db.execute(sql: "UPDATE muteRule SET exceptions = ? WHERE id = ?",
                               arguments: [updated, preparedRule.rule.id])
            }
            _ = try replay(db)
            return matching.count
        }
    }

    /// 抓取入库前与历史回扫共用同一套字段、作用域、例外和动作判定。
    static func evaluate(_ items: [ParsedItem], feedId: Int64, folderId: Int64?,
                         rules: [MuteRule]) -> [MuteEvaluation] {
        let prepared = prepare(rules.filter { scopeMatches($0, feedId: feedId, folderId: folderId) })
        return items.map { item in
            MuteEvaluation(item: item, action: action(
                for: Candidate(title: item.title, summary: item.summaryText,
                               contentHTML: item.contentHTML, author: item.author ?? "",
                               url: item.url ?? "", categories: item.categories),
                rules: prepared))
        }
    }
}

private extension MuteRules {
    struct Candidate {
        var title: String
        var summary: String
        var contentHTML: String
        var author: String
        var url: String
        var categories: [String]

        var allTexts: [String] { [title, summary, contentHTML, author, url] + categories }

        func texts(for field: MuteRuleField) -> [String] {
            switch field {
            case .title: [title]
            case .body: [summary, contentHTML]
            case .author: [author]
            case .url: [url]
            case .category: categories
            case .all: allTexts
            }
        }
    }

    struct StoredArticle: Decodable, FetchableRecord {
        var id: Int64
        var feedId: Int64
        var folderId: Int64?
        var title: String
        var url: String?
        var author: String?
        var summary: String
        var contentHTML: String
        var categories: String

        var candidate: Candidate {
            Candidate(title: title, summary: summary, contentHTML: contentHTML,
                      author: author ?? "", url: url ?? "",
                      categories: categories.split(separator: "\n").map(String.init))
        }
    }

    struct PreparedRule {
        var rule: MuteRule
        var regex: NSRegularExpression?
    }

    static func prepare(_ rules: [MuteRule]) -> [PreparedRule] {
        rules.map { rule in
            PreparedRule(rule: rule, regex: rule.matchType == .regex
                ? try? NSRegularExpression(pattern: rule.pattern, options: .caseInsensitive)
                : nil)
        }
    }

    static func scopeMatches(_ rule: MuteRule, feedId: Int64, folderId: Int64?) -> Bool {
        if let id = rule.scopeFeedId { return id == feedId }
        if let id = rule.scopeFolderId { return id == folderId }
        return true
    }

    static func matches(_ prepared: PreparedRule, candidate: Candidate) -> Bool {
        let rule = prepared.rule
        let exceptionTerms = rule.exceptions.split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if exceptionTerms.contains(where: { term in
            candidate.allTexts.contains { $0.range(of: term, options: .caseInsensitive) != nil }
        }) { return false }

        return candidate.texts(for: rule.field).contains { text in
            switch rule.matchType {
            case .contains:
                return text.range(of: rule.pattern, options: .caseInsensitive) != nil
            case .regex:
                guard let regex = prepared.regex else { return false }
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
        }
    }

    /// 多规则同时命中时使用最强动作，避免规则顺序改变结果。
    static func action(for candidate: Candidate, rules: [PreparedRule]) -> MuteRuleAction? {
        let actions = rules.lazy.filter { matches($0, candidate: candidate) }.map(\.rule.action)
        if actions.contains(.hide) { return .hide }
        if actions.contains(.markRead) { return .markRead }
        if actions.contains(.collapse) { return .collapse }
        return nil
    }

    static func storedArticle(_ db: Database, id: Int64) throws -> StoredArticle? {
        try StoredArticle.fetchOne(db, sql: storedArticleSQL + " WHERE article.id = ?", arguments: [id])
    }

    static func storedArticles(_ db: Database) throws -> [StoredArticle] {
        try StoredArticle.fetchAll(db, sql: storedArticleSQL)
    }

    static var storedArticleSQL: String { """
        SELECT article.id, article.feedId, feed.folderId, article.title, article.url,
               article.author, article.summary, COALESCE(articleContent.html, '') AS contentHTML,
               article.categories
        FROM article
        JOIN feed ON feed.id = article.feedId
        LEFT JOIN articleContent ON articleContent.articleId = article.id
        """ }

    static func replay(_ db: Database, addedRule: MuteRule? = nil) throws -> Int {
        // ponytail: 全量回扫是 O(文章数)；只有大库保存规则明显变慢时才改为索引化增量回扫。
        try db.execute(sql: "UPDATE article SET isMuted = 0, isCollapsed = 0")
        let rules = try fetchAll(db)
        let prepared = prepare(rules)
        let preparedAdded = addedRule.flatMap { prepare([$0]).first }
        var addedMatches = 0
        for article in try storedArticles(db) {
            let candidate = article.candidate
            let applicable = prepared.filter {
                scopeMatches($0.rule, feedId: article.feedId, folderId: article.folderId)
            }
            let result = action(for: candidate, rules: applicable)
            if let preparedAdded,
               scopeMatches(preparedAdded.rule, feedId: article.feedId, folderId: article.folderId),
               matches(preparedAdded, candidate: candidate) {
                addedMatches += 1
            }
            try db.execute(sql: """
                UPDATE article
                SET isMuted = ?, isCollapsed = ?,
                    isRead = CASE WHEN ? THEN 1 ELSE isRead END
                WHERE id = ?
                """, arguments: [
                    result == .hide, result == .collapse, result == .markRead, article.id,
                ])
        }
        return addedMatches
    }
}
