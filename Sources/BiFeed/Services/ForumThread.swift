import Foundation
import GRDB

// MARK: - 模型

enum ForumKind: Equatable {
    case v2ex(Int)
    case hn(Int)
    /// 规范化到 `https://www.reddit.com/r/<子版>/comments/<id>`（无尾斜杠），加 `.json` 即接口地址。
    case reddit(String)
    /// Discourse 按引擎识别不按域名白名单：linux.do、users.rust-lang.org、forums.swift.org
    /// 都是同一套 `/t/<slug>/<id>` + `/t/<id>.json`。命中只是候选，抓到才算数。
    case discourse(host: String, topicId: Int)
    /// lobste.rs 的 short id。
    case lobsters(String)
}

/// Discourse 猜错了要能收回：抓一次发现不是 Discourse，就把该 host 记进进程内否定表，
/// 之后同 host 的 `/t/...` 一律不当论坛（不出「刷新回帖」、不禁全文抓取）。
/// 只活在内存里——重启后重试一次的成本可以忽略，不值得为它加一张表。
enum DiscourseHostVerdict {
    private static let lock = NSLock()
    private static var rejected: Set<String> = []

    static func reject(host: String) {
        lock.lock()
        defer { lock.unlock() }
        rejected.insert(host.lowercased())
    }

    static func isRejected(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected.contains(host.lowercased())
    }

    /// 测试用：清掉进程内积累的判定。
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        rejected.removeAll()
    }
}

struct ForumPost: Codable {
    var index: Int
    var author: String
    var timeText: String
    var html: String
    var depth: Int
    var isOP: Bool
    /// Reddit 票数；V2EX/HN 无此概念，恒 nil。可空所以旧缓存 JSON 照常解码。
    var score: Int? = nil
}

struct ForumThread: Codable {
    var source: String // "v2ex" | "hn"
    var title: String
    var postCount: Int
    var posts: [ForumPost]
}

enum ForumFailure: LocalizedError {
    case badResponse(String)
    /// Reddit 对数据中心出口 IP 整段拒绝未登录 JSON（2026-08 实测：curl 与 URLSession、
    /// 描述性与浏览器 UA 全部 403，而同出口 RSS 是 200）。这不是代码或参数问题，
    /// 换住宅出口或 OAuth 才能过，报错要把话说清楚。
    case redditBlocked
    /// Discourse 候选猜错了。调用方要静默降级成普通文章，别把它显示给用户。
    case notForum
    var errorDescription: String? {
        switch self {
        case .badResponse(let detail): return L("error.forum.badResponse", detail)
        case .notForum: return L("error.forum.notForum")
        case .redditBlocked:
            return L("error.forum.redditBlocked")
        }
    }
}

// MARK: - 识别与抓取

enum ForumResolver {
    /// commentsURL 优先于 url。
    static func forumKind(url: String?, commentsURL: String?) -> ForumKind? {
        for candidate in [commentsURL, url] {
            if let candidate, let kind = match(candidate) { return kind }
        }
        return nil
    }

    private static func match(_ s: String) -> ForumKind? {
        if let m = s.firstMatch(of: /v2ex\.com\/t\/(\d+)/), let id = Int(m.1) {
            return .v2ex(id)
        }
        if let u = URL(string: s), u.host() == "news.ycombinator.com",
           let m = s.firstMatch(of: /item\?id=(\d+)/), let id = Int(m.1) {
            return .hn(id)
        }
        // 走 host 白名单而不是子串匹配：`notreddit.com/r/x/comments/y` 不能算命中
        if let u = URL(string: s), let host = u.host()?.lowercased(),
           ["reddit.com", "www.reddit.com", "old.reddit.com", "np.reddit.com"].contains(host),
           let m = u.path().firstMatch(of: /^\/r\/([A-Za-z0-9_]+)\/comments\/([A-Za-z0-9]+)/) {
            return .reddit("https://www.reddit.com/r/\(m.1)/comments/\(m.2)")
        }
        if let u = URL(string: s), u.host()?.lowercased() == "lobste.rs",
           let m = u.path().firstMatch(of: /^\/s\/([A-Za-z0-9]+)/) {
            return .lobsters(String(m.1))
        }
        // Discourse 放最后：它只认路径形态，任何域名都可能命中，必须让上面的确定站先走。
        // `/t/<slug>/<id>`、`/t/<slug>/<id>/<楼号>`、`/t/<id>` 三种形态。
        // `/t/123/456` 按 Discourse 自己的路由解释成 slug=123、id=456，所以 slug 组贪婪。
        if let u = URL(string: s), let host = u.host()?.lowercased(),
           ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
           !DiscourseHostVerdict.isRejected(host),
           let m = u.path().firstMatch(of: /^\/t\/(?:[^\/]+\/)?(\d+)(?:\/\d+)?\/?$/),
           let id = Int(m.1) {
            return .discourse(host: host, topicId: id)
        }
        return nil
    }

