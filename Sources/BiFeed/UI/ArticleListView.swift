import AppKit
import GRDB
import SwiftUI

/// Space 到底后阅读器请求列表跳到下一篇未读。定义收在本文件（FeedColor.swift 归 Agent R 管）；
/// ReaderView.swift 侧有同名同串的私有声明，两处以字符串 "bifeedNextUnread" 为准。
private extension Notification.Name {
    static let bifeedNextUnread = Notification.Name("bifeedNextUnread")
}

/// 本文件的局部数据源，代替 DBObserved：搜索词变化不能走 .id 重建（搜索框会丢焦点），
/// 而 DBObserved 的 fetch 闭包在 init 后无法换参数重查，所以这里包一层"可重启"的 ValueObservation。
/// 重启期间 value 保留旧列表，不闪空。
@MainActor
private final class SearchableArticleList: ObservableObject {
    @Published private(set) var value: [ArticleListItem] = []
    private let db: AppDatabase
    private let scope: SidebarSelection
    private var search: String?
    private var filter: String
    /// 搜索的范围限定：true = 忽略当前侧栏范围搜全部订阅。
    private var searchesAllFeeds = false
    private var window = SearchWindow.any
    /// 粘性未读（Paul：未读视图里点开的文章一点就消失，太难受）：
    /// 本轮未读浏览中被标读的 id 仍保留在列表；切走过滤/换范围时清空，下次进来才消失。
    private var stickyReadIds: Set<Int64> = []
    private var cancellable: AnyDatabaseCancellable?

    init(db: AppDatabase, scope: SidebarSelection, search: String?, window: SearchWindow) {
        self.db = db
        self.scope = scope
        self.search = search
        self.window = window
        // 初值直接读 UserDefaults（默认值由 SettingsKey.registerDefaults 注册）；
        // 之后的变更由视图的 onChange 经 apply(filter:) 驱动重启
        self.filter = UserDefaults.standard.string(forKey: SettingsKey.readFilter) ?? "all"
        restart()
    }

    /// 搜索的范围与时间限定。任一变化都重启观察。
    func apply(searchesAllFeeds: Bool, window newWindow: SearchWindow) {
        guard searchesAllFeeds != self.searchesAllFeeds || newWindow != window else { return }
        self.searchesAllFeeds = searchesAllFeeds
        window = newWindow
        restart()
    }

    /// 空白搜索词等价于无搜索：归一成 nil，恢复原列表。词没变就不重启观察。
    func apply(search text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard normalized != search else { return }
        search = normalized
        restart()
    }

    /// 与 apply(search:) 同构：值没变就不重启观察。切档清空粘性集合——"退出再进来才消失"。
    func apply(filter newValue: String) {
        guard newValue != filter else { return }
        filter = newValue
        stickyReadIds = []
        restart()
    }

    /// 未读视图里即将被标读的文章：先入粘性集合再写库，观察刷新时它仍在 SQL 结果里。
    func keepSticky(_ id: Int64) {
        guard filter == "unread", !stickyReadIds.contains(id) else { return }
        stickyReadIds.insert(id)
        restart()
    }

    private func restart() {
        // 范围/时间限定只在真的在搜索时生效，否则清空搜索框会莫名其妙地换掉当前范围
        let searching = search != nil
        let scope = searching && searchesAllFeeds ? .all : scope
        let search = search
        let filter = filter
        let sticky = stickyReadIds
        let since = searching ? window.since() : nil
        let observation = ValueObservation.tracking { db in
            try ArticleListItem.fetchAll(db, scope: scope, search: search, filter: filter,
                                         sticky: sticky, since: since)
        }
        cancellable = observation.start(
            in: db.pool,
            scheduling: .async(onQueue: .main),
            onError: { error in fatalError("数据库观察失败: \(error)") },
            onChange: { [weak self] newValue in self?.value = newValue })
    }
}

struct ArticleListView: View {
    /// 侧栏选中的原始值（可能是 .savedSearch）；查询用的是解析后的 effectiveScope。
    let scope: SidebarSelection
    private let effectiveScope: SidebarSelection
    private let savedSearchName: String?
    /// 保存搜索记下的列表过滤；非 nil 时在 onAppear 恢复（写 UserDefaults 是副作用，不放 init）
    private let savedFilter: String?
    @Binding var selectedArticleId: Int64?
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model: SearchableArticleList
    @AppStorage(SettingsKey.readFilter) private var readFilter = "all"
    @AppStorage(SettingsKey.markReadOnOpen) private var markReadOnOpen = true
    @State private var keyMonitor: Any?
    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var searchesAllFeeds = false
    @State private var searchWindow = SearchWindow.any
    @State private var savingSearch = false
    @State private var searchNameDraft = ""

