import XCTest
@testable import BiFeed

final class RedditTests: XCTestCase {
    // MARK: - 识别

    func testMatchesAllAcceptedHosts() {
        let urls = [
            "https://www.reddit.com/r/swift/comments/abc123/some_title/",
            "https://old.reddit.com/r/swift/comments/abc123/some_title/",
            "https://reddit.com/r/swift/comments/abc123",
            "https://np.reddit.com/r/swift/comments/abc123/some_title/?sort=new",
        ]
        for url in urls {
            XCTAssertEqual(
                ForumResolver.forumKind(url: url, commentsURL: nil),
                .reddit("https://www.reddit.com/r/swift/comments/abc123"),
                "未识别或未规范化: \(url)")
        }
    }

    func testDoesNotMatchLookalikeOrNonThreadURLs() {
        let urls = [
            "https://notreddit.com/r/swift/comments/abc123/t/",
            "https://reddit.com.evil.example/r/swift/comments/abc123/",
            "https://www.reddit.com/r/swift/",              // 子版首页不是帖子
            "https://www.reddit.com/user/someone/",
            "https://example.com/post/1",
        ]
        for url in urls {
            XCTAssertNil(ForumResolver.forumKind(url: url, commentsURL: nil), "误命中: \(url)")
        }
    }

    // MARK: - 评论 JSON 解析

    /// 手工样本，字段结构照 Reddit `/comments/<id>.json` 的公开响应：
    /// 两元素 Listing 数组、t3 帖子本体、t1 评论（replies 嵌套 Listing，无回复时是空字符串）、more 节点。
    private let sampleJSON = """
    [
      {"kind":"Listing","data":{"children":[
        {"kind":"t3","data":{"title":"样本帖","author":"op_user","score":42,
         "selftext_html":"<div class=\\"md\\"><p>题干</p></div>","created_utc":1700000000}}
      ]}},
      {"kind":"Listing","data":{"children":[
        {"kind":"t1","data":{"author":"alice","score":9,"created_utc":1700000100,
         "body_html":"<div class=\\"md\\"><p>if a < b { x }</p></div>",
         "replies":{"kind":"Listing","data":{"children":[
           {"kind":"t1","data":{"author":"op_user","score":3,"created_utc":1700000200,
            "body_html":"<div class=\\"md\\"><p>楼主回复</p></div>","replies":""}},
           {"kind":"more","data":{"count":7,"id":"xyz","children":["a","b"]}}
         ]}}}},
        {"kind":"t1","data":{"author":"bob","score":1,"created_utc":1700000300,
         "body_html":"<div class=\\"md\\"><p>二楼</p></div>","replies":""}}
      ]}}
    ]
    """

