import AppKit
import GRDB
import SwiftUI
import UniformTypeIdentifiers

/// 设置分类；case 顺序即侧栏顺序。
private enum SettingsCategory: String, CaseIterable, Identifiable {
    case appearance, reading, shortcuts, translation, refresh, retention, subscriptions, mute, data

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "外观"
        case .reading: "阅读"
        case .shortcuts: "快捷键"
        case .translation: "翻译"
        case .refresh: "刷新"
        case .retention: "保留"
        case .subscriptions: "订阅"
        case .mute: "静音"
        case .data: "数据"
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintbrush"
        case .reading: "book"
        case .shortcuts: "keyboard"
        case .translation: "translate"
        case .refresh: "arrow.clockwise"
        case .retention: "archivebox"
        case .subscriptions: "dot.radiowaves.up.forward"
        case .mute: "speaker.slash"
        case .data: "externaldrive"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsCategory = .appearance

    var body: some View {
        NavigationSplitView {
            // 分类行默认行高很紧，九个分类挤成一坨（Paul 反馈）。
            // 图标与文字都放大一档，再给每行上下留白，栏宽跟着放宽容纳。
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label {
                    Text(category.title)
                        .font(.system(size: DesignTokens.Typography.control))
                } icon: {
                    Image(systemName: category.icon)
                        .font(.system(size: DesignTokens.Icon.sidebar))
                        .frame(width: DesignTokens.Icon.sidebar + 4)
                }
                .padding(.vertical, DesignTokens.Spacing.sm)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(196)
            // 设置窗的分类栏没有收起的道理，摘掉系统自动加的侧栏按钮
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 820, height: 580)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .appearance: AppearanceSettings()
        case .reading: ReadingSettings()
        case .shortcuts: ShortcutSettings()
        case .translation: TranslationSettings()
        case .refresh: RefreshSettings()
        case .retention: RetentionSettings()
        case .subscriptions: SubscriptionSettings()
        case .mute: MuteSettings()
        case .data: DataSettings()
        }
    }
}

// MARK: - 外观