    init(db: AppDatabase, scope: SidebarSelection, selectedArticleId: Binding<Int64?>) {
        self.scope = scope
        // 保存的搜索在这里一次性解析成「基础范围 + 词 + 时间窗」，之后全链路都按普通搜索走
        let resolved: (saved: SavedSearch, scope: SidebarSelection)? =
            if case .savedSearch(let id) = scope { SavedSearches.resolve(db, id: id) } else { nil }
        effectiveScope = resolved?.scope ?? scope
        savedSearchName = resolved?.saved.name
        savedFilter = resolved?.saved.filter
        let query = resolved?.saved.query
        let window = resolved?.saved.searchWindow ?? .any
        _searchText = State(initialValue: query ?? "")
        _searchWindow = State(initialValue: window)
        _selectedArticleId = selectedArticleId
        _model = StateObject(wrappedValue: SearchableArticleList(
            db: db, scope: resolved?.scope ?? scope, search: query, window: window))
    }

    var body: some View {
        Group {
            if model.value.isEmpty {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if readFilter != "all" {
                    // 过滤态的空列表与"没有文章"分开，避免误以为没订阅
                    ContentUnavailableView {
                        Label(readFilter == "unread" ? "没有未读文章" : "没有星标文章",
                              systemImage: readFilter == "unread" ? "checkmark.circle" : "star")
                    } description: {
                        Text("切换回「全部」可查看所有文章。")
                    }
                } else if effectiveScope == .muted {
                    ContentUnavailableView {
                        Label("没有已静音文章", systemImage: "speaker.slash")
                    } description: {
                        Text("静音规则命中的文章会出现在这里。")
                    }
                } else {
                    ContentUnavailableView {
                        Label("没有文章", systemImage: "tray")
                    } description: {
                        Text("添加订阅或刷新后，文章会出现在这里。")
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedArticleId) {
                        ForEach(model.value) { item in
                            ArticleRow(item: item, showsFeedIdentity: showsFeedIdentity)
                                .tag(item.id)
                                .contextMenu { rowMenu(item) }
                        }
                    }
                    .listStyle(.inset)
                    // 不给锚点 = 最小滚动：选中项在视野内就一动不动（点击场景零跳动），
                    // 只有 j/k 走到边缘外才把它挪进来。用户明确不要"弹到中间"。
                    .onChange(of: selectedArticleId) { _, newValue in
                        guard let id = newValue else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索文章")
        .onChange(of: searchText) { _, text in
            searchTask?.cancel()
            // 清空立即恢复原列表；输入走 200ms 防抖，避免每敲一键重启一次观察
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.apply(search: "")
                return
            }
            searchTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                model.apply(search: text)
            }
        }
        .onChange(of: readFilter) { _, newValue in
            model.apply(filter: newValue)
        }
        .navigationTitle(listTitle)
        .safeAreaInset(edge: .top, spacing: 0) { listHeader }
        .toolbar {
            ToolbarItem {
                if env.undoableReadBatch != nil {
                    Button {
                        env.undoMarkAllRead()
                    } label: {
                        Label("撤销全部已读", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(Color.accentColor)
                    }
                    .help("撤销刚才的全部标为已读")
                } else {
                    Button {
                        markAllVisibleRead()
                    } label: {
                        Label("全部标为已读", systemImage: "checkmark.circle")
                    }
                    .help("当前列表全部标为已读")
                    .disabled(model.value.allSatisfy(\.isRead))
                }
            }
        }
        .onChange(of: selectedArticleId) { _, newValue in
            guard markReadOnOpen, let id = newValue,
                  let item = model.value.first(where: { $0.id == id }), !item.isRead else { return }
            model.keepSticky(id)
            env.dbWrite { [db = env.db] in try await db.setRead(articleId: id, true) }
        }
        .onChange(of: searchesAllFeeds) { _, _ in
            model.apply(searchesAllFeeds: searchesAllFeeds, window: searchWindow)
        }
        .onChange(of: searchWindow) { _, _ in
            model.apply(searchesAllFeeds: searchesAllFeeds, window: searchWindow)
        }
        .alert("保存搜索", isPresented: $savingSearch) {
            TextField("名称", text: $searchNameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") { saveCurrentSearch() }
        } message: {
            Text("保存后出现在侧栏「保存的搜索」，点开即回到这次的词与范围。")
        }
        // Space 到底后阅读器请求跳到下一篇未读（Space 按键本身由上面的监听器转成 bifeedSpaceAdvance）
        .onReceive(NotificationCenter.default.publisher(for: .bifeedNextUnread)) { _ in
            advanceToNextUnread()
        }
        .onAppear {
            installKeyMonitor()
            // readFilter 是全局控件：恢复后切到别的范围不还原，这是既定语义
            if let savedFilter, savedFilter != readFilter { readFilter = savedFilter }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
            keyMonitor = nil
            searchTask?.cancel()
        }
    }

    /// 单源视图里来源名与 feed 图标全行相同，纯属重复，隐藏（COMPETITIVE.md V5）
    private var showsFeedIdentity: Bool {
        if case .feed = effectiveScope { return false }
        return true
    }

    private var listTitle: String {
        if let savedSearchName { return savedSearchName }
        switch effectiveScope {
        case .all: return "全部文章"
        case .today: return "今天"
        case .allUnread: return "全部未读"
        case .starred: return "星标"
        case .muted: return "已静音"
        case .folder, .feed, .savedSearch:
            return model.value.first.map { scopeTitle(from: $0) } ?? "文章"
        }
    }

    private func scopeTitle(from item: ArticleListItem) -> String {
        if case .feed = effectiveScope { return item.feedTitle }
        return "文章"
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func rowMenu(_ item: ArticleListItem) -> some View {
        Button(item.isRead ? "标为未读" : "标为已读") {
            env.dbWrite { [db = env.db] in try await db.setRead(articleId: item.id, !item.isRead) }
        }
        Button(item.isStarred ? "取消星标" : "加星标") {
            env.dbWrite { [db = env.db] in try await db.setStarred(articleId: item.id, !item.isStarred) }
        }
        // 读到这里为止：按列表当前顺序（新→旧），把这一篇和它下面的全标已读
        Button("这篇及以下标为已读") { markReadFrom(item) }
        if item.isMuted {
            Button("放行并加入规则例外") {
                env.dbWrite { [db = env.db] in
                    _ = try await MuteRules.allow(db, articleId: item.id)
                }
            }
        }
        Divider()
        if let urlString = item.url, let url = URL(string: urlString) {
            Button("在浏览器打开") { NSWorkspace.shared.open(url) }
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urlString, forType: .string)
            }
        }
    }

    // MARK: - 快捷键 ↩/⌘↩/T/j/k/n/m/u/s/Space

    /// 键位表驱动（设置 → 快捷键 可改）。被处理的键必须消费事件（return nil），否则系统 beep。
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 设置页正在录制新键位：完全让路，事件归录制监听器
            if KeyBindings.shared.isRecording { return event }
            guard let action = KeyBindings.shared.action(for: event) else { return event }
            // 文本输入（搜索框、添加订阅）聚焦时：只放行无 ⌘ 的绑定，打字优先
            if NSApp.keyWindow?.firstResponder is NSTextView,
               KeyBindings.shared.bindings[action]?.command != true {
                return event
            }
            switch action {
            case .nextArticle: move(1)
            case .prevArticle: move(-1)
            case .nextUnread:
                // 与 Space 到底的路径同一个入口：onReceive(.bifeedNextUnread) → advanceToNextUnread
                NotificationCenter.default.post(name: .bifeedNextUnread, object: nil)
            case .spaceAdvance:
                NotificationCenter.default.post(name: .bifeedSpaceAdvance, object: nil)
            case .translate:
                NotificationCenter.default.post(name: .bifeedToggleTranslate, object: nil)
            case .immersive:
                NotificationCenter.default.post(name: .bifeedToggleImmersive, object: nil)
            case .openOriginal:
                // 无选中文章（或文章无链接）时放行
                guard let urlString = current()?.url, let url = URL(string: urlString) else { return event }
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            case .toggleRead, .toggleReadAlias:
                if let item = current() {
                    if !item.isRead { model.keepSticky(item.id) }
                    env.dbWrite { [db = env.db] in try await db.setRead(articleId: item.id, !item.isRead) }
                }
            case .toggleStar:
                if let item = current() {
                    env.dbWrite { [db = env.db] in try await db.setStarred(articleId: item.id, !item.isStarred) }
                }
            }
            return nil
        }
    }

    /// 邮件式列表头：篇数统计 + 未读过滤圆钮（Paul 指定，照 Mail 收件箱顶部的形态）。
    private var listHeader: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Text(headerSummary)
                .font(.system(size: DesignTokens.Typography.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if isSearching { searchScopeMenu }
            Button {
                readFilter = readFilter == "unread" ? "all" : "unread"
            } label: {
                Image(systemName: readFilter == "unread"
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
                    .font(.system(size: DesignTokens.Icon.control))
                    .foregroundStyle(readFilter == "unread" ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(readFilter == "unread" ? "显示全部" : "只看未读")
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .padding(.vertical, 5)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// 搜索时才出现：限定范围与时间，并把当前这次搜索存成侧栏的智能源。
    private var searchScopeMenu: some View {
        Menu {
            Picker("范围", selection: $searchesAllFeeds) {
                Text(currentScopeLabel).tag(false)
                Text("全部订阅").tag(true)
            }
            Picker("时间", selection: $searchWindow) {
                ForEach(SearchWindow.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Divider()
            Button("保存这次搜索…") {
                searchNameDraft = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                savingSearch = true
            }
        } label: {
            Image(systemName: searchesAllFeeds || searchWindow != .any
                ? "magnifyingglass.circle.fill" : "magnifyingglass.circle")
                .font(.system(size: DesignTokens.Icon.control))
                .foregroundStyle(searchesAllFeeds || searchWindow != .any
                    ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("搜索范围与时间")
    }

    private var currentScopeLabel: String {
        switch effectiveScope {
        case .all, .allUnread, .today, .starred, .muted, .savedSearch: "当前范围"
        case .folder: "当前分组"
        case .feed: "当前订阅"
        }
    }

    private var headerSummary: String {
        let unread = model.value.filter { !$0.isRead }.count
        if readFilter == "unread" { return "只看未读 · \(model.value.count) 篇" }
        return "\(model.value.count) 篇，\(unread) 未读"
    }

    /// 「读到这里为止」以用户看到的顺序为准：列表已经按范围、过滤和搜索筛过，
    /// 所见即所标，不用再去 SQL 里复刻一遍排序条件。
    private func markReadFrom(_ item: ArticleListItem) {
        guard let index = model.value.firstIndex(where: { $0.id == item.id }) else { return }
        env.markRead(ids: model.value[index...].filter { !$0.isRead }.map(\.id))
    }

    /// 保存的搜索没有单一 SQL 范围，统一按可见条目标已读；两条路径共用同一个撤销入口。
    private func markAllVisibleRead() {
        if case .savedSearch = scope {
            env.markRead(ids: model.value.filter { !$0.isRead }.map(\.id))
        } else {
            env.markAllRead(scope: effectiveScope)
        }
    }

    private func saveCurrentSearch() {
        let name = searchNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !query.isEmpty else { return }
        let scope = searchesAllFeeds ? .all : effectiveScope
        let window = searchWindow
        let filter = readFilter
        env.dbWrite { [db = env.db] in
            try await SavedSearches.add(db, name: name, query: query, scope: scope,
                                        window: window, filter: filter)
        }
    }

    private func current() -> ArticleListItem? {
        model.value.first { $0.id == selectedArticleId }
    }

    private func move(_ delta: Int) {
        let items = model.value
        guard !items.isEmpty else { return }
        guard let currentId = selectedArticleId,
              let idx = items.firstIndex(where: { $0.id == currentId }) else {
            selectedArticleId = items.first?.id
            return
        }
        let next = min(max(idx + delta, 0), items.count - 1)
        selectedArticleId = items[next].id
    }

    /// 从当前选中往后找第一篇未读并选中；未选中（或选中项已不在列表里）从头找；没有未读不动。
    private func advanceToNextUnread() {
        let items = model.value
        let start = selectedArticleId
            .flatMap { id in items.firstIndex(where: { $0.id == id }) }
            .map { $0 + 1 } ?? 0
        guard let next = items[start...].first(where: { !$0.isRead }) else { return }
        selectedArticleId = next.id
    }
}

/// 列表行（NNW 式）：favicon + 标题 + 摘要 + 来源/时间底行。精致度靠间距与字重层级，不靠装饰。
/// 已读 = 整行降不透明度（Unread 的做法）：浅色 0.5、深色 0.62——浅色下只灰标题看不出来，用户点名过。
private struct ArticleRow: View {
    let item: ArticleListItem
    /// false = 单源视图（V5）：全行同源，行内不再显示 feed 图标与来源名，
    /// 未读点直接放行首，行高随图标消失自然收紧。
    let showsFeedIdentity: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            if showsFeedIdentity {
                // 未读点叠在图标左上角，不再独占一列：独立列会把整行文字推右，
                // 已读行还留出一条空白竖槽显得松散；叠角标不占横向空间，且天然与图标对齐。
                // 向外偏移 2pt 让点大半落在行背景上，压不住 favicon 也不怕撞色。
                ZStack(alignment: .topLeading) {
                    RowFeedIcon(feedId: item.feedId, feedTitle: item.feedTitle, size: 20, store: FaviconStore.shared)
                    if !item.isRead {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: -2)
                    }
                }
                .padding(.top, 1)
            } else {
                // 已读行放透明占位而不是拿掉，标题左缘才对得齐
                Circle()
                    .fill(.tint)
                    .frame(width: 6, height: 6)
                    .opacity(item.isRead ? 0 : 1)
                    .padding(.top, 5) // 与 13pt 标题首行光学居中
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: DesignTokens.Typography.body,
                                  weight: item.isRead ? .regular : .semibold))
                    .foregroundStyle(.primary) // 已读的弱化交给整行 opacity，不再叠色
                    .lineLimit(item.isCollapsed ? 1 : 2)
                if !item.isCollapsed && !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.system(size: DesignTokens.Typography.metadata))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: DesignTokens.Typography.micro))
                            .foregroundStyle(.yellow)
                    }
                    if item.isCollapsed {
                        Label("已折叠", systemImage: "rectangle.compress.vertical")
                            .font(.system(size: DesignTokens.Typography.micro))
                            .foregroundStyle(.secondary)
                    }
                    if PaywallDetector.isLikelyPaywalled(urlString: item.url) {
                        Label("付费墙", systemImage: "lock")
                            .font(.system(size: DesignTokens.Typography.micro))
                            .foregroundStyle(.secondary)
                            .help("该站点通常需要订阅才能读全文")
                    }
                    if item.duplicateCount > 0 {
                        Label("\(item.duplicateCount + 1) 个来源", systemImage: "square.stack.3d.up")
                            .font(.system(size: DesignTokens.Typography.micro))
                            .foregroundStyle(.secondary)
                    }
                    if showsFeedIdentity {
                        Text(item.feedTitle)
                            .font(.system(size: DesignTokens.Typography.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(Self.relative(item.publishedAt))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .opacity(item.isRead
            ? (colorScheme == .dark ? DesignTokens.Opacity.readDark : DesignTokens.Opacity.readLight)
            : (item.isCollapsed ? 0.72 : 1))
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Paul 定的显示规则：今天=相对时间，昨天=「昨天」，更早同年 = 8/12，跨年 = 2025/8/12
    static func relative(_ date: Date?) -> String {
        guard let date else { return "无日期" }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            if Date().timeIntervalSince(date) < 60 { return "刚刚" }
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        if cal.isDateInYesterday(date) { return "昨天" }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        if c.year == cal.component(.year, from: Date()) { return "\(c.month!)/\(c.day!)" }
        return "\(c.year!)/\(c.month!)/\(c.day!)"
    }
}

/// 行首图标：有 favicon 用真图标，否则回退 FeedChip 首字块。
/// 契约里的 FeedIcon 要完整 Feed 对象，而列表行只带 feedId/feedTitle（列表查询不多拿列），
/// 所以这里按同一回退思路本地实现。观察 store：新图标落盘时 version +1，行自动换上真图标。
private struct RowFeedIcon: View {
    let feedId: Int64
    let feedTitle: String
    let size: CGFloat
    @ObservedObject var store: FaviconStore

    var body: some View {
        if let image = store.image(for: feedId) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24))
        } else {
            FeedChip(title: feedTitle, size: size)
        }
    }
}
