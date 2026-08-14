import XCTest
@testable import BiFeed

final class HTMLToolsTests: XCTestCase {
    func testPlainTextStripsMarkupAndEntities() {
        let html = "<p>Hello <b>world</b> &amp; <script>alert(1)</script>&lt;tag&gt; &#20013;文</p>"
        let out = HTMLTools.plainText(html)
        XCTAssertEqual(out, "Hello world & <tag> 中文")
    }

    func testPlainTextKeepsChineseAngleBracketTitle() {
        XCTAssertEqual(HTMLTools.plainText("<书名>：测试"), "<书名>：测试")
    }

    func testAbsolutizeRelativeContentURLs() {
        let html = #"<p><img src="../img/a.png"><a href='/next?q=1&x=2'>next</a></p>"#
        let out = HTMLTools.absolutizeURLs(
            in: html, base: URL(string: "https://example.com/posts/one")!)
        XCTAssertTrue(out.contains(#"src="https://example.com/img/a.png""#))
        XCTAssertTrue(out.contains(#"href='https://example.com/next?q=1&amp;x=2'"#))
    }

    func testExcerptLimits() {
        let long = String(repeating: "字", count: 500)
        XCTAssertEqual(HTMLTools.excerpt("<p>\(long)</p>").count, 300)
    }

    func testExcerptCutsAtSentenceBoundary() {
        // 中文：每句 51 字符（50 字 + 。），300 落在第 6 句中间，回退到第 5 句句号（回退 45 ≤ 40%）
        let zhSentence = String(repeating: "字", count: 50) + "。"
        XCTAssertEqual(HTMLTools.excerpt("<p>\(String(repeating: zhSentence, count: 10))</p>"),
                       String(repeating: zhSentence, count: 5))
        // 英文：每句 45 字符（44 字母 + .），回退到 270 处的句点（回退 30 ≤ 40%）
        let enSentence = String(repeating: "a", count: 44) + "."
        XCTAssertEqual(HTMLTools.excerpt(String(repeating: enSentence, count: 8)),
                       String(repeating: enSentence, count: 6))
        // 无句读长串：找不到句末标点，维持 300 硬截断
        XCTAssertEqual(HTMLTools.excerpt(String(repeating: "字", count: 500)).count, 300)
        // 短文：不足 limit 原样返回，包括结尾的半句
        XCTAssertEqual(HTMLTools.excerpt("<p>你好。世界</p>"), "你好。世界")
    }

    func testDiscoverFeeds() throws {
        let html = """
        <!doctype html><html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed.xml">
        <link rel="alternate" type="application/atom+xml" href="https://example.com/atom">
        </head><body></body></html>
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/blog/"))
        let feeds = HTMLTools.discoverFeeds(html: html, base: base)
        XCTAssertEqual(feeds.map(\.url.absoluteString), ["https://example.com/feed.xml", "https://example.com/atom"])
        // 无 title 属性的那条用 URL 路径兜底
        XCTAssertEqual(feeds.map(\.title), ["RSS", "/atom"])
    }

    func testDiscoverFeedsKeepsOrderAndDropsDuplicates() throws {
        let html = """
        <link rel="alternate" type="application/rss+xml" title="全站" href="/feed.xml">
        <link rel='alternate' type='application/feed+json' title='JSON &amp; 全站' href='/feed.json'>
        <link rel=alternate type="application/atom+xml" title="设计" href="/tag/design/atom.xml">
        <link rel="alternate" type="application/rss+xml" title="全站（重复）" href="https://example.com/feed.xml">
        <link rel="alternate" type="text/html" title="不是 feed" href="/mobile">
        """
        let base = try XCTUnwrap(URL(string: "https://example.com/blog/"))
        let feeds = HTMLTools.discoverFeeds(html: html, base: base)
        XCTAssertEqual(feeds.map(\.url.absoluteString), [
            "https://example.com/feed.xml",
            "https://example.com/feed.json",
            "https://example.com/tag/design/atom.xml",
        ])
        XCTAssertEqual(feeds.map(\.title), ["全站", "JSON & 全站", "设计"])
    }

    func testLooksLikeHTML() {
        XCTAssertTrue(HTMLTools.looksLikeHTML("<!DOCTYPE html><html>…"))
        XCTAssertFalse(HTMLTools.looksLikeHTML("<?xml version=\"1.0\"?><rss>"))
    }
}
