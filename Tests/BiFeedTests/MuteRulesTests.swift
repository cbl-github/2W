import XCTest
@testable import BiFeed

final class MuteRulesTests: XCTestCase {
    func testRegexScopeExceptionAndActionPrecedence() {
        let item = ParsedItem(
            guid: "1", url: "https://example.com/1", title: "Daily briefing",
            author: "Alice", publishedAt: nil, contentHTML: "<p>Trump and markets</p>",
            summaryText: "Trump and markets", categories: ["Politics"])
        let hide = rule(pattern: #"trump(s)?"#, matchType: .regex, field: .body,
                        scopeFolderId: 7, action: .hide)
        let collapse = rule(id: 2, pattern: "Politics", field: .category,
                            scopeFolderId: 7, action: .collapse)

        XCTAssertEqual(MuteRules.evaluate(
            [item], feedId: 1, folderId: 7, rules: [collapse, hide]).first?.action, .hide)
        XCTAssertNil(MuteRules.evaluate(
            [item], feedId: 1, folderId: 8, rules: [collapse, hide]).first?.action)

        var allowed = hide
        allowed.exceptions = "Alice"
        XCTAssertEqual(MuteRules.evaluate(
            [item], feedId: 1, folderId: 7, rules: [allowed, collapse]).first?.action, .collapse)
    }

    func testNewRuleReplaysHistoryAndAllowAddsException() async throws {
        let db = try makeTempDB()
        let folder = try await db.addFolder(name: "News")
        let feed = try await db.addFeed(
            url: "https://example.com/rss", title: "Example", siteURL: nil, folderId: folder.id)
        let item = ParsedItem(
            guid: "1", url: "https://example.com/1", title: "Noise story", author: nil,
            publishedAt: Date(), contentHTML: "<p>Body</p>", summaryText: "Body")
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item, action: nil)])

        let count = try await MuteRules.add(db, draft: MuteRuleDraft(
            pattern: "Noise", matchType: .contains, field: .title,
            scopeFeedId: nil, scopeFolderId: folder.id, exceptions: "", action: .hide))
        let articleId = try await db.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM article")!
        }
        XCTAssertEqual(count, 1)
        let initiallyMuted = try await db.pool.read { db in
            try Bool.fetchOne(db, sql: "SELECT isMuted FROM article WHERE id = ?", arguments: [articleId])
        }
        XCTAssertEqual(initiallyMuted, true)

        let allowedRuleCount = try await MuteRules.allow(db, articleId: articleId)
        XCTAssertEqual(allowedRuleCount, 1)
        let (muted, exceptions) = try await db.pool.read { db in
            (try Bool.fetchOne(db, sql: "SELECT isMuted FROM article WHERE id = ?", arguments: [articleId]),
             try String.fetchOne(db, sql: "SELECT exceptions FROM muteRule"))
        }
        XCTAssertEqual(muted, false)
        XCTAssertEqual(exceptions, "Noise story")
    }

    private func rule(id: Int64 = 1, pattern: String,
                      matchType: MuteMatchType = .contains,
                      field: MuteRuleField, scopeFolderId: Int64?,
                      action: MuteRuleAction) -> MuteRule {
        MuteRule(id: id, pattern: pattern, scopeFeedId: nil, titleOnly: field == .title,
                 createdAt: Date(), matchType: matchType, field: field,
                 scopeFolderId: scopeFolderId, exceptions: "", action: action)
    }
}
