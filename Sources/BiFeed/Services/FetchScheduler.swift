import CryptoKit
import Foundation

enum SettingsKey {
    static let refreshMinutes = "refreshMinutes" // 没有按源覆盖时的默认间隔，默认 30
    static let domainMinIntervalSeconds = "domainMinIntervalSeconds" // 同域两次请求最小间隔秒数，0 = 关闭
    static let keepCount = "keepCount"           // 每源保留条数，默认 500
    static let keepDays = "keepDays"             // 保留天数，0 = 不限，默认 90

    static let articleFontSize = "articleFontSize" // 正文字号 px，默认 17.5

    static let readFilter = "readFilter" // 列表过滤："all" | "unread" | "starred"，默认 "all"

    static let markReadOnOpen = "markReadOnOpen"           // 打开即已读，默认 true
    static let markReadOnScrollEnd = "markReadOnScrollEnd" // 滚动到底已读，默认 false
    static let newFeedInitialRead = "newFeedInitialRead"   // "unread" | "read" | "recent"，默认 "unread"
    static let newFeedRecentCount = "newFeedRecentCount"   // recent 模式保留未读的条数，默认 10
    static let defaultFullTextMode = "defaultFullTextMode" // 新增订阅的全文策略，FullTextMode 原始值，默认 "auto"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshMinutes: 30,
            domainMinIntervalSeconds: 0,
            keepCount: 500,
            keepDays: 90,
            articleFontSize: 17.5,
            readFilter: "all",
            markReadOnOpen: true,
            markReadOnScrollEnd: false,
            newFeedInitialRead: "unread",
            newFeedRecentCount: 10,
            defaultFullTextMode: "auto",
        ])
    }
}

/// 新增订阅首批文章的已读策略。只在该源第一次抓取成功时生效。
enum InitialReadPolicy: Equatable, Sendable {
    case allUnread
    case allRead
    case keepRecent(Int)

    static func current(_ defaults: UserDefaults = .standard) -> InitialReadPolicy {
        switch defaults.string(forKey: SettingsKey.newFeedInitialRead) ?? "unread" {
        case "read": .allRead
        case "recent": .keepRecent(max(1, defaults.integer(forKey: SettingsKey.newFeedRecentCount)))
        default: .allUnread
        }
    }
}

/// 抓取失败的处置：硬错误停止自动重试，限流走固定退避不计失败次数，其余指数退避。
enum FetchFailureKind {
    case hard
    case throttled
    case backoff
}

