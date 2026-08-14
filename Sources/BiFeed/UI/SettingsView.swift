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
        case .appearance: L("settings.appearance.title")
        case .reading: L("settings.reading.title")
        case .shortcuts: L("settings.shortcuts.title")
        case .translation: L("settings.language.title")
        case .refresh: L("settings.refresh.title")
        case .retention: L("settings.retention.title")
        case .subscriptions: L("common.feeds")
        case .mute: L("settings.mute.title")
        case .data: L("settings.data.title")
        }
    }

    var icon: String {
        switch self {
        case .appearance: "paintbrush"
        case .reading: "book"
        case .shortcuts: "keyboard"
        case .translation: "globe"
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
            // 第一行紧贴标题栏，看着像被顶住了；给顶部留一段呼吸空间（Paul 反馈）
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: DesignTokens.Spacing.lg)
            }
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
            Section(L("settings.appearance.title")) {
                Picker(L("settings.appearance.theme"), selection: $appearanceMode) {
                    Text(L("settings.appearance.theme.system")).tag("system")
                    Text(L("settings.appearance.theme.light")).tag("light")
                    Text(L("settings.appearance.theme.dark")).tag("dark")
                }
                Text(L("settings.appearance.note"))
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
            Section(L("settings.reading.title")) {
                HStack {
                    Text(L("settings.reading.fontSize"))
                    Slider(value: $articleFontSize, in: 15...23, step: 1)
                    Text("\(Int(articleFontSize)) px")
                        .font(.system(size: DesignTokens.Typography.caption).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                fontPreview
                Text(L("settings.reading.fontSize.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Toggle(L("settings.reading.markReadOnOpen"), isOn: $markReadOnOpen)
                Toggle(L("settings.reading.markReadOnScrollEnd"), isOn: $markReadOnScrollEnd)
                Text(L("settings.reading.markRead.note"))
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
            Text(L("settings.reading.preview.title"))
                .font(.system(size: articleFontSize * 1.7, weight: .bold))
            Text(L("settings.reading.preview.body"))
                .font(.system(size: articleFontSize))
            Text(L("settings.reading.preview.translation"))
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
                        Text(recordingAction == action
                            ? L("settings.shortcuts.recording")
                            : (keys.bindings[action]?.display ?? "—"))
                            .font(.system(size: DesignTokens.Typography.caption, weight: .medium))
                            .foregroundStyle(recordingAction == action ? Color.accentColor : .primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: DesignTokens.Radius.small)
                                .fill(.primary.opacity(DesignTokens.Opacity.subtle)))
                        Button(
                            recordingAction == action ? L("common.cancel") : L("settings.shortcuts.change")
                        ) { toggleRecording(action) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11))
                        Button(L("settings.shortcuts.reset")) { keys.reset(action) }
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
                Text(L("settings.shortcuts.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text(L("settings.shortcuts.title"))
                    Spacer()
                    Button(L("settings.shortcuts.resetAll")) {
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
                conflictText = L("settings.shortcuts.conflict", stroke.display, clash.title)
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
    @State private var appLanguage = AppLanguage.current
    @State private var askingRestart = false

    var body: some View {
        Form {
            // 界面语言与译文语言是两件事，同一页里分节摆清楚：
            // 前者决定应用自己说什么话，后者决定文章被翻成什么话。
            Section(L("settings.language.interface")) {
                Picker(L("settings.language.interface"), selection: $appLanguage) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: appLanguage) { _, new in
                    new.apply()
                    askingRestart = true
                }
                Text(L("settings.language.interface.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Section(L("settings.translation.title")) {
                Picker(L("settings.translation.engine"), selection: $translationEngine) {
                    Text(L("settings.translation.engine.apple")).tag("apple")
                    Text(L("settings.translation.engine.api")).tag("api")
                }
                if translationEngine == "api" {
                    TextField("Base URL", text: $apiBaseURL, prompt: Text("https://api.example.com/v1"))
                    TextField(L("settings.translation.apiModel"), text: $apiModel)
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) {
                            KeychainStore.set(account: "api-key", value: apiKey)
                        }
                }
                Picker(L("settings.translation.targetLang"), selection: $targetLang) {
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "繁體中文").tag("zh-Hant")
                    Text(verbatim: "English").tag("en")
                    Text(verbatim: "日本語").tag("ja")
                }
                Text(L("settings.translation.targetLang.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Toggle(L("settings.translation.auto"), isOn: $autoTranslateForeign)
                Text(L("settings.translation.auto.note"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(L("settings.language.restart.title"), isPresented: $askingRestart) {
            Button(L("data.restore.later"), role: .cancel) {}
            Button(L("data.restore.now")) { relaunchApp() }
        } message: {
            Text(L("settings.language.restart.message"))
        }
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
            Section(L("settings.refresh.title")) {
                Picker(L("settings.refresh.interval"), selection: $refreshMinutes) {
                    Text(L("settings.refresh.interval.15")).tag(15)
                    Text(L("settings.refresh.interval.30")).tag(30)
                    Text(L("settings.refresh.interval.60")).tag(60)
                    Text(L("settings.refresh.interval.120")).tag(120)
                }
                Text(L("settings.refresh.interval.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Picker(L("settings.refresh.domainInterval"), selection: $domainMinIntervalSeconds) {
                    Text(L("settings.refresh.domainInterval.off")).tag(0)
                    Text(L("settings.refresh.domainInterval.5")).tag(5)
                    Text(L("settings.refresh.domainInterval.10")).tag(10)
                    Text(L("settings.refresh.domainInterval.30")).tag(30)
                }
                Text(L("settings.refresh.domainInterval.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Picker(L("settings.refresh.initialRead"), selection: $newFeedInitialRead) {
                    Text(L("settings.refresh.initialRead.unread")).tag("unread")
                    Text(L("settings.refresh.initialRead.read")).tag("read")
                    Text(L("settings.refresh.initialRead.recent")).tag("recent")
                }
                if newFeedInitialRead == "recent" {
                    Picker(L("settings.refresh.initialRead.keepCount"), selection: $newFeedRecentCount) {
                        ForEach([5, 10, 25, 50], id: \.self) {
                        Text(L("settings.refresh.initialRead.items", $0)).tag($0)
                    }
                    }
                }
                Text(L("settings.refresh.initialRead.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                Picker(L("settings.refresh.defaultFullText"), selection: $defaultFullTextMode) {
                    ForEach(FullTextMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                Text(L("settings.refresh.defaultFullText.note"))
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
            Section(L("settings.retention.section")) {
                Picker(L("settings.retention.count"), selection: $keepCount) {
                    Text(verbatim: "200").tag(200)
                    Text(verbatim: "500").tag(500)
                    Text(verbatim: "1000").tag(1000)
                    Text(verbatim: "2000").tag(2000)
                }
                Picker(L("settings.retention.days"), selection: $keepDays) {
                    Text(L("settings.retention.days.30")).tag(30)
                    Text(L("settings.retention.days.90")).tag(90)
                    Text(L("settings.retention.days.365")).tag(365)
                    Text(L("settings.retention.days.forever")).tag(0)
                }
                Text(L("settings.retention.note"))
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
            Section(L("settings.mute.title")) {
                ForEach(muteRules.value) { rule in
                    HStack(spacing: DesignTokens.Spacing.md) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                            Text(rule.pattern).lineLimit(1)
                            let summary = "\(rule.matchType.label) · \(rule.field.label) · " +
                                "\(scopeLabel(rule)) · \(rule.action.label)"
                            Text(summary)
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
                        .help(L("settings.mute.delete.help"))
                    }
                }
                Button {
                    showingMuteEditor = true
                } label: {
                    Label(L("settings.mute.new"), systemImage: "plus")
                }
                if let muteStatus {
                    Text(muteStatus)
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Text(L("settings.mute.note"))
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
        guard let fid = rule.scopeFeedId else { return L("settings.mute.scope.global") }
        // scopeFeedId 外键随 feed 级联删除，正常总能查到标题；
        // 两条 ValueObservation 异步刷新可能错位一帧，占位符只为这一帧。
        return feeds.value.first { $0.id == fid }?.title ?? "—"
    }

    private func addMuteRule(_ draft: MuteRuleDraft) {
        Task {
            do {
                let count = try await MuteRules.add(AppEnvironment.sharedDB, draft: draft)
                muteStatus = L("settings.mute.saved", count)
            } catch {
                muteStatus = L("settings.mute.saveFailed", error.localizedDescription)
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
            Section(L("settings.data.title")) {
                LabeledContent(L("settings.data.dbPath")) {
                    Text(AppDatabase.defaultPath())
                        .font(.caption)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("data.backup.menu")) { backupDatabase() }
                    Button(L("data.restore.menu")) { restoreDatabase() }
                    Spacer()
                    Button(L("data.backup.openFolder")) {
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
                Text(L("data.backup.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Section(L("update.section.title")) {
                Toggle(L("update.checkOnLaunch"), isOn: $checkUpdatesOnLaunch)
                LabeledContent(L("update.currentVersion")) {
                    Text(UpdateChecker.currentVersion).foregroundStyle(.secondary)
                }
                Text(L("update.section.note"))
                    .font(.system(size: DesignTokens.Typography.caption))
                    .foregroundStyle(.secondary)
                if !skippedUpdateVersion.isEmpty {
                    HStack {
                        Text(L("update.skipped", skippedUpdateVersion))
                            .font(.system(size: DesignTokens.Typography.caption))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("update.unskip")) { skippedUpdateVersion = "" }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert(L("data.restore.needsRelaunch"), isPresented: .constant(pendingRestore != nil)) {
            Button(L("data.restore.later")) { pendingRestore = nil }
            Button(L("data.restore.now")) {
                pendingRestore = nil
                relaunchApp()
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
        panel.message = L("data.backup.panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dataStatus = L("data.backup.running")
        Task {
            do {
                try await Backup.snapshot(AppEnvironment.sharedDB, to: url)
                dataStatus = L("data.backup.done", url.lastPathComponent)
            } catch {
                dataStatus = L("data.backup.failed", error.localizedDescription)
            }
        }
    }

    /// 恢复不当场替换运行中的数据库：校验后落一份待恢复文件，下次启动换过去。
    private func restoreDatabase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data, .data]
        panel.message = L("data.restore.panel")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let info = try Backup.stageRestore(from: url)
            dataStatus = L("data.restore.verified", info.summary)
            pendingRestore = L("data.restore.pending", url.lastPathComponent, info.summary)
        } catch {
            dataStatus = L("data.restore.failed", error.localizedDescription)
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
                Section(L("settings.mute.editor.condition")) {
                    Picker(L("settings.mute.editor.matchType"), selection: $matchType) {
                        ForEach(MuteMatchType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(
                        matchType == .regex
                            ? L("settings.mute.editor.pattern.regex")
                            : L("settings.mute.editor.pattern.keyword"),
                        text: $pattern
                    )
                    Picker(L("settings.mute.editor.field"), selection: $field) {
                        ForEach(MuteRuleField.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section(L("settings.mute.editor.scope")) {
                    Picker(L("settings.mute.editor.scope.appliesTo"), selection: $scope) {
                        Text(L("common.allFeeds")).tag(MuteScopeChoice.all)
                        if !folders.isEmpty {
                            Section(L("common.folders")) {
                                ForEach(folders) { folder in
                                    Text(folder.name).tag(MuteScopeChoice.folder(folder.id!))
                                }
                            }
                        }
                        Section(L("common.feeds")) {
                            ForEach(feeds) { feed in
                                Text(feed.title).tag(MuteScopeChoice.feed(feed.id!))
                            }
                        }
                    }
                }
                Section(L("settings.mute.editor.exceptions")) {
                    TextEditor(text: $exceptions)
                        .font(.system(size: DesignTokens.Typography.body))
                        .frame(height: 72)
                    Text(L("settings.mute.editor.exceptions.note"))
                        .font(.system(size: DesignTokens.Typography.caption))
                        .foregroundStyle(.secondary)
                }
                Section(L("settings.mute.editor.action")) {
                    Picker(L("settings.mute.editor.action.onMatch"), selection: $action) {
                        ForEach(MuteRuleAction.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L("settings.mute.editor.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("settings.mute.editor.save")) {
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
