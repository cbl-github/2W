import XCTest
@testable import BiFeed

/// Discourse（按引擎识别）与 Lobsters 的识别与解析。样本手工写，不打网络。
final class ForumEngineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 否定表是进程内全局的，测试之间必须互不污染
        DiscourseHostVerdict.reset()
    }

    override func tearDown() {
        DiscourseHostVerdict.reset()
        super.tearDown()
    }

    // MARK: - Discourse 识别

    func testMatchesDiscourseTopicPaths() {
        let cases: [(String, ForumKind)] = [
            ("https://linux.do/t/topic/123456", .discourse(host: "linux.do", topicId: 123456)),
            ("https://linux.do/t/topic/123456/7", .discourse(host: "linux.do", topicId: 123456)),
            ("https://linux.do/t/123456", .discourse(host: "linux.do", topicId: 123456)),
            ("https://forums.swift.org/t/se-0123-something/60123/",
             .discourse(host: "forums.swift.org", topicId: 60123)),
            ("https://users.rust-lang.org/t/how-do-i/98765",
             .discourse(host: "users.rust-lang.org", topicId: 98765)),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(ForumResolver.forumKind(url: url, commentsURL: nil), expected,
                           "未识别: \(url)")
        }
    }

    func testDoesNotMatchNonDiscoursePaths() {
        let urls = [
            "https://example.com/t/",
            "https://example.com/t/only-slug",         // 没有数字 id
            "https://example.com/topics/123",
            "https://example.com/t/slug/123/extra",    // 楼号位不是数字
            "https://example.com/tag/123",
            "ftp://example.com/t/slug/123",            // 非 HTTP
        ]
        for url in urls {
            XCTAssertNil(ForumResolver.forumKind(url: url, commentsURL: nil), "误命中: \(url)")
        }
    }

    /// v2ex 的 `/t/<id>` 形态与 Discourse 撞车，靠 match 顺序保证 v2ex 先赢。
    func testV2EXAndOtherKnownSitesWinOverDiscourse() {
        XCTAssertEqual(ForumResolver.forumKind(url: "https://www.v2ex.com/t/1234095", commentsURL: nil),
                       .v2ex(1234095))
        XCTAssertEqual(ForumResolver.forumKind(url: "https://www.v2ex.com/t/1234095#reply3",
                                               commentsURL: nil),
                       .v2ex(1234095))
        XCTAssertEqual(ForumResolver.forumKind(url: "https://lobste.rs/s/abc123/some_title",
                                               commentsURL: nil),
                       .lobsters("abc123"))
    }

    /// 抓过一次判定不是 Discourse，同 host 之后直接不当论坛。
    func testRejectedHostStopsMatching() {
        let url = "https://blog.example.com/t/post-slug/42"
        XCTAssertEqual(ForumResolver.forumKind(url: url, commentsURL: nil),
                       .discourse(host: "blog.example.com", topicId: 42))
        DiscourseHostVerdict.reject(host: "BLOG.Example.com")   // 大小写不敏感
        XCTAssertNil(ForumResolver.forumKind(url: url, commentsURL: nil))
        // 只影响被判定的 host
        XCTAssertEqual(ForumResolver.forumKind(url: "https://linux.do/t/x/1", commentsURL: nil),
                       .discourse(host: "linux.do", topicId: 1))
    }

    // MARK: - Discourse 解析

    /// 字段照 `/t/<id>.json` 的公开响应：post_stream.posts + posts_count + title。
    /// 3 楼，posts_count 说明还有更多。
    private let discourseJSON = """
    {"title":"样本主题","posts_count":25,"post_stream":{"posts":[
      {"post_number":1,"username":"op_user","created_at":"2026-08-01T10:00:00.000Z",
       "cooked":"<p>题干正文</p>"},
      {"post_number":2,"username":"alice","created_at":"2026-08-01T10:05:00.000Z",
       "cooked":"<p>看这里 <a href=\\"/t/other/9\\">另一帖</a> <img src=\\"/uploads/a.png\\"></p>"},
      {"post_number":3,"username":"op_user","created_at":"2026-08-01T10:09:00Z",
       "cooked":"<p>楼主补充</p>"}
    ]}}
    """

    func testParsesDiscourseTopicAndAbsolutizesLinks() throws {
        let thread = try ForumResolver.parseDiscourse(
            data: Data(discourseJSON.utf8), host: "linux.do", fallbackTitle: "兜底")

        XCTAssertEqual(thread.source, "discourse")
        XCTAssertEqual(thread.title, "样本主题")
        // 1 楼是题干不进 posts；末尾多一行「还有 N 条」占位
        XCTAssertEqual(thread.posts.count, 3)
        XCTAssertEqual(thread.postCount, 2, "占位行不计入楼层数")
        XCTAssertEqual(thread.posts.map(\.author), ["alice", "op_user", ""])
        XCTAssertEqual(thread.posts.map(\.index), [2, 3, 0], "楼号用 post_number")
        XCTAssertEqual(thread.posts.map(\.isOP), [false, true, false])
        XCTAssertEqual(thread.posts.map(\.depth), [0, 0, 0], "Discourse 平铺")

        XCTAssertTrue(thread.posts[0].html.contains(#"href="https://linux.do/t/other/9""#))
        XCTAssertTrue(thread.posts[0].html.contains(#"src="https://linux.do/uploads/a.png""#))
        // 25 - 3 = 22
        XCTAssertTrue(thread.posts[2].html.contains("还有 22 条回复"), thread.posts[2].html)
        // 带小数秒与不带小数秒的 created_at 都要能解析
        XCTAssertFalse(thread.posts[0].timeText.isEmpty)
        XCTAssertFalse(thread.posts[1].timeText.isEmpty)
    }

    func testDiscourseWithoutRemainderHasNoPlaceholder() throws {
        let json = """
        {"posts_count":2,"post_stream":{"posts":[
          {"post_number":1,"username":"op","created_at":"2026-08-01T10:00:00.000Z","cooked":"<p>题干</p>"},
          {"post_number":2,"username":"bob","created_at":"2026-08-01T10:01:00.000Z","cooked":"<p>回一句</p>"}
        ]}}
        """
        let thread = try ForumResolver.parseDiscourse(
            data: Data(json.utf8), host: "linux.do", fallbackTitle: "兜底")
        XCTAssertEqual(thread.title, "兜底", "没有 title 用文章标题兜底")
        XCTAssertEqual(thread.posts.count, 1)
        XCTAssertEqual(thread.postCount, 1)
    }

    func testDiscourseRejectsNonDiscourseShape() {
        // 随便一个站的 JSON 接口：能解析成 JSON，但没有 post_stream
        XCTAssertThrowsError(try ForumResolver.parseDiscourse(
            data: Data(#"{"ok":true,"items":[]}"#.utf8), host: "blog.example.com", fallbackTitle: "x"))
        XCTAssertThrowsError(try ForumResolver.parseDiscourse(
            data: Data("<!doctype html><html>".utf8), host: "blog.example.com", fallbackTitle: "x"))
    }

    // MARK: - Lobsters 识别

    func testMatchesAndRejectsLobstersURLs() {
        XCTAssertEqual(
            ForumResolver.forumKind(url: "https://lobste.rs/s/xk9dpv/a_story_title", commentsURL: nil),
            .lobsters("xk9dpv"))
        XCTAssertEqual(ForumResolver.forumKind(url: "https://lobste.rs/s/xk9dpv", commentsURL: nil),
                       .lobsters("xk9dpv"))
        for url in ["https://notlobste.rs/s/xk9dpv/t", "https://lobste.rs/t/rust",
                    "https://lobste.rs/u/someone"] {
            XCTAssertNil(ForumResolver.forumKind(url: url, commentsURL: nil), "误命中: \(url)")
        }
    }

    // MARK: - Lobsters 解析

    func testParsesLobstersNestedComments() throws {
        // commenting_user 在不同版本里是字符串或 {username}，两种都要吃下
        let json = """
        {"short_id":"xk9dpv","title":"样本故事","submitter_user":"carol","comments":[
          {"commenting_user":"alice","score":5,"indent_level":1,
           "created_at":"2026-08-01T10:00:00.000-07:00","comment":"<p>顶层</p>"},
          {"commenting_user":{"username":"carol"},"score":2,"indent_level":2,
           "created_at":"2026-08-01T10:05:00.000-07:00","comment":"<p>楼主回复</p>"},
          {"commenting_user":"bob","indent_level":3,
           "created_at":"2026-08-01T10:09:00.000-07:00","comment":"<p>三层</p>"}
        ]}
        """
        let thread = try ForumResolver.parseLobsters(data: Data(json.utf8), fallbackTitle: "兜底")

        XCTAssertEqual(thread.source, "lobsters")
        XCTAssertEqual(thread.title, "样本故事")
        XCTAssertEqual(thread.postCount, 3)
        XCTAssertEqual(thread.posts.map(\.author), ["alice", "carol", "bob"])
        XCTAssertEqual(thread.posts.map(\.depth), [0, 1, 2], "depth = indent_level - 1")
        XCTAssertEqual(thread.posts.map(\.isOP), [false, true, false])
        XCTAssertEqual(thread.posts.map(\.score), [5, 2, nil])
        XCTAssertEqual(thread.posts[0].html, "<p>顶层</p>")
        XCTAssertFalse(thread.posts[0].timeText.isEmpty)
    }

    /// 现行 lobste.rs API（2026-08-14 真实响应实测）：0 起的 depth 字段，没有 indent_level。
    func testParsesLobstersCurrentAPIDepthField() throws {
        let json = """
        {"short_id":"tssf5y","title":"现行样本","submitter_user":"fzakaria","comments":[
          {"commenting_user":"pizlonator","score":9,"depth":0,"parent_comment":null,
           "created_at":"2026-08-14T01:00:00.000-05:00","comment":"<p>顶层</p>"},
          {"commenting_user":"moltonel","score":3,"depth":1,"parent_comment":"rpp7t7",
           "created_at":"2026-08-14T01:10:00.000-05:00","comment":"<p>二层</p>"},
          {"commenting_user":"fzakaria","score":1,"depth":2,"parent_comment":"eophu2",
           "created_at":"2026-08-14T01:20:00.000-05:00","comment":"<p>楼主三层</p>"}
        ]}
        """
        let thread = try ForumResolver.parseLobsters(data: Data(json.utf8), fallbackTitle: "兜底")
        XCTAssertEqual(thread.posts.map(\.depth), [0, 1, 2], "depth 字段直接就是 0 起缩进")
        XCTAssertEqual(thread.posts.map(\.isOP), [false, false, true])
    }

    func testLobstersEmptyAndBadShape() throws {
        let thread = try ForumResolver.parseLobsters(
            data: Data(#"{"title":"无评论"}"#.utf8), fallbackTitle: "兜底")
        XCTAssertTrue(thread.posts.isEmpty)
        XCTAssertThrowsError(
            try ForumResolver.parseLobsters(data: Data("[]".utf8), fallbackTitle: "x"))
    }

    // MARK: - 渲染

    func testDiscourseRendersFlatWithPostNumbers() throws {
        let thread = try ForumResolver.parseDiscourse(
            data: Data(discourseJSON.utf8), host: "linux.do", fallbackTitle: "兜底")
        let html = ReaderTemplate.forumHTML(thread)
        XCTAssertTrue(html.contains("回帖"), "平铺样式用「回帖」而不是「评论」")
        XCTAssertTrue(html.contains("#2 ·"), "楼号来自 post_number")
        XCTAssertTrue(html.contains("楼主"))
        XCTAssertTrue(html.contains("--depth:0"))
        XCTAssertFalse(html.contains(#"<span class="bf-post-author"></span>"#),
                       "占位行没有作者，不出头部")
    }
}
