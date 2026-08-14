import Foundation

enum SubscribeError: LocalizedError {
    case noFeedFound
    var errorDescription: String? {
        switch self {
        case .noFeedFound: return "这个地址里没有发现 feed"
        }
    }
}

enum SubscribeResolution {
    case feed(url: URL, parsed: ParsedFeed)
    /// 页面声明了两个以上 feed，交给用户勾选（需求 17）。
    case candidates([FeedCandidate])
}

/// 需求 1、17：输入任意 URL → 订阅。
/// feed URL 直接解析；网页 URL 扫 `<link rel="alternate">`，多个候选交给用户选，
/// 一个候选直接订阅，无声明再按常见路径探测。
enum SubscribeResolver {
    /// 无声明时按此顺序探测，相对站点根。顺序即优先级，不重排。
    static let probePaths = [
        "/feed", "/rss", "/atom.xml", "/index.xml", "/feed.json", "/rss/", "?feed=rss2",
    ]

    static func probeURLs(for pageURL: URL) -> [URL] {
        guard let root = URL(string: "/", relativeTo: pageURL)?.absoluteURL else { return [] }
        return probePaths.compactMap { URL(string: $0, relativeTo: root)?.absoluteURL }
    }

    static func resolve(_ input: String, fetcher: FeedFetcher) async throws -> SubscribeResolution {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // YouTube 频道地址（需求 18）：先换成官方 feed 地址，再走普通解析
        if let target = YouTube.channelTarget(text) {
            let hit = try await fetchFeed(url: try await youtubeFeedURL(target, fetcher: fetcher),
                                          fetcher: fetcher)
            return .feed(url: hit.url, parsed: hit.parsed)
        }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { throw FetchError.badURL(input) }

        guard case .success(let data, _, _, let charset, let finalURL) = try await fetcher.fetch(url: url) else {
            throw SubscribeError.noFeedFound // 无条件请求不会返回 304
        }
        let decoded = CharsetDecoder.decodeToString(data, httpTextEncodingName: charset)

        if !HTMLTools.looksLikeHTML(decoded) {
            return .feed(url: finalURL, parsed: try parse(decoded, from: finalURL))
        }

        let candidates = HTMLTools.discoverFeeds(html: decoded, base: finalURL)
        if candidates.count > 1 { return .candidates(candidates) }
        if let only = candidates.first {
            let hit = try await fetchFeed(url: only.url, fetcher: fetcher)
            return .feed(url: hit.url, parsed: hit.parsed)
        }

        // 串行探测，最多 probePaths.count 个请求，失败即换下一个，不重试。
        for probe in probeURLs(for: finalURL) {
            if let hit = try? await fetchFeed(url: probe, fetcher: fetcher) {
                return .feed(url: hit.url, parsed: hit.parsed)
            }
        }
        throw SubscribeError.noFeedFound
    }

    /// 死源改址发现（需求 7 第二级）：从站点页面找这个源的新地址。
    /// 只由用户手动触发，不做后台自动探测。返回的候选都已验证能解析，且不等于当前地址。
    static func relocations(for feed: Feed, fetcher: FeedFetcher) async -> [FeedCandidate] {
        guard let current = URL(string: feed.url) else { return [] }
        // 没记站点地址就退到 feed URL 的站点根——死源的页面本身常常也一起没了
        guard let page = feed.siteURL.flatMap({ URL(string: $0) })
            ?? URL(string: "/", relativeTo: current)?.absoluteURL else { return [] }

        var declared: [FeedCandidate] = []
        if case .success(let data, _, _, let charset, let finalURL)? =
            try? await fetcher.fetch(url: page) {
            let decoded = CharsetDecoder.decodeToString(data, httpTextEncodingName: charset)
            declared = HTMLTools.discoverFeeds(html: decoded, base: finalURL)
        }
        // 有声明就全部验证列给用户选；无声明才按常见路径探测，且探到一个就停（探测最多 7 个请求）
        let probing = declared.isEmpty
        let pool = probing
            ? probeURLs(for: page).map { FeedCandidate(url: $0, title: $0.absoluteString) }
            : declared

        var found: [FeedCandidate] = []
        var seen = Set([current.absoluteString])
        for candidate in pool where !seen.contains(candidate.url.absoluteString) {
            guard let hit = try? await fetchFeed(url: candidate.url, fetcher: fetcher),
                  seen.insert(hit.url.absoluteString).inserted else { continue }
            found.append(FeedCandidate(url: hit.url, title: hit.parsed.title))
            if probing { break }
        }
        return found
    }

    /// @handle 与 /c/xxx 拼不出 channel_id，要抓频道页 HTML 找；抓不到或找不到都按「没有发现 feed」报。
    private static func youtubeFeedURL(_ target: YouTube.ChannelTarget,
                                       fetcher: FeedFetcher) async throws -> URL {
        switch target {
        case .feed(let url):
            return url
        case .page(let url):
            guard case .success(let data, _, _, let charset, _)? = try? await fetcher.fetch(url: url),
                  let id = YouTube.channelID(
                      inHTML: CharsetDecoder.decodeToString(data, httpTextEncodingName: charset)),
                  let feed = YouTube.feedURL(channelID: id) else { throw SubscribeError.noFeedFound }
            return feed
        }
    }

    /// 抓一个必须是 feed 的地址：返回 HTML 或解析不了都算没找到。
    static func fetchFeed(url: URL, fetcher: FeedFetcher) async throws -> (url: URL, parsed: ParsedFeed) {
        guard case .success(let data, _, _, let charset, let finalURL) = try await fetcher.fetch(url: url) else {
            throw SubscribeError.noFeedFound
        }
        let decoded = CharsetDecoder.decodeToString(data, httpTextEncodingName: charset)
        guard !HTMLTools.looksLikeHTML(decoded) else { throw SubscribeError.noFeedFound }
        return (finalURL, try parse(decoded, from: finalURL))
    }

    private static func parse(_ decoded: String, from url: URL) throws -> ParsedFeed {
        try FeedParsing.parse(
            data: Data(CharsetDecoder.normalizeXMLDeclaration(decoded).utf8),
            fallbackTitle: url.host() ?? url.absoluteString)
    }
}
