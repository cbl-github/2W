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
    @State private var reloadingFeed: Feed?

    init(selection: Binding<SidebarSelection?>, columnVisibility: Binding<NavigationSplitViewVisibility>) {
        _selection = selection
        _columnVisibility = columnVisibility
        // StateObject 初值在首次 body 前生效；db 经 EnvironmentObject 在 init 拿不到，
        // 所以用全局单例路径初始化一次性观察。见 AppEnvironment.shared 说明。
        _model = StateObject(wrappedValue: DBObserved(
            db: AppEnvironment.sharedDB,
            initial: SidebarData(),
            fetch: SidebarData.fetch
        ))
    }

    private var smartItems: [(selection: SidebarSelection, title: String, icon: String, badge: Int)] {
        [
            (.today, L("sidebar.smart.today"), "sun.max", model.value.todayCount),
            (.starred, L("sidebar.smart.starred"), "star", model.value.starredCount),
            (.muted, L("sidebar.smart.muted"), "speaker.slash", model.value.mutedCount),
            (.all, L("sidebar.smart.all"), "tray.full", model.value.totalUnread),
        ]
    }

    var body: some View {
        List(selection: $selection) {
            // 智能区增加“已静音”，作为检查误伤与放行的固定出口。
            // 「未读」不占侧栏行，走列表工具栏的未读按钮。
            // 必须用 ForEach 提供行：List 的选中与高亮对 Section 静态行不完整生效
            //（智能行"点了没反馈"的根因），ForEach + tag 才是原生路径。
            Section(L("sidebar.section.smart")) {
                ForEach(smartItems, id: \.selection) { item in
                    Label(item.title, systemImage: item.icon)
                        .badge(badgeText(item.badge))
                        .tag(item.selection)
                }
            }
            savedSearchSection
            folderSection
            if !model.value.feedsWithoutFolder.isEmpty {
                Section(L("common.feeds")) {
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
                    Label(L("sidebar.toolbar.toggleSidebar"), systemImage: "sidebar.left")
                }
                .help(L("sidebar.toolbar.toggleSidebar"))
            }
            ToolbarItem {
                if env.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await env.scheduler.refreshAll() }
                    } label: {
                        Label(L("sidebar.toolbar.refreshAll"), systemImage: "arrow.clockwise")
                    }
                    .help(L("sidebar.toolbar.refreshAll.help"))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .alert(L("feed.rename.title"), isPresented: .constant(renamingFeed != nil)) {
            TextField(L("common.name"), text: $nameDraft)
            Button(L("common.cancel"), role: .cancel) { renamingFeed = nil }
            Button(L("common.confirm")) {
                if let f = renamingFeed, let id = f.id, !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in try await db.renameFeed(id: id, to: self.nameDraft) }
                }
                renamingFeed = nil
            }
        }
        .alert(L("sidebar.folder.rename.title"), isPresented: .constant(renamingFolder != nil)) {
            TextField(L("common.name"), text: $nameDraft)
            Button(L("common.cancel"), role: .cancel) { renamingFolder = nil }
            Button(L("common.confirm")) {
                if let f = renamingFolder, let id = f.id, !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in try await db.renameFolder(id: id, to: self.nameDraft) }
                }
                renamingFolder = nil
            }
        }
        .alert(L("search.rename.title"), isPresented: .constant(renamingSearch != nil)) {
            TextField(L("common.name"), text: $nameDraft)
            Button(L("common.cancel"), role: .cancel) { renamingSearch = nil }
            Button(L("common.confirm")) {
                if let s = renamingSearch, let id = s.id, !nameDraft.isEmpty {
                    env.dbWrite { [db = env.db] in
                        try await SavedSearches.rename(db, id: id, to: self.nameDraft)
                    }
                }
                renamingSearch = nil
            }
        }
        .alert(L("sidebar.folder.new.title"), isPresented: $creatingFolder) {
            TextField(L("sidebar.folder.new.namePlaceholder"), text: $nameDraft)
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("sidebar.folder.new.create")) {
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
                    try await db.setAutoTranslate(feedId: feed.id!, draft.autoTranslate)
                }
            }
        }
        .alert(L("feed.reload.title"), isPresented: .constant(reloadingFeed != nil)) {
            Button(L("common.cancel"), role: .cancel) { reloadingFeed = nil }
            Button(L("feed.reload.title"), role: .destructive) {
                guard let feed = reloadingFeed, let id = feed.id else { return }
                reloadingFeed = nil
                Task {
                    try? await env.db.clearArticles(feedId: id)
                    try? await env.db.resetFetchState(feedId: id)
                    await env.scheduler.refresh(feedId: id)
                }
            }
        } message: {
            Text(L("feed.reload.message", reloadingFeed?.title ?? ""))
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
            Section(L("sidebar.section.savedSearches")) {
                ForEach(model.value.savedSearches) { saved in
                    Label(saved.name, systemImage: "magnifyingglass")
                        .tag(SidebarSelection.savedSearch(saved.id!))
                        .selectableRow(.savedSearch(saved.id!), selection: $selection)
                        .contextMenu {
                            Button(L("common.rename")) {
                                nameDraft = saved.name
                                renamingSearch = saved
                            }
                            Button(L("common.delete"), role: .destructive) {
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
            Section(L("common.folders")) {
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
                Button(L("feed.add.menu")) { env.showAddFeed = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button(L("sidebar.folder.new.menu")) {
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
            .help(L("sidebar.bottomBar.add.help"))
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: DesignTokens.Icon.sidebar))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(DesignTokens.Spacing.md)
            .help(L("sidebar.bottomBar.settings.help"))
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
                    .help(L("sidebar.feed.hardError.help", status))
            } else if let next = feed.nextFetchAt, next > Date() {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: DesignTokens.Icon.status))
                    .foregroundStyle(.orange)
                    .help(L(
                        "sidebar.feed.deferred.help",
                        next.formatted(date: .omitted, time: .shortened),
                        feed.fetchError ?? L("sidebar.feed.fetchFailed")
                    ))
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
                    .help(L("sidebar.feed.stale.help", days))
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
        Button(L("feed.menu.refresh")) {
            Task { await env.scheduler.refresh(feedId: feed.id!) }
        }
        // 重新载入 = 丢掉条件请求头与内容指纹再抓，服务器一定给全量。
        // 「刷新此源」在 feed 内容没变时会被 304 或指纹短路，改完全文策略、
        // 或者怀疑正文抓错了的时候，需要的是这个而不是刷新。
        Button(L("feed.menu.reloadFetchState")) {
            Task {
                try? await env.db.resetFetchState(feedId: feed.id!)
                await env.scheduler.refresh(feedId: feed.id!)
            }
        }
        Button(L("feed.menu.clearAndReload")) { reloadingFeed = feed }
        Button(L("common.markAllRead")) {
            env.markAllRead(scope: .feed(feed.id!))
        }
        Divider()
        Button(L("feed.menu.readingSettings")) {
            readingSettingsFeed = feed
        }
        Button(L("feed.menu.fetchSettings")) {
            fetchSettingsFeed = feed
        }
        // 只有硬错误的源才谈得上改址；其它情况这一项不出现
        if feed.isHardErrored {
            Button(L("feed.menu.relocate")) { relocatingFeed = feed }
        }
        if let site = feed.siteURL, let url = URL(string: site) {
            Button(L("feed.menu.openSite")) { NSWorkspace.shared.open(url) }
        }
        Button(L("feed.menu.copyURL")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(feed.url, forType: .string)
        }
        Divider()
        Button(L("common.rename")) {
            nameDraft = feed.title
            renamingFeed = feed
        }
        Menu(L("feed.menu.moveToFolder")) {
            // 启发式建议置顶（同域跟随/组名关键词），只是建议，动手的还是用户
            if let suggested = FeedOrganizer.suggestFolder(
                for: feed, folders: model.value.folders, feeds: model.value.feeds) {
                Button(L("feed.menu.folderSuggested", suggested.name)) {
                    env.dbWrite { [db = env.db] in try await db.moveFeed(id: feed.id!, toFolder: suggested.id) }
                }
                Divider()
            }
            Button(L("common.noFolder")) {
                env.dbWrite { [db = env.db] in try await db.moveFeed(id: feed.id!, toFolder: nil) }
            }
            ForEach(model.value.folders) { folder in
                Button(folder.name) {
                    env.dbWrite { [db = env.db] in try await db.moveFeed(id: feed.id!, toFolder: folder.id) }
                }
            }
        }
        Divider()
        Button(L("common.unsubscribe"), role: .destructive) {
            env.dbWrite { [db = env.db] in try await db.deleteFeed(id: feed.id!) }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button(L("common.markAllRead")) {
            env.markAllRead(scope: .folder(folder.id!))
        }
        Button(folder.showsUnreadBadge ? L("sidebar.folder.menu.hideBadge") : L("sidebar.folder.menu.showBadge")) {
            env.dbWrite { [db = env.db] in
                try await db.setUnreadBadge(folderId: folder.id!, !folder.showsUnreadBadge)
            }
        }
        Button(L("common.rename")) {
            nameDraft = folder.name
            renamingFolder = folder
        }
        Button(L("sidebar.folder.menu.delete"), role: .destructive) {
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
    var autoTranslate: AutoTranslateMode
}

private struct FeedReadingSettings: View {
    let feed: Feed
    let onSave: (FeedReadingDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: FullTextMode
    @State private var selector: String
    @State private var showsUnreadBadge: Bool
    @State private var autoTranslate: AutoTranslateMode
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
        _autoTranslate = State(initialValue: feed.autoTranslateMode)
        _keepCount = State(initialValue: feed.keepCount ?? Self.followsGlobal)
        _keepDays = State(initialValue: feed.keepDays ?? Self.followsGlobal)
        _filterShorts = State(initialValue: feed.filterShorts)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("feed.reading.fullText")) {
                    Picker(L("feed.reading.fullText.mode"), selection: $mode) {
                        ForEach(FullTextMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(modeDescription)
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("feed.reading.selector")) {
                    TextField(L("feed.reading.selector.placeholder"), text: $selector)
                        .disabled(mode == .never)
                    Text(L("feed.reading.selector.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("feed.reading.autoTranslate")) {
                    Picker(L("feed.reading.autoTranslate"), selection: $autoTranslate) {
                        ForEach(AutoTranslateMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Text(L("feed.reading.autoTranslate.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("feed.reading.unread")) {
                    Toggle(L("feed.reading.unread.badge"), isOn: $showsUnreadBadge)
                    Text(L("feed.reading.unread.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("feed.reading.retention")) {
                    Picker(L("feed.reading.retention.count"), selection: $keepCount) {
                        Text(L("common.followGlobal")).tag(Self.followsGlobal)
                        ForEach([50, 100, 200, 500, 1000, 2000], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker(L("feed.reading.retention.days"), selection: $keepDays) {
                        Text(L("common.followGlobal")).tag(Self.followsGlobal)
                        Text(L("settings.retention.days.7")).tag(7)
                        Text(L("settings.retention.days.30")).tag(30)
                        Text(L("settings.retention.days.90")).tag(90)
                        Text(L("settings.retention.days.365")).tag(365)
                        Text(L("settings.retention.days.forever")).tag(0)
                    }
                    Text(L("feed.reading.retention.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                youtubeSection
            }
            .formStyle(.grouped)
            .navigationTitle(feed.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
                        onSave(FeedReadingDraft(
                            mode: mode, selector: selector, showsUnreadBadge: showsUnreadBadge,
                            keepCount: keepCount == Self.followsGlobal ? nil : keepCount,
                            keepDays: keepDays == Self.followsGlobal ? nil : keepDays,
                            filterShorts: filterShorts,
                            autoTranslate: autoTranslate))
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
                Toggle(L("feed.reading.youtube.filterShorts"), isOn: $filterShorts)
                Text(L("feed.reading.youtube.filterShorts.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Text(L("feed.reading.youtube.limit.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var modeDescription: String {
        switch mode {
        case .auto: L("feed.reading.fullText.mode.auto.note")
        case .always: L("feed.reading.fullText.mode.always.note")
        case .never: L("feed.reading.fullText.mode.never.note")
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
                Section(L("feed.relocate.current")) {
                    Text(feed.url)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Section(L("feed.relocate.new")) {
                    if searching {
                        HStack(spacing: DesignTokens.Spacing.md) {
                            ProgressView().controlSize(.small)
                            Text(L("feed.relocate.searching"))
                        }
                    } else if candidates.isEmpty {
                        Text(L("feed.relocate.notFound"))
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
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("feed.relocate.replace")) { if let picked { onReplace(picked) } }
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
            initialValue: feed.id.map {
                KeychainStore.get(account: KeychainStore.basicAccount(feedId: $0)) ?? ""
            } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("settings.refresh.title")) {
                    Picker(L("feed.fetch.interval"), selection: $refreshMinutes) {
                        Text(L("common.followGlobal")).tag(Self.followsGlobal)
                        Text(L("settings.refresh.interval.15")).tag(15)
                        Text(L("settings.refresh.interval.30")).tag(30)
                        Text(L("settings.refresh.interval.60")).tag(60)
                        Text(L("settings.refresh.interval.120")).tag(120)
                    }
                    Text(L("feed.fetch.interval.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("feed.fetch.userAgent")) {
                    TextField(L("feed.fetch.userAgent.placeholder"), text: $userAgent)
                    Text(L("feed.fetch.userAgent.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("feed.fetch.basicAuth")) {
                    TextField(L("feed.fetch.basicAuth.user"), text: $basicUser)
                    SecureField(L("feed.fetch.basicAuth.password"), text: $basicPassword)
                    Text(L("feed.fetch.basicAuth.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(feed.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.save")) {
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