private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.appearanceMode) private var appearanceMode = "light"

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Text("主题立即生效。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 阅读

private struct ReadingSettings: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.articleFontSize) private var articleFontSize = 17.5
    @AppStorage(SettingsKey.markReadOnOpen) private var markReadOnOpen = true
    @AppStorage(SettingsKey.markReadOnScrollEnd) private var markReadOnScrollEnd = false

    var body: some View {
        Form {
            Section("阅读") {
                HStack {
                    Text("正文字号")
                    Slider(value: $articleFontSize, in: 15...23, step: 1)
                    Text("\(Int(articleFontSize)) px")
                        .font(.system(size: DesignTokens.Typography.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                fontPreview
                Text("字号对之后打开的文章生效。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Toggle("打开即标为已读", isOn: $markReadOnOpen)
                Toggle("滚动到底标为已读", isOn: $markReadOnScrollEnd)
                Text("两个开关互不依赖；都关闭时只能用 m 或右键手动标记。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// 字号实时预览：阅读页同款纸面底色，标题按正文 1.7 倍缩放（与模板 30/17.5 的比例一致），
    /// 译文行带模板同款左侧强调线。
    @ViewBuilder
    private var fontPreview: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("文章标题预览")
                .font(.system(size: articleFontSize * 1.7, weight: .bold))
            Text("正文会以这个大小显示。The quick brown fox jumps over the lazy dog.")
                .font(.system(size: articleFontSize))
            Text("译文与正文同字号，带左侧强调线。")
                .font(.system(size: articleFontSize))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(.tint).frame(width: 3)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Typography.control)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
                .fill(DesignTokens.Reader.background(for: colorScheme))
        )
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Radius.large)
            .strokeBorder(.separator, lineWidth: 1))
    }
}

// MARK: - 快捷键

private struct ShortcutSettings: View {
    @ObservedObject private var keys = KeyBindings.shared
    @State private var recordingAction: KeyAction?
    @State private var recordMonitor: Any?
    @State private var conflictText: String?

    var body: some View {
        Form {
            Section {
                ForEach(KeyAction.allCases) { action in
                    HStack(spacing: 8) {
                        Text(action.title)
                        Spacer()
                        Text(recordingAction == action ? "按下新键位…" : (keys.bindings[action]?.display ?? "—"))
                            .font(.system(size: DesignTokens.Typography.caption, weight: .medium))
                            .foregroundStyle(recordingAction == action ? Color.accentColor : .primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                                .fill(.primary.opacity(DesignTokens.Opacity.subtle)))
                        Button(recordingAction == action ? "取消" : "更改") { toggleRecording(action) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        Button("恢复") { keys.reset(action) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                            .disabled(keys.bindings[action] == KeyBindings.defaults[action])
                    }
                }
                if let conflictText {
                    Text(conflictText)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Text("点「更改」后直接按目标键；Esc 取消。修改立即生效。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("快捷键")
                    Spacer()
                    Button("全部恢复默认") {
                        keys.resetAll()
                        conflictText = nil
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .formStyle(.grouped)
        // 切到别的分类时本视图会销毁，录制中的全局监听必须一起撤掉。
        .onDisappear { stopRecording() }
    }

    /// 录制下一个按键作为 action 的新键位；Esc 取消；与既有键位冲突时拒绝并提示。
    private func toggleRecording(_ action: KeyAction) {
        if recordingAction == action {
            stopRecording()
            return
        }
        stopRecording()
        recordingAction = action
        keys.isRecording = true
        conflictText = nil
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc = 取消
                stopRecording()
                return nil
            }
            guard let stroke = KeyStroke.from(event: event) else { return nil } // 纯修饰键：等下一次按键
            if let clash = keys.conflict(of: stroke, excluding: action) {
                conflictText = "「\(stroke.display)」已被「\(clash.title)」占用，换一个键位。"
                stopRecording()
                return nil
            }
            keys.set(stroke, for: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = recordMonitor { NSEvent.removeMonitor(m) }
        recordMonitor = nil
        recordingAction = nil
        keys.isRecording = false
    }
}

// MARK: - 翻译

private struct TranslationSettings: View {
    @AppStorage(SettingsKey.translationEngine) private var translationEngine = "apple"
    @AppStorage(SettingsKey.autoTranslateForeign) private var autoTranslateForeign = true
    @AppStorage(SettingsKey.apiBaseURL) private var apiBaseURL = ""
    @AppStorage(SettingsKey.apiModel) private var apiModel = ""
    @AppStorage(SettingsKey.translationTargetLang) private var targetLang = "zh-Hans"

    /// Key 存钥匙串不进 UserDefaults，用 @State 中转：显示时读出，编辑时写回。
    @State private var apiKey = KeychainStore.get(account: "api-key") ?? ""

    var body: some View {
        Form {
            Section("翻译") {
                Picker("引擎", selection: $translationEngine) {
                    Text("系统翻译（离线）").tag("apple")
                    Text("API 翻译").tag("api")
                }
                if translationEngine == "api" {
                    TextField("Base URL", text: $apiBaseURL, prompt: Text("https://api.example.com/v1"))
                    TextField("模型名", text: $apiModel)
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) {
                            KeychainStore.set(account: "api-key", value: apiKey)
                        }
                }
                Picker("译文语言", selection: $targetLang) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                Text("对之后打开的文章生效；换语言后旧译文缓存自动失效重翻。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle("外文文章自动开启双语对照", isOn: $autoTranslateForeign)
                Text("关闭后仍可按 T 手动翻译；Key 存本机钥匙串，设置对之后打开的文章生效。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 刷新

private struct RefreshSettings: View {
    @AppStorage(SettingsKey.refreshMinutes) private var refreshMinutes = 30
    @AppStorage(SettingsKey.newFeedInitialRead) private var newFeedInitialRead = "unread"
    @AppStorage(SettingsKey.newFeedRecentCount) private var newFeedRecentCount = 10
    @AppStorage(SettingsKey.defaultFullTextMode) private var defaultFullTextMode = "auto"
    @AppStorage(SettingsKey.domainMinIntervalSeconds) private var domainMinIntervalSeconds = 0

    var body: some View {
        Form {
            Section("刷新") {
                Picker("自动刷新间隔", selection: $refreshMinutes) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("2 小时").tag(120)
                }
                Text("单个源可以在右键「抓取设置…」里覆盖这个间隔。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Picker("同域请求间隔", selection: $domainMinIntervalSeconds) {
                    Text("关闭").tag(0)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("30 秒").tag(30)
                }
                Text("同一网站的多个订阅之间至少间隔这么久再发下一个请求。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Picker("新增订阅的首批文章", selection: $newFeedInitialRead) {
                    Text("全部未读").tag("unread")
                    Text("全部已读").tag("read")
                    Text("只留最近几条未读").tag("recent")
                }
                if newFeedInitialRead == "recent" {
                    Picker("保留未读条数", selection: $newFeedRecentCount) {
                        ForEach([5, 10, 25, 50], id: \.self) { Text("\($0) 条").tag($0) }
                    }
                }
                Text("只影响该源第一次抓取的那批文章。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Picker("默认全文抓取", selection: $defaultFullTextMode) {
                    ForEach(FullTextMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Text("只影响之后新增的订阅；已有订阅在右键「阅读设置…」里改。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 保留

private struct RetentionSettings: View {
    @AppStorage(SettingsKey.keepCount) private var keepCount = 500
    @AppStorage(SettingsKey.keepDays) private var keepDays = 90

    var body: some View {
        Form {
            Section("保留策略（星标永久保留）") {
                Picker("每源保留条数", selection: $keepCount) {
                    Text("200").tag(200)
                    Text("500").tag(500)
                    Text("1000").tag(1000)
                    Text("2000").tag(2000)
                }
                Picker("保留时间", selection: $keepDays) {
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("一年").tag(365)
                    Text("永久").tag(0)
                }
                Text("单个订阅可在右键「阅读设置…」里覆盖这两项。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 静音

private struct MuteSettings: View {
    // Settings 场景没有注入 AppEnvironment（见 BiFeedApp），数据统一走 AppEnvironment.sharedDB。
    @StateObject private var muteRules: DBObserved<[MuteRule]>
    @StateObject private var feeds: DBObserved<[Feed]>
    @StateObject private var folders: DBObserved<[Folder]>
    @State private var showingMuteEditor = false
    @State private var muteStatus: String?

    init() {
        _muteRules = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: []) { db in
            try MuteRules.fetchAll(db)
        })
        _feeds = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: []) { db in
            try Feed.order(Column("title")).fetchAll(db)
        })
        _folders = StateObject(wrappedValue: DBObserved(db: AppEnvironment.sharedDB, initial: []) { db in
            try Folder.order(Column("name")).fetchAll(db)
        })
    }

    var body: some View {
        Form {
            Section("静音") {
                ForEach(muteRules.value) { rule in
                    HStack(spacing: DesignTokens.Spacing.md) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            Text(rule.pattern).lineLimit(1)
                            Text("\(rule.matchType.label) · \(rule.field.label) · \(scopeLabel(rule)) · \(rule.action.label)")
                                .font(.system(size: DesignTokens.Typography.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            let db = AppEnvironment.sharedDB
                            let id = rule.id
                            write { try await MuteRules.delete(db, id: id) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("删除这条规则")
                    }
                }
                Button {
                    showingMuteEditor = true
                } label: {
                    Label("新建静音规则…", systemImage: "plus")
                }
                if let muteStatus {
                    Text(muteStatus)
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Text("规则保存或删除后立即回扫历史；已静音文章可在侧栏检查并放行。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingMuteEditor) {
            MuteRuleEditor(feeds: feeds.value, folders: folders.value) { draft in
                showingMuteEditor = false
                addMuteRule(draft)
            }
        }
    }

    private func scopeLabel(_ rule: MuteRule) -> String {
        if let folderId = rule.scopeFolderId {
            return folders.value.first { $0.id == folderId }?.name ?? "—"
        }
        guard let fid = rule.scopeFeedId else { return "全局" }
        // scopeFeedId 外键随 feed 级联删除，正常总能查到标题；
        // 两条 ValueObservation 异步刷新可能错位一帧，占位符只为这一帧。
        return feeds.value.first { $0.id == fid }?.title ?? "—"
    }

    private func addMuteRule(_ draft: MuteRuleDraft) {
        Task {
            do {
                let count = try await MuteRules.add(AppEnvironment.sharedDB, draft: draft)
                muteStatus = "保存成功，本次命中 \(count) 篇。"
            } catch {
                muteStatus = "保存失败：\(error.localizedDescription)"
            }
        }
    }

    /// Settings 场景拿不到 AppEnvironment，错误处理与 AppEnvironment.dbWrite 同策略：
    /// debug 断言，release 打日志。
    private func write(_ op: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await op() } catch {
                assertionFailure("db write failed: \(error)")
                FileHandle.standardError.write(Data("[2W] db write failed: \(error)\n".utf8))
            }
        }
    }
}

// MARK: - 数据

private struct DataSettings: View {
    @AppStorage(SettingsKey.checkUpdatesOnLaunch) private var checkUpdatesOnLaunch = true
    @AppStorage(SettingsKey.skippedUpdateVersion) private var skippedUpdateVersion = ""
    @State private var dataStatus: String?
    /// 非 nil = 待恢复文件已就位，弹窗问要不要立刻重启
    @State private var pendingRestore: String?

    var body: some View {
        Form {
            Section("数据") {
                LabeledContent("数据库位置") {
                    Text(AppDatabase.defaultPath())
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("备份数据库…") { backupDatabase() }
                    Button("从备份恢复…") { restoreDatabase() }
                    Spacer()
                    Button("打开备份文件夹") {
                        try? FileManager.default.createDirectory(
                            at: Backup.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Backup.directory)
                    }
                }
                if let dataStatus {
                    Text(dataStatus)
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Text("备份是一致性快照，可在应用运行时进行。订阅列表每天自动备份一份 OPML，保留最近 7 份。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Section("更新") {
                Toggle("启动时检查更新", isOn: $checkUpdatesOnLaunch)
                LabeledContent("当前版本") {
                    Text(UpdateChecker.currentVersion).foregroundStyle(.secondary)
                }
                Text("只检查并提示，不会自动下载或安装。跳过的版本可在这里清除。")
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                if !skippedUpdateVersion.isEmpty {
                    HStack {
                        Text("已跳过 \(skippedUpdateVersion)")
                            .font(.system(size: DesignTokens.Typography.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("不再跳过") { skippedUpdateVersion = "" }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("恢复后需要重启", isPresented: .constant(pendingRestore != nil)) {
            Button("稍后重启") { pendingRestore = nil }
            Button("立即重启") {
                pendingRestore = nil
                relaunch()
            }
        } message: {
            Text(pendingRestore ?? "")
        }
    }

    // MARK: - 备份与恢复

    private func backupDatabase() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.nameFieldStringValue = Backup.suggestedFilename()
        panel.message = "保存数据库快照"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataStatus = "正在备份…"
        Task {
            do {
                try await Backup.snapshot(AppEnvironment.sharedDB, to: url)
                dataStatus = "已备份到 \(url.lastPathComponent)。"
            } catch {
                dataStatus = "备份失败：\(error.localizedDescription)"
            }
        }
    }

    /// 恢复不当场替换运行中的数据库：校验后落一份待恢复文件，下次启动换过去。
    private func restoreDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data, .data]
        panel.message = "选择 2W 数据库备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let info = try Backup.stageRestore(from: url)
            dataStatus = "备份已校验：\(info.summary)。重启后生效。"
            pendingRestore = "\(url.lastPathComponent)（\(info.summary)）将在下次启动时替换当前数据库，"
                + "当前数据库会保留为 bifeed.sqlite.bak。"
        } catch {
            dataStatus = "无法恢复：\(error.localizedDescription)"
        }
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - 静音规则编辑器

private enum MuteScopeChoice: Hashable {
    case all
    case folder(Int64)
    case feed(Int64)
}

private struct MuteRuleEditor: View {
    let feeds: [Feed]
    let folders: [Folder]
    let onSave: (MuteRuleDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @State private var matchType = MuteMatchType.contains
    @State private var field = MuteRuleField.title
    @State private var scope = MuteScopeChoice.all
    @State private var exceptions = ""
    @State private var action = MuteRuleAction.hide

    var body: some View {
        NavigationStack {
            Form {
                Section("条件") {
                    Picker("匹配", selection: $matchType) {
                        ForEach(MuteMatchType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(matchType == .regex ? "正则表达式" : "关键词", text: $pattern)
                    Picker("字段", selection: $field) {
                        ForEach(MuteRuleField.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("范围") {
                    Picker("作用于", selection: $scope) {
                        Text("全部订阅").tag(MuteScopeChoice.all)
                        if !folders.isEmpty {
                            Section("分组") {
                                ForEach(folders) { folder in
                                    Text(folder.name).tag(MuteScopeChoice.folder(folder.id!))
                                }
                            }
                        }
                        Section("订阅") {
                            ForEach(feeds) { feed in
                                Text(feed.title).tag(MuteScopeChoice.feed(feed.id!))
                            }
                        }
                    }
                }
                Section("例外词（一行一个，可留空）") {
                    TextEditor(text: $exceptions)
                        .font(.system(size: DesignTokens.Typography.body))
                        .frame(height: 72)
                    Text("任一字段含例外词时，这条规则不会触发。")
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section("动作") {
                    Picker("命中后", selection: $action) {
                        ForEach(MuteRuleAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新建静音规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并回扫") {
                        onSave(draft)
                    }
                    .disabled(!isValid)
                }
            }
        }
        .frame(width: 430, height: 490)
    }

    private var isValid: Bool {
        let value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return matchType != .regex
            || (try? NSRegularExpression(pattern: value, options: .caseInsensitive)) != nil
    }

    private var draft: MuteRuleDraft {
        let feedId: Int64? = if case .feed(let id) = scope { id } else { nil }
        let folderId: Int64? = if case .folder(let id) = scope { id } else { nil }
        return MuteRuleDraft(
            pattern: pattern.trimmingCharacters(in: .whitespacesAndNewlines),
            matchType: matchType, field: field, scopeFeedId: feedId,
            scopeFolderId: folderId, exceptions: exceptions, action: action)
    }
}
