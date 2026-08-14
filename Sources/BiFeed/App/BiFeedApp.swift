import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BiFeedApp: App {
    @StateObject private var env = AppEnvironment()
    /// 声明在 App 里，设置面板改主题时两个场景都会重算 body。
    @AppStorage(SettingsKey.appearanceMode) private var appearanceMode = "light"

    /// nil = 不调用方干预，preferredColorScheme(nil) 即跟随系统。默认仍是 "light"（用户定的默认浅色）。
    private var colorScheme: ColorScheme? {
        switch appearanceMode {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(env)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 1180, height: 720)
        .commands { AppCommands(env: env) }

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }

        // 源健康面板（文件菜单 → 源健康…）：独立小窗，与主窗互不干扰
        Window("源健康", id: "feedHealth") {
            FeedHealthView()
                .environmentObject(env)
                .preferredColorScheme(colorScheme)
        }
        .defaultSize(width: 720, height: 440)

        // 快捷键总表（帮助菜单 → BiFeed 快捷键）：独立小窗，尺寸随内容固定
        Window("2W 快捷键", id: "shortcuts") {
            ShortcutsView()
                .preferredColorScheme(colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

/// SettingsKey 本体在 FetchScheduler.swift，翻译引擎与界面相关的键收在这个扩展里。
extension SettingsKey {
    static let translationEngine = "translationEngine" // "apple" | "api"，默认 "apple"
    static let apiBaseURL = "apiBaseURL"
    static let apiModel = "apiModel"
    static let appearanceMode = "appearanceMode"             // "system" | "light" | "dark"，默认 "light"
    static let autoTranslateForeign = "autoTranslateForeign" // 外文文章自动开双语，默认 true
    static let translationTargetLang = "translationTargetLang" // 译文目标语言，默认 "zh-Hans"
    static let checkUpdatesOnLaunch = "checkUpdatesOnLaunch"   // 启动时检查更新，默认 true
    static let skippedUpdateVersion = "skippedUpdateVersion"   // 用户点过「跳过」的版本号

    /// register(defaults:) 可重复调用，键合并进同一注册域。
    static func registerTranslationDefaults() {
        UserDefaults.standard.register(defaults: [
            translationEngine: "apple",
            apiBaseURL: "",
            apiModel: "",
            appearanceMode: "light",
            autoTranslateForeign: true,
            translationTargetLang: "zh-Hans",
            checkUpdatesOnLaunch: true,
            skippedUpdateVersion: "",
        ])
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    /// 全进程唯一 DatabasePool。@StateObject 的观察对象要在 View.init 里建，
    /// 拿不到 EnvironmentObject，统一从这里取。
    static let sharedDB: AppDatabase = try! AppDatabase(path: AppDatabase.defaultPath())

    /// 全进程唯一翻译引擎。TranslationHost 和 TranslationService 必须共用同一实例，
    /// 请求才会汇进同一个 session 队列（DESIGN.md §8 坑 1）。
    static let sharedTranslationEngine = AppleTranslationEngine()

    static let sharedAPIEngine = OpenAICompatibleEngine()

    static func currentEngineId() -> String {
        UserDefaults.standard.string(forKey: SettingsKey.translationEngine) ?? "apple"
    }

    static func currentEngine() -> any TranslationEngine {
        currentEngineId() == "api" ? sharedAPIEngine : sharedTranslationEngine
    }

    let db: AppDatabase
    let fetcher = FeedFetcher()
    @Published var isRefreshing = false
    @Published var showAddFeed = false
    @Published var showSavePage = false
    /// 最近一次「全部标为已读」的名单；非 nil 时列表工具栏出现撤销按钮（手滑保险）
    @Published var undoableReadBatch: [Int64]?

    lazy var scheduler: FetchScheduler = FetchScheduler(
        db: db, fetcher: fetcher,
        onRefreshingChange: { [weak self] refreshing in
            Task { @MainActor in self?.isRefreshing = refreshing }
        },
        onInitialReadBatch: { [weak self] ids in
            Task { @MainActor in self?.undoableReadBatch = ids }
        })

    init() {
        SettingsKey.registerDefaults()
        SettingsKey.registerTranslationDefaults()
        // DB 打不开 = 环境坏了，直接崩（工程原则：fail fast）。
        db = Self.sharedDB
        Task { await scheduler.startAutoRefresh() }
        if UserDefaults.standard.bool(forKey: SettingsKey.checkUpdatesOnLaunch) {
            checkForUpdates(manual: false)
        }
    }

    /// UI 触发的写操作：错误不静默——debug 断言，release 打日志。
    func dbWrite(_ op: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await op() } catch {
                assertionFailure("db write failed: \(error)")
                FileHandle.standardError.write(Data("[2W] db write failed: \(error)\n".utf8))
            }
        }
    }

    func markAllRead(scope: SidebarSelection) {
        Task { @MainActor in
            let ids = try! await db.markAllRead(scope: scope)
            if !ids.isEmpty { undoableReadBatch = ids }
        }
    }

    // MARK: - 更新

    /// 非 nil = 有比当前版本新的 release，界面弹提示。
    @Published var availableUpdate: UpdateInfo?
    @Published var checkingUpdate = false
    /// 手动检查时即使已是最新也要给个回应，自动检查则安静。
    @Published var updateStatus: String?

    func checkForUpdates(manual: Bool) {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        Task { @MainActor in
            defer { checkingUpdate = false }
            do {
                let found = try await UpdateChecker.check()
                guard let found else {
                    if manual { updateStatus = "已是最新版本（\(UpdateChecker.currentVersion)）。" }
                    return
                }
                // 自动检查尊重「跳过此版本」；手动检查是用户主动问，一律回答
                let skipped = UserDefaults.standard.string(forKey: SettingsKey.skippedUpdateVersion)
                if !manual, skipped == found.version { return }
                availableUpdate = found
            } catch {
                if manual { updateStatus = "检查更新失败：\(error.localizedDescription)" }
            }
        }
    }

    func skipUpdate(_ info: UpdateInfo) {
        UserDefaults.standard.set(info.version, forKey: SettingsKey.skippedUpdateVersion)
        availableUpdate = nil
    }

    /// 「这篇及以下标为已读」与保存搜索的全标已读共用；撤销按钮与 markAllRead 同一入口。
    func markRead(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        Task { @MainActor in
            let changed = try! await db.markRead(ids: ids)
            if !changed.isEmpty { undoableReadBatch = changed }
        }
    }

    func undoMarkAllRead() {
        guard let ids = undoableReadBatch else { return }
        undoableReadBatch = nil
        Task { try! await db.markUnread(ids: ids) }
    }

    // MARK: - OPML

    func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        panel.message = "选择 OPML 文件"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task {
            let outlines = try OPML.parse(data: data)
            _ = try await OPML.importOutlines(outlines, into: db)
            await scheduler.refreshAll()
        }
    }

    func exportOPML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        panel.nameFieldStringValue = "2W.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let (folders, feeds) = try await db.pool.read { db in
                (try Folder.fetchAll(db), try Feed.fetchAll(db))
            }
            try OPML.export(folders: folders, feeds: feeds).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("添加订阅…") { env.showAddFeed = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("保存网页…") { env.showSavePage = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("刷新全部") { Task { await env.scheduler.refreshAll() } }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(env.isRefreshing)
            Button("源健康…") { openWindow(id: "feedHealth") }
            Divider()
            Button("导入 OPML…") { env.importOPML() }
            Button("导出 OPML…") { env.exportOPML() }
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") { env.checkForUpdates(manual: true) }
                .disabled(env.checkingUpdate)
        }
        // 系统默认的「BiFeed 帮助」没有内容，整组换成快捷键总表入口
        CommandGroup(replacing: .help) {
            Button("2W 快捷键") { openWindow(id: "shortcuts") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}

/// 快捷键总表：纯静态两列 Grid（键位 | 作用）。键位描述与各监听器实现对齐，改键时同步改这里。
struct ShortcutsView: View {
    private struct Shortcut: Identifiable {
        let key: String
        let action: String
        var id: String { key }
    }

    private static let rows: [Shortcut] = [
        .init(key: "↩", action: "在浏览器打开原文"),
        .init(key: "⌘↩", action: "沉浸模式开关"),
        .init(key: "Esc", action: "退出沉浸模式"),
        .init(key: "Space", action: "翻一屏；到底后跳下一篇未读"),
        .init(key: "j", action: "下一篇"),
        .init(key: "k", action: "上一篇"),
        .init(key: "n", action: "下一篇未读"),
        .init(key: "m", action: "标为已读 / 未读"),
        .init(key: "u", action: "标为已读 / 未读（与 m 同效）"),
        .init(key: "s", action: "加星标 / 取消星标"),
        .init(key: "T", action: "双语对照开关"),
        .init(key: "⌘R", action: "刷新全部"),
        .init(key: "⌘N", action: "添加订阅"),
        .init(key: "⌘⇧N", action: "保存网页"),
        .init(key: "⌘,", action: "设置"),
    ]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline,
             horizontalSpacing: DesignTokens.Spacing.xl, verticalSpacing: 7) {
            ForEach(Self.rows) { row in
                GridRow {
                    Text(row.key)
                        .font(.system(size: DesignTokens.Typography.metadata,
                                      weight: .medium, design: .monospaced))
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .padding(.vertical, DesignTokens.Spacing.xxs)
                        .background(.quaternary,
                                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.small))
                        .gridColumnAlignment(.trailing)
                    Text(row.action)
                        .font(.system(size: DesignTokens.Typography.body))
                }
            }
        }
        .padding(DesignTokens.Spacing.xxxl)
        .fixedSize()
    }
}
