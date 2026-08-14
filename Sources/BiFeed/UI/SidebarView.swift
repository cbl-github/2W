import AppKit
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarSelection?
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: DBObserved<SidebarData>

    // 重命名/新建弹窗状态
    @State private var renamingFeed: Feed?
    @State private var renamingFolder: Folder?
    @State private var renamingSearch: SavedSearch?
    @State private var creatingFolder = false
    @State private var nameDraft = ""
    @State private var readingSettingsFeed: Feed?
    @State private var fetchSettingsFeed: Feed?
    @State private var relocatingFeed: Feed?

    init(selection: Binding<SidebarSelection?>, columnVisibility: Binding<NavigationSplitViewVisibility>) {
        _selection = selection
        _columnVisibility = columnVisibility
        // StateObject 初值在首次 body 前生效；db 经 EnvironmentObject 在 init 拿不到，
        // 所以用全局单例路径初始化一次性观察。见 AppEnvironment.shared 说明。
        _model = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: SidebarData(), fetch: SidebarData.fetch))
    }

    private var smartItems: [(selection: SidebarSelection, title: String, icon: String, badge: Int)] {
        [
            (.today, "今天", "sun.max", model.value.todayCount),
            (.starred, "星标", "star", model.value.starredCount),
            (.muted, "已静音", "speaker.slash", model.value.mutedCount),
            (.all, "全部文章", "tray.full", model.value.totalUnread),
        ]
    }

    var body: some View {
        List(selection: $selection) {
            // 智能区增加“已静音”，作为检查误伤与放行的固定出口。
            // 「未读」不占侧栏行，走列表工具栏的未读按钮。
            // 必须用 ForEach 提供行：List 的选中与高亮对 Section 静态行不完整生效
            //（智能行"点了没反馈"的根因），ForEach + tag 才是原生路径。
            Section("智能") {
                ForEach(smartItems, id: \.selection) { item in
                    Label(item.title, systemImage: item.icon)
                        .badge(badgeText(item.badge))
                        .tag(item.selection)
                }
            }
            savedSearchSection
            folderSection
            if !model.value.feedsWithoutFolder.isEmpty {
                Section("订阅") {
                    ForEach(model.value.feedsWithoutFolder) { feed in
                        feedRow(feed)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("2W")
        // 系统侧栏按钮带动画，动画期间 WKWebView 逐帧重排在 Intel 上卡成幻灯片；
        // 摘掉系统按钮，换无动画的瞬时切换
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = columnVisibility == .all ? .doubleColumn : .all
                } label: {
                    Label("收起/展开侧栏", systemImage: "sidebar.left")
                }
                .help("收起/展开侧栏")
            }
            ToolbarItem {
                if env.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await env.scheduler.refreshAll() }
                    } label: {
                        Label("刷新全部", systemImage: "arrow.clockwise")
                    }
                    .help("刷新全部 (⌘R)")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .alert("重命名订阅", isPresented: .constant(renamingFeed != nil)) {
            TextField("名称", text: $nameDraft)
            Button("取消", role: .cancel) { renamingFeed = nil }
            Button("确定") {
                if let f = renamingFeed, let id = f.id, !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in try await db.renameFeed(id: id, to: self.nameDraft) }
                }
                renamingFeed = nil
            }
        }
        .alert("重命名分组", isPresented: .constant(renamingFolder != nil)) {
            TextField("名称", text: $nameDraft)
            Button("取消", role: .cancel) { renamingFolder = nil }
            Button("确定") {
                if let f = renamingFolder, let id = f.id, !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in try await db.renameFolder(id: id, to: self.nameDraft) }
                }
                renamingFolder = nil
            }
        }
        .alert("重命名搜索", isPresented: .constant(renamingSearch != nil)) {
            TextField("名称", text: $nameDraft)
            Button("取消", role: .cancel) { renamingSearch = nil }
            Button("确定") {
                if let s = renamingSearch, let id = s.id, !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in
                        try await SavedSearches.rename(db, id: id, to: self.nameDraft)
                    }
                }
                renamingSearch = nil
            }
        }
        .alert("新建分组", isPresented: $creatingFolder) {
            TextField("分组名", text: $nameDraft)
            Button("取消", role: .cancel) {}
            Button("创建") {
                if !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in _ = try await db.addFolder(name: self.nameDraft) }
                }
            }
        }
        .sheet(item: $readingSettingsFeed) { feed in
            FeedReadingSettings(feed: feed) { draft in
                readingSettingsFeed = nil
                env.dbWrite { [db = env.db] in
                    try await db.setFullTextPolicy(
                        feedId: feed.id!, mode: draft.mode, selector: draft.selector)
                    try await db.setUnreadBadge(feedId: feed.id!, draft.showsUnreadBadge)
                    try await db.setRetention(
                        feedId: feed.id!, keepCount: draft.keepCount, keepDays: draft.keepDays)
                    try await db.setFilterShorts(feedId: feed.id!, draft.filterShorts)
                }
            }
        }
        .sheet(item: $relocatingFeed) { feed in
            FeedRelocationSheet(feed: feed, fetcher: env.fetcher) { newURL in
                relocatingFeed = nil
                // 改址与随后的刷新必须有序：dbWrite 是即发即忘，先刷新会读到旧地址
                Task {
                    try? await env.db.relocateFeed(id: feed.id!, to: newURL.absoluteString)
                    await env.scheduler.refresh(feedId: feed.id!)
                }
            }
        }
        .sheet(item: $fetchSettingsFeed) { feed in
            FeedFetchSettings(feed: feed) { draft in
                fetchSettingsFeed = nil
                // 密码只走钥匙串；没有用户名 = 关认证，空串即删条目
                KeychainStore.set(account: KeychainStore.basicAccount(feedId: feed.id!),
                                  value: draft.basicUser == nil ? "" : draft.basicPassword)
                env.dbWrite { [db = env.db] in
                    try await db.setFetchConfig(
                        feedId: feed.id!, userAgent: draft.userAgent,
                        basicUser: draft.basicUser, refreshMinutes: draft.refreshMinutes)
                }
            }
        }
    }

    /// 保存的搜索：与智能行同一层级，点开即带着词和范围回到列表。
    @ViewBuilder
    private var savedSearchSection: some View {
        if !model.value.savedSearches.isEmpty {
            Section("保存的搜索") {
                ForEach(model.value.savedSearches) { saved in
                    Label(saved.name, systemImage: "magnifyingglass")
                        .tag(SidebarSelection.savedSearch(saved.id!))
                        .selectableRow(.savedSearch(saved.id!), selection: $selection)
                        .contextMenu {
                            Button("重命名…") {
                                nameDraft = saved.name
                                renamingSearch = saved
                            }
                            Button("删除", role: .destructive) {
                                env.dbWrite { [db = env.db] in
                                    try await SavedSearches.delete(db, id: saved.id!)
                                }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        if !model.value.folders.isEmpty {
            Section("分组") {
                ForEach(model.value.folders) { folder in
                    DisclosureGroup {
                        ForEach(model.value.feeds(inFolder: folder.id!)) { feed in
                            feedRow(feed)
                        }
                    } label: {
                        folderRow(folder)
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        Label(folder.name, systemImage: "folder")
            .badge(badgeText(model.value.unreadBadge(inFolder: folder.id!)))
            .tag(SidebarSelection.folder(folder.id!))
            .selectableRow(.folder(folder.id!), selection: $selection)
            .contextMenu { folderMenu(folder) }
            // 拖一个订阅丢到分组名上 = 移入该组（Paul：整理要顺手）
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first,
                      let feedId = Int64(payload.dropFirst("feed:".count)),
                      payload.hasPrefix("feed:") else { return false }
                env.dbWrite { [db = env.db] in
                    try await db.moveFeed(id: feedId, toFolder: folder.id)
                }
                return true
            }
    }

    private var bottomBar: some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            // 邮件式加号：一个 + 菜单选加什么（Paul 指定，照 Mail 的 + ˅，纯图标无文字）。
            // .borderlessButton 样式配 Label 点击区域会失灵（实测点不动），用 .button + 无边框按钮样式。
            Menu {
                Button("添加订阅…") { env.showAddFeed = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("新建分组…") {
                    nameDraft = ""
                    creatingFolder = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: DesignTokens.Icon.sidebar, weight: .medium))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.visible)
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.xs)
            .help("添加订阅或分组")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: DesignTokens.Icon.sidebar))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(DesignTokens.Spacing.md)
            .help("设置 (⌘,)")
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// 角标走 Text 重载而非 Int：数字要 .monospacedDigit()（竞品报告 V4）。
    /// 0 显式传 nil，保持 Int 重载「0 不显示」的行为。
    private func badgeText(_ count: Int) -> Text? {
        count > 0 ? Text(verbatim: "\(count)").monospacedDigit() : nil
    }

    @ViewBuilder
    private func feedRow(_ feed: Feed) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Label {
                Text(feed.title).lineLimit(1)
            } icon: {
                FeedIcon(feed: feed, size: 16)
            }
            if feed.isHardErrored, let status = feed.lastHTTPStatus {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: DesignTokens.Icon.status))
                    .foregroundStyle(.red)
                    .help("HTTP \(status)，已停止自动重试；右键手动刷新可重试")
            } else if let next = feed.nextFetchAt, next > Date() {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: DesignTokens.Icon.status))
                    .foregroundStyle(.orange)
                    .help("暂缓到 \(next.formatted(date: .omitted, time: .shortened))：\(feed.fetchError ?? "抓取失败")")
            } else if feed.fetchError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: DesignTokens.Icon.status))
                    .foregroundStyle(.orange)
                    .help(feed.fetchError ?? "")
            } else if let days = model.value.staleDays(for: feed) {
                // 抓得通只是没新东西：不标红，只标注（需求 7 第三级）
                Image(systemName: "clock")
                    .font(.system(size: DesignTokens.Icon.status))
                    .foregroundStyle(.tertiary)
                    .help("最后更新于 \(days) 天前")
            }
        }
        .badge(badgeText(model.value.unreadBadge(for: feed)))
        .tag(SidebarSelection.feed(feed.id!))
        .selectableRow(.feed(feed.id!), selection: $selection)
        .draggable("feed:\(feed.id!)") {
            Label(feed.title, systemImage: "dot.radiowaves.up.forward")
                .padding(6)
        }
        .contextMenu { feedMenu(feed) }
    }

    @ViewBuilder
    private func feedMenu(_ feed: Feed) -> some View {
        Button("刷新此源") {
            Task { await env.scheduler.refresh(feedId: feed.id!) }
        }
        Button("标记全部已读") {
            env.markAllRead(scope: .feed(feed.id!))
        }
        Divider()
        Button("阅读设置…") {
            readingSettingsFeed = feed
        }
        Button("抓取设置…") {
            fetchSettingsFeed = feed
        }
        // 只有硬错误的源才谈得上改址；其它情况这一项不出现
        if feed.isHardErrored {
            Button("查找新地址…") { relocatingFeed = feed }
        }
        if let site = feed.siteURL, let url = URL(string: site) {
            Button("打开网站") { NSWorkspace.shared.open(url) }
        }
        Button("复制 Feed 链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(feed.url, forType: .string)
        }
        Divider()
        Button("重命名…") {
            nameDraft = feed.title
            renamingFeed = feed
        }
        Menu("移动到分组") {
            // 启发式建议置顶（同域跟随/组名关键词），只是建议，动手的还是用户
            if let suggested = FeedOrganizer.suggestFolder(
                for: feed, folders: model.value.folders, feeds: model.value.feeds) {
                Button("\(suggested.name)（建议）") {
                    env.dbWrite { [db = env.db] in try await db.moveFeed(id: feed.id!, toFolder: suggested.id) }
                }
                Divider()
            }
            Button("无分组") {
                env.dbWrite { [db = env.db] in try await db.moveFeed(id: feed.id!, toFolder: nil) }
            }
            ForEach(model.value.folders) { folder in
                Button(folder.name) {
                    env.dbWrite { [db = env.db] in try await db.moveFeed(id: feed.id!, toFolder: folder.id) }
                }
            }
        }
        Divider()
        Button("退订", role: .destructive) {
            env.dbWrite { [db = env.db] in try await db.deleteFeed(id: feed.id!) }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("标记全部已读") {
            env.markAllRead(scope: .folder(folder.id!))
        }
        Button(folder.showsUnreadBadge ? "关闭未读徽标" : "开启未读徽标") {
            env.dbWrite { [db = env.db] in
                try await db.setUnreadBadge(folderId: folder.id!, !folder.showsUnreadBadge)
            }
        }
        Button("重命名…") {
            nameDraft = folder.name
            renamingFolder = folder
        }
        Button("删除分组", role: .destructive) {
            env.dbWrite { [db = env.db] in try await db.deleteFolder(id: folder.id!) }
        }
    }
}

