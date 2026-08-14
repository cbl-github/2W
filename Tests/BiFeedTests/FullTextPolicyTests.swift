import Foundation
import XCTest
@testable import BiFeed

final class FullTextPolicyTests: XCTestCase {
    func testAutomaticModeOnlyDetectsLikelyTruncation() {
        XCTAssertTrue(FullTextPolicy.looksTruncated(
            "<p>\(String(repeating: "摘要内容", count: 30))……继续阅读</p>"))
        XCTAssertTrue(FullTextPolicy.looksTruncated(
            "<p>这是简短摘要，点击这里继续阅读完整内容</p>"))
        XCTAssertTrue(FullTextPolicy.looksTruncated(
            "<p>\(String(repeating: "Short summary. ", count: 12))</p>"))
        XCTAssertFalse(FullTextPolicy.looksTruncated("<p>Too short</p>"))
        XCTAssertFalse(FullTextPolicy.looksTruncated(
            "<p>\(String(repeating: "完整正文", count: 90))</p><p>第二段</p>"))
    }

    func testFeedFullTextPolicyPersists() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(
            url: "https://example.com/rss", title: "Example", siteURL: nil, folderId: nil)
        try await db.setFullTextPolicy(
            feedId: feed.id!, mode: .always, selector: "article .body")
        let stored = try await db.feed(id: feed.id!)
        XCTAssertEqual(stored?.fullTextMode, .always)
        XCTAssertEqual(stored?.fullTextSelector, "article .body")
    }

    func testNewFeedTakesGlobalFullTextDefault() async throws {
        let db = try makeTempDB()
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: SettingsKey.defaultFullTextMode)
        defer { defaults.set(previous, forKey: SettingsKey.defaultFullTextMode) }

        defaults.set("always", forKey: SettingsKey.defaultFullTextMode)
        let configured = try await db.addFeed(
            url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let stored = try await db.feed(id: configured.id!)
        XCTAssertEqual(stored?.fullTextMode, .always)

        defaults.removeObject(forKey: SettingsKey.defaultFullTextMode)
        let fallback = try await db.addFeed(
            url: "https://b.example/rss", title: "B", siteURL: nil, folderId: nil)
        let fallbackStored = try await db.feed(id: fallback.id!)
        XCTAssertEqual(fallbackStored?.fullTextMode, .auto, "没设过就回落到 auto")
    }

    func testNeverModeHidesCachedFullTextWithoutDeletingIt() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(
            url: "https://example.com/rss", title: "Example", siteURL: nil, folderId: nil)
        let item = ParsedItem(
            guid: "1", url: "https://example.com/1", title: "Story", author: nil,
            publishedAt: Date(), contentHTML: "<p>Feed body</p>", summaryText: "Feed body")
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: item, action: nil)])
        let articleId = try await db.pool.read {
            try Int64.fetchOne($0, sql: "SELECT id FROM article")!
        }
        try await db.storeExtractedHTML(articleId: articleId, "<p>Extracted body</p>")
        try await db.setFullTextPolicy(feedId: feed.id!, mode: .never, selector: nil)

        let reader = try await db.readerData(articleId: articleId)
        let state = try await db.fullTextState(articleId: articleId)
        XCTAssertNil(reader?.extractedHTML)
        XCTAssertEqual(state?.hasFullText, true)
    }
}