    /// articleAuthor/articleTitle 来自 RSS 已有数据：V2EX 的楼主名和标题不再单独打 API
    /// （原本每帖两个请求，V2EX 限流 120 次/小时，砍半后浏览量翻倍才会撞）。
    static func fetch(_ kind: ForumKind, fetcher: FeedFetcher,
                      articleAuthor: String?, articleTitle: String) async throws -> ForumThread {
        switch kind {
        case .v2ex(let id):
            return try await fetchV2EX(topicId: id, fetcher: fetcher,
                                       topicAuthor: articleAuthor, topicTitle: articleTitle)
        case .hn(let id): return try await fetchHN(itemId: id, fetcher: fetcher)
        case .reddit(let permalink):
            return try await fetchReddit(permalink: permalink, fetcher: fetcher,
                                         fallbackTitle: articleTitle)
        case .discourse(let host, let topicId):
            return try await fetchDiscourse(host: host, topicId: topicId, fetcher: fetcher,
                                            fallbackTitle: articleTitle)
        case .lobsters(let shortId):
            return try await fetchLobsters(shortId: shortId, fetcher: fetcher,
                                           fallbackTitle: articleTitle)
        }
    }

    // MARK: - V2EX

    private struct V2EXMember: Decodable { var username: String }
    private struct V2EXReply: Decodable {
        var member: V2EXMember
        var contentRendered: String
        var created: Int // unix 秒
    }

    /// 帖子正文已在文章 content 里，posts 只装回帖；楼主发言靠 isOP 标记。
    private static func fetchV2EX(topicId: Int, fetcher: FeedFetcher,
                                  topicAuthor: String?, topicTitle: String) async throws -> ForumThread {
        // V2EX API v1 的 CDN 会把新帖的空回帖结果缓存住（实测同 URL 恒返回 []，
        // 加随机参数立刻返回真实回帖），必须 cache-bust。
        // 该接口不分页也不截断：2026-08-14 实测 topic 1234095（当时 450 回复）单次返回 451 条，
        // 加 `page=2` 返回同一批（首尾 reply id 一致）。所以长帖不需要翻页逻辑。
        let bust = Int(Date().timeIntervalSince1970)
        let repliesData = try await getData(
            "https://www.v2ex.com/api/replies/show.json?topic_id=\(topicId)&_=\(bust)", fetcher: fetcher)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let replies = try? decoder.decode([V2EXReply].self, from: repliesData) else {
            throw ForumFailure.badResponse(L("error.forum.detail.v2ex", topicId))
        }
        let fmt = relativeFormatter()
        let now = Date()
        let posts = replies.enumerated().map { offset, reply in
            ForumPost(
                index: offset + 1,
                author: reply.member.username,
                timeText: fmt.localizedString(
                    for: Date(timeIntervalSince1970: Double(reply.created)), relativeTo: now),
                html: reply.contentRendered,
                depth: 0,
                isOP: topicAuthor != nil && reply.member.username == topicAuthor)
        }
        return ForumThread(source: "v2ex", title: topicTitle, postCount: posts.count, posts: posts)
    }

    // MARK: - HN (Algolia)

    private struct HNItem: Decodable {
        var author: String?
        var title: String?
        var text: String?
        var createdAtI: Int?
        var children: [HNItem]?
    }

    private static func fetchHN(itemId: Int, fetcher: FeedFetcher) async throws -> ForumThread {
        let data = try await getData("https://hn.algolia.com/api/v1/items/\(itemId)", fetcher: fetcher)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let root = try? decoder.decode(HNItem.self, from: data) else {
            throw ForumFailure.badResponse("HN item \(itemId)")
        }
        let fmt = relativeFormatter()
        let now = Date()
        var posts: [ForumPost] = []
        // DFS 拍平嵌套评论。已删评论（author 为 null）连同整棵子树跳过。
        func walk(_ item: HNItem, depth: Int) {
            guard let author = item.author, let created = item.createdAtI else { return }
            posts.append(ForumPost(
                index: posts.count + 1,
                author: author,
                timeText: fmt.localizedString(
                    for: Date(timeIntervalSince1970: Double(created)), relativeTo: now),
                html: item.text ?? "",
                depth: depth,
                isOP: author == root.author))
            for child in item.children ?? [] { walk(child, depth: depth + 1) }
        }
        for child in root.children ?? [] { walk(child, depth: 0) }
        return ForumThread(source: "hn", title: root.title ?? "", postCount: posts.count, posts: posts)
    }

    // MARK: - Reddit