    func testParsesNestedCommentsScoresAndMoreNode() throws {
        let thread = try ForumResolver.parseReddit(
            data: Data(sampleJSON.utf8), fallbackTitle: "兜底标题")

        XCTAssertEqual(thread.source, "reddit")
        XCTAssertEqual(thread.title, "样本帖")
        XCTAssertEqual(thread.posts.count, 4)
        XCTAssertEqual(thread.postCount, 3, "more 占位不计入楼层数")

        // DFS 顺序：alice → 它的子回复 → more 占位 → bob
        XCTAssertEqual(thread.posts.map(\.author), ["alice", "op_user", "", "bob"])
        XCTAssertEqual(thread.posts.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(thread.posts.map(\.isOP), [false, true, false, false])
        XCTAssertEqual(thread.posts.map(\.score), [9, 3, nil, 1])

        // 样本里的 `<` 是 raw_json=1 的形态（不带该参数会是 `&lt;`）；解析器原样透传，不再解一次实体
        XCTAssertEqual(thread.posts[0].html, #"<div class="md"><p>if a < b { x }</p></div>"#)
        XCTAssertTrue(thread.posts[2].html.contains("还有 7 条回复"))
        XCTAssertFalse(thread.posts[1].timeText.isEmpty)
    }

    func testParseUsesFallbackTitleAndRejectsWrongShape() throws {
        let noTitle = #"[{"kind":"Listing","data":{"children":[]}},{"kind":"Listing","data":{"children":[]}}]"#
        let thread = try ForumResolver.parseReddit(data: Data(noTitle.utf8), fallbackTitle: "兜底标题")
        XCTAssertEqual(thread.title, "兜底标题")
        XCTAssertTrue(thread.posts.isEmpty)

        XCTAssertThrowsError(
            try ForumResolver.parseReddit(data: Data(#"{"error":404}"#.utf8), fallbackTitle: "x"))
    }

    // MARK: - 正文重排

    /// 链接帖：单行表格 + 缩略图锚回 permalink + 尾部模板行，[link] 指向站外。
    func testRewriteLinkPostStripsTableAndTemplateTail() {
        let html = """
        <table> <tr><td> <a href="https://www.reddit.com/r/swift/comments/abc/t/">\
        <img src="https://b.thumbs.redditmedia.com/thumb.jpg" alt="t" /></a> </td><td> \
        &#32; submitted by &#32; <a href="https://www.reddit.com/user/alice"> /u/alice </a> <br/> \
        <span><a href="https://example.com/article">[link]</a></span> &#32; \
        <span><a href="https://www.reddit.com/r/swift/comments/abc/t/">[comments]</a></span> \
        </td></tr></table>
        """
        let out = RedditContent.rewrite(html: html)

        XCTAssertFalse(out.contains("<table"))
        XCTAssertFalse(out.contains("<td"))
        XCTAssertFalse(out.contains("submitted by"))
        XCTAssertFalse(out.contains("[comments]"))
        XCTAssertTrue(out.contains(#"<p>链接：<a href="https://example.com/article">"#))
        // href 不是图片、[link] 也不是图片：锚点原样保留，不丢缩略图
        XCTAssertTrue(out.contains("b.thumbs.redditmedia.com"))
        XCTAssertEqual(RedditContent.rewrite(html: out), out, "重排必须幂等")
    }

    func testRewriteUpgradesThumbnailToFullImage() {
        let html = """
        <table> <tr><td> <a href="https://www.reddit.com/r/pics/comments/abc/t/">\
        <img src="https://b.thumbs.redditmedia.com/thumb.jpg" alt="t" /></a> </td><td> \
        submitted by <a href="https://www.reddit.com/user/bob"> /u/bob </a> <br/> \
        <span><a href="https://i.redd.it/full.png">[link]</a></span> \
        <span><a href="https://www.reddit.com/r/pics/comments/abc/t/">[comments]</a></span> \
        </td></tr></table>
        """
        let out = RedditContent.rewrite(html: html)

        XCTAssertTrue(out.contains(#"<img src="https://i.redd.it/full.png">"#))
        XCTAssertFalse(out.contains("b.thumbs.redditmedia.com"), "缩略图应被原图替换")
        XCTAssertFalse(out.contains("<a "), "锚点壳与模板尾都该消失")
        XCTAssertEqual(RedditContent.rewrite(html: out), out, "重排必须幂等")
    }

    func testRewriteSelfPostKeepsBodyAndDropsSelfLink() {
        let html = """
        <!-- SC_OFF --><div class="md"><p>第一段</p><ul><li>要点</li></ul>\
        <pre><code>let x = 1
        </code></pre></div><!-- SC_ON --> &#32; submitted by &#32; \
        <a href="https://www.reddit.com/user/carol"> /u/carol </a> <br/> \
        <span><a href="https://www.reddit.com/r/swift/comments/abc/t/">[link]</a></span> &#32; \
        <span><a href="https://www.reddit.com/r/swift/comments/abc/t/">[comments]</a></span>
        """
        let out = RedditContent.rewrite(html: html)

        XCTAssertTrue(out.contains("<p>第一段</p>"))
        XCTAssertTrue(out.contains("<li>要点</li>"))
        XCTAssertTrue(out.contains("<pre><code>let x = 1"))
        XCTAssertFalse(out.contains("submitted by"))
        XCTAssertFalse(out.contains("链接："), "[link] 指回自身 permalink，不该冒出一行链接")
        XCTAssertEqual(RedditContent.rewrite(html: out), out, "重排必须幂等")
    }

    func testRewriteLeavesUnrecognizedContentAlone() {
        // 普通文章正文：无模板尾、无布局表；多行真表格也不能被拆
        let plain = "<p>正文 submitted by 某人</p><table><tr><td>a</td></tr><tr><td>b</td></tr></table>"
        XCTAssertEqual(RedditContent.rewrite(html: plain), plain)

        let onlyImage = #"<p><img src="https://i.redd.it/x.png"></p>"#
        XCTAssertEqual(RedditContent.rewrite(html: onlyImage), onlyImage)

        XCTAssertEqual(RedditContent.rewrite(html: ""), "")
    }
}