/// 源级阅读设置的一次提交：全文策略 + 未读徽标 + 保留覆盖 + YouTube 的 Shorts 过滤。
struct FeedReadingDraft {
    var mode: FullTextMode
    var selector: String?
    var showsUnreadBadge: Bool
    /// nil = 跟随全局设置
    var keepCount: Int?
    var keepDays: Int?
    var filterShorts: Bool
}

private struct FeedReadingSettings: View {
    let feed: Feed
    let onSave: (FeedReadingDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: FullTextMode
    @State private var selector: String
    @State private var showsUnreadBadge: Bool
    /// -1 = 跟随全局；Picker 用一个哨兵值比多带一个 Toggle 少一层状态
    @State private var keepCount: Int
    @State private var keepDays: Int
    @State private var filterShorts: Bool

    private static let followsGlobal = -1

    init(feed: Feed, onSave: @escaping (FeedReadingDraft) -> Void) {
        self.feed = feed
        self.onSave = onSave
        _mode = State(initialValue: feed.fullTextMode)
        _selector = State(initialValue: feed.fullTextSelector ?? "")
        _showsUnreadBadge = State(initialValue: feed.showsUnreadBadge)
        _keepCount = State(initialValue: feed.keepCount ?? Self.followsGlobal)
        _keepDays = State(initialValue: feed.keepDays ?? Self.followsGlobal)
        _filterShorts = State(initialValue: feed.filterShorts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("全文") {
                    Picker("策略", selection: $mode) {
                        ForEach(FullTextMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(modeDescription)
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section("CSS 选择器（可选）") {
                    TextField("例如 article .post-content", text: $selector)
                        .disabled(mode == .never)
                    Text("填写后优先提取匹配区域；不匹配时会显示具体失败原因。")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section("未读") {
                    Toggle("在侧栏显示未读数", isOn: $showsUnreadBadge)
                    Text("关闭后此源不计入任何未读徽标；文章照常进列表。")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section("保留（覆盖全局设置）") {
                    Picker("保留条数", selection: $keepCount) {
                        Text("跟随全局").tag(Self.followsGlobal)
                        ForEach([50, 100, 200, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("保留时间", selection: $keepDays) {
                        Text("跟随全局").tag(Self.followsGlobal)
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("一年").tag(365)
                        Text("永久").tag(0)
                    }
                    Text("星标文章永远不会被清理。")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                youtubeSection
            }
            .formStyle(.grouped)
            .navigationTitle(feed.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(FeedReadingDraft(
                            mode: mode, selector: selector, showsUnreadBadge: showsUnreadBadge,
                            keepCount: keepCount == Self.followsGlobal ? nil : keepCount,
                            keepDays: keepDays == Self.followsGlobal ? nil : keepDays,
                            filterShorts: filterShorts))
                    }
                }
            }
        }
        .frame(width: 440, height: 520)
    }

    /// 只对 YouTube 官方 feed 显示（需求 18）。单独拆出来是为了别把 body 撑到类型检查超时。
    @ViewBuilder
    private var youtubeSection: some View {
        if YouTube.isFeedURL(feed.url) {
            Section("YouTube") {
                Toggle("过滤 Shorts", isOn: $filterShorts)
                Text("开启后新抓到的 Shorts 视频不入库；已入库的条目不受影响。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Text("YouTube 官方 feed 只提供最近 15 条视频。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeDescription: String {
        switch mode {
        case .auto: "检测到 feed 只给一段摘要时，在打开文章后抓取全文。"
        case .always: "打开文章时总是尝试从原站提取全文。"
        case .never: "只显示 feed 自带正文，不访问原站抓取全文。"
        }
    }
}

/// 死源改址（需求 7 第二级）：查到的新地址列出来，选一个替换。
/// 只在用户点「查找新地址…」时跑一次，不做后台自动探测。
private struct FeedRelocationSheet: View {
    let feed: Feed
    let fetcher: FeedFetcher
    let onReplace: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [FeedCandidate] = []
    @State private var picked: URL?
    @State private var searching = true

    var body: some View {
        NavigationStack {
            Form {
                Section("当前地址") {
                    Text(feed.url)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Section("新地址") {
                    if searching {
                        HStack(spacing: DesignTokens.Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text("正在从站点页面查找…")
                        }
                    } else if candidates.isEmpty {
                        Text("没有发现新地址")
                    } else {
                        Picker("", selection: $picked) {
                            ForEach(candidates) { candidate in
                                Text("\(candidate.title)\n\(candidate.url.absoluteString)")
                                    .tag(Optional(candidate.url))
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(feed.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("替换") { if let picked { onReplace(picked) } }
                        .disabled(picked == nil)
                }
            }
        }
        .frame(width: 440, height: 320)
        .task {
            candidates = await SubscribeResolver.relocations(for: feed, fetcher: fetcher)
            picked = candidates.first?.url
            searching = false
        }
    }
}

/// 源级抓取设置的一次提交。basicUser 为 nil = 关闭认证（此时 basicPassword 无意义）。
struct FeedFetchDraft {
    var refreshMinutes: Int?
    var userAgent: String?
    var basicUser: String?
    var basicPassword: String
}

private struct FeedFetchSettings: View {
    let feed: Feed
    let onSave: (FeedFetchDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    /// -1 = 跟随全局，与 FeedReadingSettings 用同一套哨兵约定
    @State private var refreshMinutes: Int
    @State private var userAgent: String
    @State private var basicUser: String
    @State private var basicPassword: String

    private static let followsGlobal = -1

    init(feed: Feed, onSave: @escaping (FeedFetchDraft) -> Void) {
        self.feed = feed
        self.onSave = onSave
        _refreshMinutes = State(initialValue: feed.refreshMinutes ?? Self.followsGlobal)
        _userAgent = State(initialValue: feed.userAgent ?? "")
        _basicUser = State(initialValue: feed.basicUser ?? "")
        // 回填已存的密码，否则"只改 UA"会把认证顺手清掉
        _basicPassword = State(
            initialValue: feed.id.map { KeychainStore.get(account: KeychainStore.basicAccount(feedId: $0)) ?? "" } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("刷新") {
                    Picker("刷新间隔", selection: $refreshMinutes) {
                        Text("跟随全局").tag(Self.followsGlobal)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                        Text("2 小时").tag(120)
                    }
                    Text("覆盖设置里的全局间隔，只影响这个源的自动刷新。")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section("User-Agent（可选）") {
                    TextField("留空使用默认", text: $userAgent)
                    Text("有些站点会按 UA 拒绝请求。示例：Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                         + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section("HTTP Basic 认证") {
                    TextField("用户名", text: $basicUser)
                    SecureField("密码", text: $basicPassword)
                    Text("仅用于需要登录的 feed（如私有 Reddit 源）；密码存本机钥匙串。清空用户名即关闭认证。")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(feed.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let user = basicUser.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(FeedFetchDraft(
                            refreshMinutes: refreshMinutes == Self.followsGlobal ? nil : refreshMinutes,
                            userAgent: userAgent,
                            basicUser: user.isEmpty ? nil : user,
                            basicPassword: basicPassword))
                    }
                }
            }
        }
        .frame(width: 440, height: 460)
    }
}

private extension View {
    /// List(selection:) 的 tag 匹配在 Section/DisclosureGroup 组合下偶发失灵（智能行实测点不动），
    /// 显式把点击写进绑定做双保险；高亮仍由 List 按绑定渲染，无视觉差异。
    func selectableRow(_ value: SidebarSelection, selection: Binding<SidebarSelection?>) -> some View {
        contentShape(Rectangle())
            .onTapGesture { selection.wrappedValue = value }
    }
}