    /// 免登录接口限流紧，与 V2EX 同策略：不预取，点开才拉，失败不重试。
    private static func fetchReddit(permalink: String, fetcher: FeedFetcher,
                                    fallbackTitle: String) async throws -> ForumThread {
        // raw_json=1 少一层实体转义（否则 body_html 里的 `<` 是 `&lt;`）；
        // UA 必须是描述性的，Reddit 对 URLSession 默认 UA 直接 429。
        do {
            let data = try await getData("\(permalink).json?raw_json=1", fetcher: fetcher,
                                         userAgent: "2W/0.1 (macOS RSS reader)")
            return try parseReddit(data: data, fallbackTitle: fallbackTitle)
        } catch FetchError.status(403, _) {
            throw ForumFailure.redditBlocked
        }
    }

    /// 响应是两元素数组：[0] 帖子本体，[1] 评论树。
    /// 字段可选性太杂（replies 无回复时是空字符串而非对象），Codable 要写一堆自定义解码，
    /// 直接走 JSONSerialization 更短。测试喂手工样本。
    static func parseReddit(data: Data, fallbackTitle: String) throws -> ForumThread {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any], root.count >= 2 else {
            throw ForumFailure.badResponse(L("error.forum.detail.reddit"))
        }
        let op = listingChildren(root[0]).first?["data"] as? [String: Any]
        let opAuthor = op?["author"] as? String
        let title = op?["title"] as? String ?? fallbackTitle
        let fmt = relativeFormatter()
        let now = Date()
        var posts: [ForumPost] = []
        // 楼主帖正文不进 posts：与 V2EX 一致，题干已经在文章 content 里（RedditContent 重排过）。
        func walk(_ node: [String: Any], depth: Int) {
            guard let d = node["data"] as? [String: Any] else { return }
            switch node["kind"] as? String {
            case "t1":
                let author = d["author"] as? String ?? "[deleted]"
                posts.append(ForumPost(
                    index: posts.count + 1,
                    author: author,
                    timeText: (d["created_utc"] as? Double).map {
                        fmt.localizedString(for: Date(timeIntervalSince1970: $0), relativeTo: now)
                    } ?? "",
                    html: d["body_html"] as? String ?? "",
                    depth: depth,
                    isOP: opAuthor != nil && author == opAuthor,
                    score: d["score"] as? Int))
                for child in listingChildren(d["replies"]) { walk(child, depth: depth + 1) }
            case "more":
                // 不追加请求展开。count 为 0 是「continue this thread」占位，写「还有 0 条」没意义。
                guard let count = d["count"] as? Int, count > 0 else { return }
                posts.append(ForumPost(
                    index: posts.count + 1, author: "", timeText: "",
                    html: "<p>" + L("forum.more.reddit", count) + "</p>", depth: depth, isOP: false))
            default: break
            }
        }
        for child in listingChildren(root[1]) { walk(child, depth: 0) }
        // more 占位不算楼层，标题里的计数只数真实评论
        return ForumThread(source: "reddit", title: title,
                           postCount: posts.filter { !$0.author.isEmpty }.count, posts: posts)
    }

    /// Listing 壳：`{"data": {"children": [...]}}`。无回复时该位置是空字符串，返回空数组。
    private static func listingChildren(_ any: Any?) -> [[String: Any]] {
        guard let listing = any as? [String: Any],
              let data = listing["data"] as? [String: Any],
              let children = data["children"] as? [[String: Any]] else { return [] }
        return children
    }

    // MARK: - Discourse

    private struct DiscourseTopic: Decodable {
        struct Stream: Decodable { var posts: [Post] }
        struct Post: Decodable {
            var username: String?
            var cooked: String?
            var createdAt: String?
            var postNumber: Int?
        }
        var postStream: Stream
        var postsCount: Int?
        var title: String?
    }

    /// 候选站点：抓不动或者不是 Discourse 形状，就记否定判定并抛 notForum，让调用方当普通文章处理。
    // ponytail: 断网这类临时失败也会判否定，真 Discourse 站在本次进程里从此不出楼层。
    // 判定不落库，重启即恢复，暂不值得为它区分传输错误和 HTTP 错误；真碰上了再按 FetchError 分流。
    private static func fetchDiscourse(host: String, topicId: Int, fetcher: FeedFetcher,
                                       fallbackTitle: String) async throws -> ForumThread {
        do {
            let data = try await getData("https://\(host)/t/\(topicId).json", fetcher: fetcher)
            return try parseDiscourse(data: data, host: host, fallbackTitle: fallbackTitle)
        } catch {
            DiscourseHostVerdict.reject(host: host)
            throw ForumFailure.notForum
        }
    }

    /// 该接口只返回第一批（约 20 楼）。不追加请求：多数帖子够用，不够就给一行「还有 N 条」。
    /// 1 楼是题干，与 V2EX 一致地不进 posts——它已经在文章 content 里。
    static func parseDiscourse(data: Data, host: String, fallbackTitle: String) throws -> ForumThread {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let topic = try? decoder.decode(DiscourseTopic.self, from: data) else {
            throw ForumFailure.badResponse(L("error.forum.detail.discourse", host))
        }
        let stream = topic.postStream.posts
        let opAuthor = stream.first(where: { $0.postNumber == 1 })?.username
        let base = URL(string: "https://\(host)/")
        let fmt = relativeFormatter()
        let now = Date()
        var posts: [ForumPost] = stream.filter { $0.postNumber != 1 }.map { post in
            ForumPost(
                index: post.postNumber ?? 0,
                author: post.username ?? "",
                timeText: parseISO(post.createdAt).map {
                    fmt.localizedString(for: $0, relativeTo: now)
                } ?? "",
                html: HTMLTools.absolutizeURLs(in: post.cooked ?? "", base: base),
                depth: 0,
                isOP: opAuthor != nil && post.username == opAuthor)
        }
        let rendered = posts.count
        if let total = topic.postsCount, total > stream.count {
            posts.append(ForumPost(
                index: 0, author: "", timeText: "",
                html: "<p>" + L("forum.more.generic", total - stream.count) + "</p>", depth: 0, isOP: false))
        }
        return ForumThread(source: "discourse", title: topic.title ?? fallbackTitle,
                           postCount: rendered, posts: posts)
    }

    // MARK: - Lobsters

    /// `commenting_user` 历史上有字符串和 `{username}` 两种形态，`submitter_user` 同理；
    /// 为这点差异写自定义 Decodable 不划算，照 parseReddit 的先例走 JSONSerialization。
    static func parseLobsters(data: Data, fallbackTitle: String) throws -> ForumThread {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ForumFailure.badResponse(L("error.forum.detail.lobsters"))
        }
        let submitter = username(root["submitter_user"])
        let fmt = relativeFormatter()
        let now = Date()
        let posts = (root["comments"] as? [[String: Any]] ?? []).enumerated().map { offset, c in
            let author = username(c["commenting_user"]) ?? "[deleted]"
            return ForumPost(
                index: offset + 1,
                author: author,
                timeText: parseISO(c["created_at"] as? String).map {
                    fmt.localizedString(for: $0, relativeTo: now)
                } ?? "",
                html: c["comment"] as? String ?? "",
                // 现行 API 直接给 0 起的 depth（2026-08-14 真实响应实测）；
                // indent_level（1 起）是旧版字段，留作回退，两个都没有按顶层算。
                depth: (c["depth"] as? Int).map { max(0, $0) }
                    ?? max(0, (c["indent_level"] as? Int ?? 1) - 1),
                isOP: submitter != nil && author == submitter,
                score: c["score"] as? Int)
        }
        return ForumThread(source: "lobsters", title: root["title"] as? String ?? fallbackTitle,
                           postCount: posts.count, posts: posts)
    }

    private static func fetchLobsters(shortId: String, fetcher: FeedFetcher,
                                      fallbackTitle: String) async throws -> ForumThread {
        let data = try await getData("https://lobste.rs/s/\(shortId).json", fetcher: fetcher)
        return try parseLobsters(data: data, fallbackTitle: fallbackTitle)
    }

    private static func username(_ any: Any?) -> String? {
        (any as? String) ?? (any as? [String: Any])?["username"] as? String
    }

    // MARK: - 共用

    /// Discourse/Lobsters 的时间是 ISO8601，小数秒有无都见过。
    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmt.date(from: s) { return d }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s)
    }

    private static func getData(_ url: String, fetcher: FeedFetcher,
                                userAgent: String? = nil) async throws -> Data {
        // 不带条件请求头，.notModified 不可能出现。
        guard case .success(let data, _, _, _, _) = try await fetcher.fetch(
            url: URL(string: url)!, userAgent: userAgent) else {
            throw ForumFailure.badResponse(L("error.forum.detail.unexpected304"))
        }
        return data
    }

    private static func relativeFormatter() -> RelativeDateTimeFormatter {
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt
    }
}

// MARK: - 缓存

extension AppDatabase {
    func cachedThread(articleId: Int64) async throws -> ForumThread? {
        try await pool.read { db in
            guard let json = try String.fetchOne(
                db, sql: "SELECT json FROM forumThread WHERE articleId = ?",
                arguments: [articleId]) else { return nil }
            return try JSONDecoder().decode(ForumThread.self, from: Data(json.utf8))
        }
    }

    func storeThread(articleId: Int64, thread: ForumThread) async throws {
        let json = try String(decoding: JSONEncoder().encode(thread), as: UTF8.self)
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO forumThread (articleId, json, fetchedAt) VALUES (?, ?, ?)",
                arguments: [articleId, json, Date()])
        }
    }
}