/// 抓取调度。actor 天然串行化状态；单次全量刷新内部并发上限 4（设计文档 §4 机制 5）。
actor FetchScheduler {
    private let db: AppDatabase
    private let fetcher: FeedFetcher
    private let onRefreshingChange: @Sendable (Bool) -> Void
    /// 首批已读策略在后台刷新里标掉的文章名单，交给调用方挂到「撤销已读」上。
    private let onInitialReadBatch: (@Sendable ([Int64]) -> Void)?
    private var isRefreshing = false
    private var autoRefreshTask: Task<Void, Never>?

    init(db: AppDatabase, fetcher: FeedFetcher,
         onRefreshingChange: @escaping @Sendable (Bool) -> Void,
         onInitialReadBatch: (@Sendable ([Int64]) -> Void)? = nil) {
        self.db = db
        self.fetcher = fetcher
        self.onRefreshingChange = onRefreshingChange
        self.onInitialReadBatch = onInitialReadBatch
    }

    /// 固定 5 分钟一跳，每跳只刷到期的源——间隔已是按源属性，轮询周期不能再等于任何一个源的间隔。
    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task {
            await refreshAll(manual: false) // 启动即刷一轮，仍只刷到期的
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                await refreshAll(manual: false)
            }
        }
    }

    /// manual = 用户主动刷新（⌘R / 工具栏 / 导入后）：跳过到期判定，全刷。
    func refreshAll(manual: Bool = true) async {
        // 占坑必须在第一个 await 之前：查库期间 actor 会让位，晚占坑就挡不住并发的第二次进入。
        // 转圈图标另算——空跳（没有到期源）不亮，5 分钟一跳才不会每跳闪一下。
        guard !isRefreshing else { return }
        isRefreshing = true
        var spinning = false
        defer {
            isRefreshing = false
            if spinning { onRefreshingChange(false) }
        }
        guard let all = try? await db.feedsForRefresh(), !all.isEmpty else { return }
        // UserDefaults 每轮读一次，不进循环
        let d = UserDefaults.standard
        let globalMinutes = d.integer(forKey: SettingsKey.refreshMinutes)
        let spacing = d.integer(forKey: SettingsKey.domainMinIntervalSeconds)
        let now = Date()
        let feeds = manual ? all : all.filter {
            Self.isDue(lastFetchedAt: $0.lastFetchedAt, feedMinutes: $0.refreshMinutes,
                       globalMinutes: globalMinutes, now: now)
        }
        guard !feeds.isEmpty else { return }

        spinning = true
        onRefreshingChange(true)

        // 同域串行，避免多个订阅同时撞站点限流；不同域仍保留最多 4 路并发。
        await withTaskGroup(of: Void.self) { group in
            var iterator = Self.hostGroups(feeds).makeIterator()
            var inFlight = 0
            while inFlight < 4, let hostFeeds = iterator.next() {
                group.addTask { await self.refreshHostGroup(hostFeeds, spacing: spacing, manual: manual) }
                inFlight += 1
            }
            while await group.next() != nil {
                if let hostFeeds = iterator.next() {
                    group.addTask { await self.refreshHostGroup(hostFeeds, spacing: spacing, manual: manual) }
                }
            }
        }

        try? await db.purge(keepCount: d.integer(forKey: SettingsKey.keepCount),
                            keepDays: d.integer(forKey: SettingsKey.keepDays))

        // 订阅列表是丢了最难重建的东西：每天一份 OPML，失败不影响刷新
        try? await Backup.autoOPML(db)

        // HN 线程预取：把新文章的评论树先拉好落库，用户点开即读缓存（"首开要等一会"的机制解）。
        // 预取失败静默跳过——点开时的按需路径会重试并把错误显示出来，这里不重复报。
        if let candidates = try? await db.hnArticlesNeedingThreadPrefetch(limit: 8) {
            for article in candidates {
                guard let id = article.id,
                      let kind = ForumResolver.forumKind(url: article.url, commentsURL: article.commentsURL)
                else { continue }
                if let thread = try? await ForumResolver.fetch(
                    kind, fetcher: fetcher, articleAuthor: article.author, articleTitle: article.title) {
                    try? await db.storeThread(articleId: id, thread: thread)
                }
            }
        }
    }

    func refresh(feedId: Int64) async {
        guard let feed = try? await db.feed(id: feedId) else { return }
        await refreshOne(feed, manual: true)
    }

    /// 同域组内串行 + 可选间隔。manual 一路透传到 refreshOne：
    /// 用户点「刷新全部」就是要现在全刷一遍，退避和 404/410 只该挡自动轮询。
    /// （曾经这里写死 manual: false，结果退避中的源必须逐个右键刷新，Paul 实测报的 bug。）
    private func refreshHostGroup(_ feeds: [Feed], spacing: Int, manual: Bool) async {
        for (index, feed) in feeds.enumerated() {
            if index > 0, spacing > 0 { try? await Task.sleep(for: .seconds(spacing)) }
            await refreshOne(feed, manual: manual)
        }
    }

    /// 单源刷新。网络失败/解析失败是规格内错误：落到 feed.fetchError 显示，不抛出。
    /// manual = 用户点「刷新此源」：硬错误与退避只挡自动轮询，手动始终执行。
    private func refreshOne(_ feed: Feed, manual: Bool) async {
        // 非 http(s) 的源（手动保存的容器源）永不发请求，见 Feed.isFetchable
        guard let feedId = feed.id, feed.isFetchable, let url = URL(string: feed.url) else { return }
        if Self.shouldSkip(manual: manual, host: url.host(), lastHTTPStatus: feed.lastHTTPStatus,
                           failCount: feed.failCount, nextFetchAt: feed.nextFetchAt) { return }
        do {
            let password = feed.basicUser == nil
                ? nil : KeychainStore.get(account: KeychainStore.basicAccount(feedId: feedId))
            switch try await fetcher.fetch(
                url: url, etag: feed.etag, lastModified: feed.lastModified,
                userAgent: feed.userAgent, basicUser: feed.basicUser, basicPassword: password) {
            case .notModified:
                try await db.applyFetchNotModified(feedId: feedId)
                try await markHealthy(feedId: feedId, bodyHash: feed.bodyHash)
            case .success(let data, let etag, let lastModified, let charset, _):
                let bodyHash = Self.sha256Hex(data)
                if bodyHash == feed.bodyHash {
                    // 内容指纹相同：服务器没发 304 但正文没变，跳过解析，只 touch lastFetchedAt
                    try await db.applyFetchNotModified(feedId: feedId, status: 200)
                } else {
                    let utf8 = CharsetDecoder.decodeToUTF8(data, httpTextEncodingName: charset)
                    let parsed = try FeedParsing.parse(data: utf8, fallbackTitle: feed.title)
                    let rules = try await MuteRules.all(db)
                    let items = Self.dropShorts(parsed.items, enabled: feed.filterShorts)
                    // lastSuccessAt 为空 = 这个源还没成功抓过，本批就是"新增订阅的首批文章"
                    let result = try await db.applyFetchSuccess(
                        feedId: feedId, etag: etag, lastModified: lastModified,
                        items: MuteRules.evaluate(
                            items, feedId: feedId, folderId: feed.folderId, rules: rules),
                        initialPolicy: feed.lastSuccessAt == nil ? InitialReadPolicy.current() : nil)
                    if !result.initialReadIds.isEmpty {
                        onInitialReadBatch?(result.initialReadIds)
                    }
                }
                try await markHealthy(feedId: feedId, bodyHash: bodyHash)
            }
            // 成功后顺手补 favicon：fire-and-forget，不阻塞刷新（store 在 MainActor 上）
            Task { await FaviconStore.shared.ensureIcon(feed: feed, fetcher: self.fetcher) }
        } catch FetchError.status(let code, let retryAfter) {
            // failCount 传"含本次在内"的次数：feed.failCount 是本次失败落库前的值
            let kind = Self.failureKind(host: url.host(), code: code,
                                        failCount: feed.failCount + 1)
            let fallback = code == 429 ? 15.0 * 60 : 60.0 * 60
            let next: Date? = switch kind {
            case .hard: nil
            case .throttled: retryAfter ?? Date().addingTimeInterval(fallback)
            case .backoff: retryAfter ?? Self.retryDate(afterFailureCount: feed.failCount)
            }
            try? await db.applyFetchFailure(
                feedId: feedId, message: "HTTP \(code)", status: code,
                nextFetchAt: next, incrementFailure: kind != .throttled)
        } catch {
            try? await db.applyFetchFailure(
                feedId: feedId, message: error.localizedDescription, status: nil,
                nextFetchAt: Self.retryDate(afterFailureCount: feed.failCount),
                incrementFailure: true)
        }
    }

    /// 成功路径三列（failCount/lastSuccessAt/bodyHash）的落库在这里：
    /// applyFetch* 的实现归 Database.swift，契约没把这三列划给它，用独立 UPDATE 写。
    /// 304 路径传旧 bodyHash（原样重写），200 路径传新指纹。
    private func markHealthy(feedId: Int64, bodyHash: String?) async throws {
        try await db.pool.write { db in
            try db.execute(
                sql: "UPDATE feed SET failCount = 0, lastSuccessAt = ?, bodyHash = ? WHERE id = ?",
                arguments: [Date(), bodyHash, feedId])
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 保持输入顺序的域名分组。URL 异常的源各自成组，避免误串行所有坏地址。
    static func hostGroups(_ feeds: [Feed]) -> [[Feed]] {
        var result: [[Feed]] = []
        var indices: [String: Int] = [:]
        for feed in feeds {
            let key = URL(string: feed.url)?.host()?.lowercased() ?? "invalid:\(feed.url)"
            if let index = indices[key] {
                result[index].append(feed)
            } else {
                indices[key] = result.count
                result.append([feed])
            }
        }
        return result
    }

    /// 自动轮询的到期判定。只看间隔：退避（nextFetchAt）与 404/410 由 refreshOne 另行拦截，两者叠加。
    /// 从没抓过的源永远到期，新订阅不用等一个周期。
    static func isDue(lastFetchedAt: Date?, feedMinutes: Int?, globalMinutes: Int,
                      now: Date = Date()) -> Bool {
        guard let lastFetchedAt else { return true }
        let minutes = max(1, feedMinutes ?? globalMinutes)
        return now.timeIntervalSince(lastFetchedAt) >= Double(minutes) * 60
    }

    /// 入库前丢掉 Shorts（需求 18）。开关关着原样返回；丢弃不是静音——用户要它们不占库存。
    static func dropShorts(_ items: [ParsedItem], enabled: Bool) -> [ParsedItem] {
        enabled ? items.filter { !YouTube.isShorts($0.url) } : items
    }

    /// HTTP 失败分类。failCount = 含本次在内的连续失败次数。
    /// 404/410 一般是源没了，落硬错误停自动重试；但 YouTube 的 feed 接口偶发 404
    /// （RRSS 实测报告），前三次当暂时错误退避重试，连续第 4 次才认。
    static func failureKind(host: String?, code: Int, failCount: Int) -> FetchFailureKind {
        if code == 403 || code == 429 { return .throttled }
        guard code == 404 || code == 410 else { return .backoff }
        if code == 404, host?.lowercased() == "www.youtube.com", failCount < 4 { return .backoff }
        return .hard
    }

    /// 跳过判定。**manual 为真时永远不跳过**——用户点了刷新就是要现在发请求，
    /// 硬错误和退避都只该挡自动轮询。这条不变量被写死的 `manual: false` 破坏过一次，
    /// 所以抽成纯函数并单独立测试。
    static func shouldSkip(manual: Bool, host: String?, lastHTTPStatus: Int?, failCount: Int,
                           nextFetchAt: Date?, now: Date = Date()) -> Bool {
        guard !manual else { return false }
        if let lastHTTPStatus,
           failureKind(host: host, code: lastHTTPStatus, failCount: failCount) == .hard { return true }
        if let nextFetchAt, nextFetchAt > now { return true }
        return false
    }

    /// 暂时错误从 5 分钟开始指数退避，封顶 6 小时。
    static func retryDate(afterFailureCount failureCount: Int, now: Date = Date()) -> Date {
        let delay = min(6.0 * 3600, 5.0 * 60 * pow(2, Double(min(failureCount, 7))))
        return now.addingTimeInterval(delay)
    }
}
