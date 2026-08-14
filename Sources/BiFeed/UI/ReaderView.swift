import AppKit
import GRDB
import NaturalLanguage
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Space 到底后请求列表跳到下一篇未读。与 ArticleListView.swift 里的同名私有声明同串
///（"bifeedNextUnread"）；不进 FeedColor.swift 是因为那个文件归 Agent R 管。
private extension Notification.Name {
    static let bifeedNextUnread = Notification.Name("bifeedNextUnread")
}

struct ReaderView: View {
    let articleId: Int64?
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        if let articleId {
            // 不挂 .id：面板跨文章复用，工具栏不重建（用户反馈：每次切换菜单栏闪一下）。
            // 文章切换的状态复位在 ReaderPane.onChange(of: articleId) 手动做。
            ReaderPane(articleId: articleId)
        } else {
            ContentUnavailableView {
                Label(L("reader.empty.title"), systemImage: "doc.richtext")
            } description: {
                Text(L("reader.empty.description"))
            }
        }
    }
}

private struct FullTextFailure {
    var message: String
    var url: URL
    var selector: String?
}

private struct ReaderPane: View {
    let articleId: Int64
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var meta: ArticleMetaObserver
    @StateObject private var service: TranslationService

    @State private var coordinator: WebReader.Coordinator?
    @State private var translated = false
    /// nil = 未识别出主语言、正文无段落或本身是中文——三种情况都不显示翻译按钮
    @State private var sourceLang: String?
    /// 模型下载轮询归本视图管（service.state 对外只读），超时失败态只能记在这里
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadTimedOut = false
    /// "阅读中标未读"的读完观察：滚过 97%（短文停留 10s）自动翻回已读（Paul 的语义：标未读=没读完标记）
    @State private var readCompletionWatch: Task<Void, Never>?
    @State private var forumRefreshing = false
    /// 全文抓取。hasFullText = 库里 extractedHTML 非空；showingFullText = 当前页面渲染的是全文
    ///（两者在「退回原文」时分离：库不动，只换渲染）。非 nil 的 extractTask 占住按钮位转圈。
    @State private var extractTask: Task<Void, Never>?
    @State private var extractFailure: FullTextFailure?
    @State private var hasFullText = false
    @State private var showingFullText = false
    @State private var fullTextProbe: Task<Void, Never>?
    @State private var fullTextMode = FullTextMode.auto
    @State private var fullTextSelector: String?
    @State private var autoExtractAttempted = false
    @AppStorage(SettingsKey.markReadOnScrollEnd) private var markReadOnScrollEnd = false
    /// 当前文章所属源的自动翻译设置，来自 readerData。
    @State private var autoTranslateMode = AutoTranslateMode.inherit
    /// 楼层落地后的二次语言识别每篇只做一次，避免「刷新回帖」反复触发。
    @State private var redetectedAfterForum = false

    init(articleId: Int64) {
        self.articleId = articleId
        _meta = StateObject(wrappedValue: ArticleMetaObserver(db: AppEnvironment.sharedDB))
        // 引擎跟随设置（apple | api）；面板跨文章复用，切引擎在换文章时经 reconfigure 生效
        _service = StateObject(wrappedValue: TranslationService(
            db: AppEnvironment.sharedDB,
            engine: AppEnvironment.currentEngine(),
            engineId: AppEnvironment.currentEngineId()))
    }

    /// 文章切换时的手动复位（原先靠 .id 重建整个面板，代价是工具栏跟着闪）
    private func switchTo(_ id: Int64) {
        meta.track(id)
        translated = false
        sourceLang = nil
        downloadTimedOut = false
        downloadTask?.cancel()
        downloadTask = nil
        extractTask?.cancel()
        extractTask = nil
        extractFailure = nil
        readCompletionWatch?.cancel()
        readCompletionWatch = nil
        hasFullText = false
        showingFullText = false
        fullTextMode = .auto
        fullTextSelector = nil
        autoExtractAttempted = false
        autoTranslateMode = .inherit
        redetectedAfterForum = false
        // 探测新文章是否已有全文，决定按钮初始高亮（页面本身由 readerData 直接给全文）。
        // 结构体闭包捕获的 self.articleId 是旧拷贝，不能拿来做时效判定；靠 cancel + isCancelled 把关。
        fullTextProbe?.cancel()
        fullTextProbe = Task { @MainActor in
            // try?：任务被 cancel 时 GRDB 可能以抛错收场，这里只影响按钮态，吞掉即可
            let state = try? await env.db.fullTextState(articleId: id)
            guard !Task.isCancelled else { return }
            hasFullText = state?.hasFullText == true
            fullTextMode = state?.mode ?? .auto
            fullTextSelector = state?.selector
            showingFullText = hasFullText && fullTextMode != .never
        }
        service.reconfigure(
            engine: AppEnvironment.currentEngine(),
            engineId: AppEnvironment.currentEngineId())
    }

    @Environment(\.colorScheme) private var colorScheme

    /// 与 ReaderTemplate.css 的 --bg 严格同值。WebView 是透明的，
    /// 橡皮筋回弹露出的就是这层背景——不同色就是用户看到的"翻出边界色差"。
    private var readerBackground: Color {
        DesignTokens.Reader.background(for: colorScheme)
    }

    var body: some View {
        WebReader(articleId: articleId) { coord in
            coord.onPageLoaded = { [weak coord] in
                guard let coord else { return }
                Task { @MainActor in await pageDidLoad(coord) }
            }
            // makeCoordinator 发生在渲染期间，直接写 @State 是未定义行为，推迟一拍
            Task { @MainActor in coordinator = coord }
        }
        .background(readerBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let failure = extractFailure {
                fullTextFailureBar(failure)
            }
        }
        .toolbar {
            // 全部按钮显式 borderless：默认样式在动作抢走焦点（如切去浏览器）时会卡在按下态灰色
            ToolbarItemGroup {
                translationControl
                if let article = meta.value {
                    Button {
                        env.dbWrite { [db = env.db] in
                            try await db.setStarred(articleId: articleId, !article.isStarred)
                        }
                    } label: {
                        Label(article.isStarred ? L("list.menu.unstar") : L("list.menu.star"),
                              systemImage: article.isStarred ? "star.fill" : "star")
                            .foregroundStyle(article.isStarred ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .readerToolbarIcon()
                    .help(L("reader.toolbar.star.help"))
                    if let urlString = article.url, let url = URL(string: urlString) {
                        Button {
                            // 推迟一拍让按钮先完成点击态释放再失焦，否则从浏览器回来按钮停在按下态
                            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                        } label: {
                            Label(L("common.openInBrowser"), systemImage: "safari")
                        }
                        .buttonStyle(.borderless)
                    .readerToolbarIcon()
                        .help(L("reader.toolbar.openOriginal.help"))
                        // 论坛帖（V2EX/HN/Reddit）不给抓全文：feed 里正文本就完整、楼层另行渲染，
                        // 对论坛页跑提取只会抓到导航壳子（用户实测：点了就白板）。
                        // 换成「刷新回帖」：原地换楼层 DOM，不重载文档，阅读位置不动（Paul 点名）。
                        if ForumResolver.forumKind(url: article.url, commentsURL: article.commentsURL) != nil {
                            if forumRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Button {
                                    refreshForum()
                                } label: {
                                    Label(
                                        L("reader.toolbar.refreshForum"),
                                        systemImage: "bubble.left.and.text.bubble.right"
                                    )
                                }
                                .buttonStyle(.borderless)
                    .readerToolbarIcon()
                                .help(L("reader.toolbar.refreshForum.help"))
                            }
                        } else {
                            fullTextControl(url: url)
                        }
                    }
                }
                Button {
                    exportMarkdown()
                } label: {
                    Label(L("export.markdown.action"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                    .readerToolbarIcon()
                .help(L("export.markdown.action"))
            }
        }
        // T 由列表的 NSEvent 监听器消费后转发为通知：不挂在按钮上，
        // 按钮被 ProgressView 替换期间快捷键也不会 beep
        .onReceive(NotificationCenter.default.publisher(for: .bifeedToggleTranslate)) { _ in
            guard sourceLang != nil else { return }
            toggleTranslation()
        }
        // Space 阅读流：未到底翻一屏；已到底请求列表跳下一篇未读
        .onReceive(NotificationCenter.default.publisher(for: .bifeedSpaceAdvance)) { _ in
            guard let webView = coordinator?.webView else { return }
            Task { @MainActor in
                // pageDown() 返回 bool，async 版求值安全；页面竞态下求值失败按「已翻页」处理，不跳篇
                guard let more = (try? await webView.evaluateJavaScript("window.__bifeed.pageDown()")) as? Bool
                else { return }
                if !more {
                    NotificationCenter.default.post(name: .bifeedNextUnread, object: nil)
                }
            }
        }
        .onAppear { switchTo(articleId) }
        .onChange(of: articleId) { _, newId in switchTo(newId) }
        // 打开着的文章被手动标未读 → 视为"没读完"，开始读完观察；翻回已读即停
        .onChange(of: meta.value?.isRead) { old, new in
            if old == true, new == false {
                startReadCompletionWatch()
            } else if new == true {
                readCompletionWatch?.cancel()
                readCompletionWatch = nil
            }
        }
        .onDisappear {
            downloadTask?.cancel()
            extractTask?.cancel()
            fullTextProbe?.cancel()
        }
    }

    // MARK: - 翻译控制

    @ViewBuilder
    private var translationControl: some View {
        if sourceLang != nil {
            if downloadTask != nil || service.state == .translating {
                ProgressView().controlSize(.small)
            } else if downloadTimedOut {
                retryButton(help: L("reader.translate.downloadTimeout.help"))
            } else {
                switch service.state {
                case .needsDownload:
                    Button {
                        startDownload()
                    } label: {
                        Label(L("reader.translate.download"), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .readerToolbarIcon()
                    .help(L("reader.translate.download.help"))
                case .failed(let reason):
                    retryButton(help: L("reader.translate.failed.help", reason))
                case .idle, .translating:
                    Button {
                        toggleTranslation()
                    } label: {
                        Label(L("reader.translate.toggle"), systemImage: "translate")
                            .foregroundStyle(translated ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .readerToolbarIcon()
                    .help(L("reader.translate.toggle.help"))
                }
            }
        }
    }

    /// 工具栏按钮与 T 通知共用的开关动作。下载/翻译进行中按钮位被 ProgressView 占用不可点，
    /// 通知路径按同一条件忽略，避免并发重复翻译。
    private func toggleTranslation() {
        guard downloadTask == nil, service.state != .translating else { return }
        if translated {
            disableTranslation()
        } else {
            Task { await enableTranslation() }
        }
    }

    private func retryButton(help: String) -> some View {
        Button {
            downloadTimedOut = false
            Task { await enableTranslation() }
        } label: {
            Label(L("reader.translate.retry"), systemImage: "exclamationmark.arrow.circlepath")
        }
        .buttonStyle(.borderless)
                    .readerToolbarIcon()
        .help(help)
    }

    // MARK: - Markdown 导出

    /// 导出页面当前渲染的内容（全文/原文态跟随 currentData）；文章 id 也从 currentData 取
    ///（self.articleId 的逃逸捕获坑同 pageDidLoad 注释），页面没加载完就什么都不做。
    private func exportMarkdown() {
        guard let data = coordinator?.currentData, let id = data.article.id else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MarkdownExporter.filename(for: data.article.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let translations = await service.cached(articleId: id)
            let thread = try! await env.db.cachedThread(articleId: id)
            let md = MarkdownExporter.markdown(data: data, translations: translations, thread: thread)
            try md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 全文抓取

    /// 三态：未抓取（点击抓取）→ 全文态（高亮，点击退回原文渲染）→ 原文态（点击再进全文）。
    /// 后两态切换只换渲染不动库——契约没有清除方法，extractedHTML 一直保留，下次打开仍直接进全文。
    @ViewBuilder
    private func fullTextControl(url: URL) -> some View {
        if extractTask != nil {
            ProgressView().controlSize(.small)
        } else if fullTextMode == .never {
            Label(L("reader.fullText.disabled"), systemImage: "doc.text.magnifyingglass")
                .foregroundStyle(.tertiary)
                .help(L("reader.fullText.disabled.help"))
        } else {
            Button {
                toggleFullText(url: url)
            } label: {
                Label(L("reader.fullText.extract"), systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(showingFullText ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
                    .readerToolbarIcon()
            .help(showingFullText ? L("reader.fullText.showOriginal") : L("reader.fullText.extract"))
        }
    }

    private func toggleFullText(url: URL) {
        // 任一方向的重载都换掉整个文档，已注入的译文随之消失，双语态归零；
        // didFinish 后 detectLanguage 照常跑，自动翻译条件满足会自己再进双语。
        if showingFullText {
            translated = false
            coordinator?.showOriginal()
            showingFullText = false
        } else if hasFullText {
            translated = false
            coordinator?.reloadCurrent(db: env.db)
            showingFullText = true
        } else {
            startExtract(url: url, selector: fullTextSelector)
        }
    }

    /// 转圈 → 提取 → 入库 → 经 reloadCurrent 重载（readerData 优先返回 extractedHTML）。
    /// 等待期间切走文章：switchTo 已 cancel 本任务且清了 extractTask，这里只入库不碰界面。
    private func startExtract(url: URL, selector: String?) {
        guard extractTask == nil else { return }
        extractFailure = nil
        let id = articleId
        extractTask = Task { @MainActor in
            do {
                let html = try await FullTextExtractor.shared.extract(url: url, selector: selector)
                try await env.db.storeExtractedHTML(articleId: id, html)
                guard !Task.isCancelled else { return }
                extractTask = nil
                hasFullText = true
                showingFullText = true
                translated = false
                coordinator?.reloadCurrent(db: env.db)
            } catch {
                guard !Task.isCancelled else { return }
                extractTask = nil
                extractFailure = FullTextFailure(
                    message: error.localizedDescription, url: url, selector: selector)
            }
        }
    }

    private func fullTextFailureBar(_ failure: FullTextFailure) -> some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(L("reader.fullText.failed", failure.message))
                .font(.system(size: DesignTokens.Typography.metadata))
                .lineLimit(2)
            Spacer()
            Button(L("common.retry")) {
                startExtract(url: failure.url, selector: failure.selector)
            }
            Button(L("reader.fullText.openInBrowser")) {
                DispatchQueue.main.async { NSWorkspace.shared.open(failure.url) }
            }
            Button(L("reader.fullText.neverForFeed")) {
                guard let feedId = meta.value?.feedId else { return }
                fullTextMode = .never
                extractFailure = nil
                env.dbWrite { [db = env.db] in
                    try await db.setFullTextPolicy(feedId: feedId, mode: .never, selector: nil)
                }
            }
        }
        .buttonStyle(.borderless)
                    .readerToolbarIcon()
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .padding(.vertical, DesignTokens.Spacing.md)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - 翻译流程

    /// 注意：onPageLoaded 闭包只在 Coordinator 创建时装一次，捕获的 self.articleId 是
    /// 首篇文章的旧拷贝（struct 逃逸捕获）。链路里的文章 id 必须从 coord.currentData 取，
    /// 它随每次加载更新，才是"当前页面属于哪篇文章"的唯一真相。
    private func pageDidLoad(_ coord: WebReader.Coordinator) async {
        guard let webView = coord.webView,
              let data = coord.currentData,
              let loadedId = data.article.id else { return }
        fullTextMode = data.fullTextMode
        fullTextSelector = data.fullTextSelector
        autoTranslateMode = data.autoTranslateMode
        showingFullText = data.extractedHTML != nil
        hasFullText = hasFullText || data.extractedHTML != nil
        startAutomaticFullTextIfNeeded(data)
        // 「滚动到底已读」：与「打开即已读」互不依赖，两个都关就只能手动标记。
        // loadedId 而不是 self.articleId——本闭包捕获的 self 是首篇文章那份旧拷贝（见上方注释）。
        if markReadOnScrollEnd { startReadCompletionWatch(articleId: loadedId) }
        await detectLanguage(webView: webView, articleId: loadedId)
        await restoreProgress(webView: webView, articleId: loadedId)
        await loadForum(coord, webView: webView, articleId: loadedId)
    }

    private func startAutomaticFullTextIfNeeded(_ data: ReaderData) {
        guard !autoExtractAttempted else { return }
        autoExtractAttempted = true
        guard data.extractedHTML == nil,
              ForumResolver.forumKind(url: data.article.url, commentsURL: data.commentsURL) == nil,
              let rawURL = data.article.url, let url = URL(string: rawURL) else { return }
        let shouldExtract = data.fullTextMode == .always
            || (data.fullTextMode == .auto && FullTextPolicy.looksTruncated(data.html))
        guard shouldExtract else { return }
        startExtract(url: url, selector: data.fullTextSelector)
    }

    /// 恢复上次阅读位置。论坛注入随后会加高页面，但按约定正文位置优先，注入前按比例恢复即可。
    private func restoreProgress(webView: WKWebView, articleId: Int64) async {
        let progress = try! await env.db.readingProgress(articleId: articleId)
        guard progress > 0.03 else { return }
        // setScroll 返回 undefined：async 版 evaluateJavaScript 桥接 nil 会崩，走回调版
        webView.evaluateJavaScript("window.__bifeed.setScroll(\(progress))", completionHandler: nil)
    }

    /// 识别正文主语言，决定翻译按钮显隐；设置中的自动翻译总开关开启时进入双语。
    /// 识别正文主语言并决定要不要自动进入双语。
    ///
    /// 论坛帖的 feed 正文往往只是个占位符——HN 的整篇正文就是一个 `Comments` 链接，
    /// 真正的文字要等楼层注入之后才在页面上。所以这个函数会被调用两次：
    /// 页面加载完一次，楼层落地后再一次（`redetectAfterForum`）。
    private func detectLanguage(webView: WKWebView, articleId: Int64) async {
        // 求值前页面被替换/销毁属生命周期竞态，放弃本次而不是报错
        guard let json = try? await webView.evaluateJavaScript("window.__bifeed.extract()") as? String,
              let decoded = try? JSONDecoder().decode([BlockText].self, from: Data(json.utf8)),
              !decoded.isEmpty else {
            sourceLang = nil
            return
        }
        let sample = String(decoded.map(\.text).joined(separator: "\n").prefix(1000))
        guard let lang = TranslationService.detectSourceLanguage(
            sample: sample, target: TranslationService.targetLang) else {
            sourceLang = nil
            return
        }
        sourceLang = lang
        guard !translated else { return } // 楼层重翻由 showForumThread 负责，别重复触发

        // 按源开关优先于全局开关：inherit 才看设置里的总开关
        let global = UserDefaults.standard.bool(forKey: SettingsKey.autoTranslateForeign)
        guard autoTranslateMode.resolved(global: global) else { return }

        // 自动翻译只在模型已经装好时进行。未装就停在这里——工具栏会显示「下载翻译模型」
        // 按钮由用户决定。否则系统会为没装的语言对自己弹下载框，
        // 用户等于被追着下载一堆自己根本用不到的语言（Paul 实测报的）。
        guard await AppEnvironment.currentEngine().availability(
            source: lang, target: TranslationService.targetLang) == .installed else {
            service.markNeedsDownload()
            return
        }
        await enableTranslation(webView: webView, articleId: articleId)
    }

    /// webView 参数给 didFinish 直达路径用（那一刻 coordinator @State 可能还没写入）
    private func enableTranslation(webView: WKWebView? = nil, articleId: Int64? = nil) async {
        guard !translated, let webView = webView ?? coordinator?.webView else { return }
        if await translateAndInject(webView: webView, articleId: articleId ?? self.articleId) {
            translated = true
        }
    }

    /// 现场重新 extract 再翻译注入：论坛楼层随时可能落地，固定快照会漏掉新段落；
    /// hash 缓存保证已翻段落零成本，inject 幂等跳过已有译文。
    /// 返回 false = 无可翻段落/提取失败（生命周期竞态）或引擎失败（原因在 service.state）。
    @discardableResult
    private func translateAndInject(webView: WKWebView, articleId: Int64) async -> Bool {
        guard let sourceLang,
              let json = try? await webView.evaluateJavaScript("window.__bifeed.extract()") as? String,
              let decoded = try? JSONDecoder().decode([BlockText].self, from: Data(json.utf8)),
              !decoded.isEmpty else { return false }
        // 返回 nil = 失败，原因已进 service.state，按钮态随之切换
        guard let pairs = await service.translations(
            articleId: articleId, blocks: decoded, sourceLang: sourceLang) else { return false }
        // 翻译可能等了几秒（API 引擎更久），期间切走文章就丢弃结果，不往新页面注旧译文。
        // 译文已进缓存，切回来零成本重注。coordinator 为 nil 只发生在首次加载前，此时页面必是本文。
        if let current = coordinator?.currentData?.article.id, current != articleId { return false }
        let data = try! JSONSerialization.data(withJSONObject: pairs.map { [$0.0, $0.1] as [Any] })
        // inject 收 JSON 字符串本体，再编码一层得到合法的 JS 字符串字面量
        let literal = String(
            data: try! JSONEncoder().encode(String(data: data, encoding: .utf8)!), encoding: .utf8)!
        webView.evaluateJavaScript("window.__bifeed.inject(\(literal))", completionHandler: nil)
        return true
    }

    private func disableTranslation() {
        // clear() 返回 undefined：async 版 evaluateJavaScript 桥接 nil 会崩，必须走回调版
        coordinator?.webView?.evaluateJavaScript("window.__bifeed.clear()", completionHandler: nil)
        translated = false
    }

    private func startDownload() {
        guard downloadTask == nil, let sourceLang else { return }
        downloadTimedOut = false
        downloadTask = Task { @MainActor in
            defer { downloadTask = nil }
            // 轮询的必须是 service 正在用的那类引擎（apple | api）
            let engine: any TranslationEngine = AppEnvironment.currentEngine()
            await engine.requestDownload(source: sourceLang, target: TranslationService.targetLang)
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                if await engine.availability(source: sourceLang, target: TranslationService.targetLang) == .installed {
                    await enableTranslation()
                    return
                }
            }
            downloadTimedOut = true
        }
    }

    /// 每 2s 查一次滚动位置；文章切换/标回已读由调用方取消。短到不用滚的文章按停留时间判定。
    private func startReadCompletionWatch(articleId: Int64? = nil) {
        readCompletionWatch?.cancel()
        let id = articleId ?? self.articleId // 省略参数的调用点在 body 里，值是当前文章
        readCompletionWatch = Task { @MainActor in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled,
                      let webView = coordinator?.webView,
                      coordinator?.currentData?.article.id == id else { return }
                let fraction = (try? await webView.evaluateJavaScript(
                    "window.__bifeed.getScroll()") as? Double) ?? 0
                let scrollable = (try? await webView.evaluateJavaScript(
                    "Math.max(0, document.documentElement.scrollHeight - window.innerHeight)") as? Double) ?? 1
                let shortDwell = scrollable <= 40 && ContinuousClock.now - start >= .seconds(10)
                if fraction > 0.97 || shortDwell {
                    env.dbWrite { [db = env.db] in try await db.setRead(articleId: id, true) }
                    return
                }
            }
        }
    }

    // MARK: - 论坛回帖

    /// V2EX / HN / Reddit / Discourse / Lobsters 讨论帖：读缓存与网络抓取并行——缓存先注入立即可读，网络成功后覆盖为最新。
    /// 注入顺序天然安全：缓存注入一定发生在 await 网络结果之前。DB 错误按工程原则 fail fast。
    /// 手动刷新当前帖的楼层：网络拉最新 → 原地替换，不动滚动位置。
    private func refreshForum() {
        guard !forumRefreshing,
              let coord = coordinator, let webView = coord.webView,
              let id = coord.currentData?.article.id else { return }
        forumRefreshing = true
        Task { @MainActor in
            await loadForum(coord, webView: webView, articleId: id, showPlaceholder: false)
            forumRefreshing = false
        }
    }

    private func loadForum(_ coord: WebReader.Coordinator, webView: WKWebView, articleId: Int64,
                           showPlaceholder: Bool = true) async {
        guard let data = coord.currentData,
              let kind = ForumResolver.forumKind(url: data.article.url, commentsURL: data.commentsURL)
        else { return }
        // 手动"刷新回帖"不闪占位符：旧楼层原地保留到新楼层到达，滚动位置零扰动
        if showPlaceholder {
            webView.evaluateJavaScript("window.__bifeed.forumLoading()", completionHandler: nil)
        }
        let fetchTask = Task { [fetcher = env.fetcher] in
            try await ForumResolver.fetch(kind, fetcher: fetcher,
                                          articleAuthor: data.article.author,
                                          articleTitle: data.article.title)
        }
        let cached = try! await env.db.cachedThread(articleId: articleId)
        // 每个 await 之后都要复查页面归属：抓帖是秒级网络等待，期间用户可能已切走文章，
        // 不查就把上一篇的楼层注进下一篇的页面（Paul 实测撞到过）。落库不受影响，只拦注入。
        guard coord.currentData?.article.id == articleId else { return }
        if let cached {
            await showForumThread(cached, in: webView, articleId: articleId)
        }
        do {
            let thread = try await fetchTask.value
            try! await env.db.storeThread(articleId: articleId, thread: thread)
            guard coord.currentData?.article.id == articleId else { return }
            await showForumThread(thread, in: webView, articleId: articleId)
        } catch {
            // 有缓存兜着就静默保留旧楼层；页面已切走也不写错误占位
            guard cached == nil, coord.currentData?.article.id == articleId else { return }
            // Discourse 候选猜错了：清掉「正在加载回帖…」当普通文章看，不给用户看错误条
            if let failure = error as? ForumFailure, case .notForum = failure {
                await setForumHTML("", in: webView)
                return
            }
            let message = ReaderTemplate.escape(L("forum.loadFailed", error.localizedDescription))
            // 先落到局部量：校验脚本按 L 加左括号加引号提取 key，函数名以 L 结尾时会被误当成一条
            let placeholder = "<p class=\"bf-empty\">\(message)</p>"
            await setForumHTML(placeholder, in: webView)
        }
    }

    /// 楼层落地后，正在双语态就补翻：新段落走引擎，旧段落 hash 缓存零成本。
    private func showForumThread(_ thread: ForumThread, in webView: WKWebView, articleId: Int64) async {
        await setForumHTML(ReaderTemplate.forumHTML(thread), in: webView)
        // 楼层里新来的图片也要挂软浮现钩子（模板脚本只处理了初始 DOM）
        webView.evaluateJavaScript("window.__bifeedWireImgs()", completionHandler: nil)
        if translated {
            await translateAndInject(webView: webView, articleId: articleId)
        } else if !redetectedAfterForum {
            // 楼层是这类文章唯一的正文。页面刚加载时样本只有一句占位符，
            // 语言识别要么判错要么判不出（HN 的正文就是一个 Comments 链接），
            // 楼层落地后才有足够的文字可判——这时候重来一次，翻译按钮和自动双语才生效。
            redetectedAfterForum = true
            await detectLanguage(webView: webView, articleId: articleId)
        }
    }

    /// setForum 的参数按契约是「HTML 的 JSON 编码」，再编一层得到合法的 JS 字符串字面量（同 inject）。
    /// setForum 返回 1，非 nil，async 版求值安全。
    private func setForumHTML(_ html: String, in webView: WKWebView) async {
        let payload = String(data: try! JSONEncoder().encode(html), encoding: .utf8)!
        let literal = String(data: try! JSONEncoder().encode(payload), encoding: .utf8)!
        _ = try? await webView.evaluateJavaScript("window.__bifeed.setForum(\(literal))")
    }
}

/// 单 WKWebView 实例复用（设计文档 §4 机制 4）：makeNSView 只走一次生命周期内的必要次数，
/// 文章切换只换内容不换实例。
private struct WebReader: NSViewRepresentable {
    let articleId: Int64
    /// 把 Coordinator 交给上层：翻译控制要拿它对页面执行 JS
    let onReady: (Coordinator) -> Void
    @EnvironmentObject private var env: AppEnvironment

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        onReady(coordinator)
        return coordinator
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // 深色模式下避免切页白闪：不画默认白底
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.loadIfNeeded(articleId: articleId, into: webView, db: env.db)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onPageLoaded: (() -> Void)?
        /// 最近一次加载的数据；阅读进度、导出与论坛流程以它确认当前文章。
        private(set) var currentData: ReaderData?
        private var currentId: Int64?
        private var loadTask: Task<Void, Never>?

        func loadIfNeeded(articleId: Int64, into webView: WKWebView, db: AppDatabase) {
            guard currentId != articleId else { return }
            // 切走前保存旧文章的阅读进度。currentData 与 currentId 比对：
            // 加载被取消时 webView 里可能还是更早文章的页面，比例不能记到旧 id 名下。
            // getScroll 返回 number，回调版求值安全；页面已被替换时 result 非 Double，静默放弃。
            if let oldId = currentId, currentData?.article.id == oldId {
                webView.evaluateJavaScript("window.__bifeed.getScroll()") { result, _ in
                    guard let fraction = result as? Double else { return }
                    Task { try! await db.setReadingProgress(articleId: oldId, fraction) }
                }
            }
            currentId = articleId
            loadTask?.cancel()
            loadTask = Task { @MainActor in
                guard var data = try! await db.readerData(articleId: articleId) else { return }
                guard !Task.isCancelled else { return }
                // 论坛帖永远渲染原文：历史上误存的提取结果（导航壳子）就地作废
                if ForumResolver.forumKind(url: data.article.url, commentsURL: data.commentsURL) != nil {
                    data.extractedHTML = nil
                }
                currentData = data
                // 双向淡场：旧内容 0.08s 淡出（瞬间消失正是"生硬"感的来源），
                // 新内容 didCommit 后淡入。async 上下文里 runAnimationGroup 会解析到
                // async 重载，用 begin/end 分组保持同步语义。
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0.08
                webView.animator().alphaValue = 0
                NSAnimationContext.endGrouping()
                webView.loadHTMLString(
                    ReaderTemplate.page(data),
                    baseURL: data.article.url.flatMap(URL.init(string:)))
            }
        }

        /// 全文抓取后的重载入口：清 currentId 再走 loadIfNeeded，重新查库渲染
        ///（readerData 优先返回 extractedHTML）。currentId 已清，进度保存分支不会误触发。
        func reloadCurrent(db: AppDatabase) {
            guard let webView, let id = currentId else { return }
            currentId = nil
            loadIfNeeded(articleId: id, into: webView, db: db)
        }

        /// 全文态下退回原文渲染（不动库）：抹掉 currentData 里的 extractedHTML 后重走模板，
        /// 库里的 extractedHTML 原样保留，下次打开仍直接进全文。
        func showOriginal() {
            guard let webView, var data = currentData else { return }
            data.extractedHTML = nil
            currentData = data
            webView.alphaValue = 0
            webView.loadHTMLString(
                ReaderTemplate.page(data),
                baseURL: data.article.url.flatMap(URL.init(string:)))
        }

        // 淡入挂 didCommit 而非 didFinish：文档一提交就显示文字，不等资源评估，
        // 用户反馈"文字可以更快出现"。翻译/论坛管线仍等 didFinish。
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                webView.animator().alphaValue = 1
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onPageLoaded?()
        }

        // 点链接 → 默认浏览器（需求 6）；模板自身的 loadHTMLString 放行。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}

/// 单篇文章元数据的可重启观察：面板跨文章复用后不能再用 init 定死查询的 DBObserved。
/// track 换目标时保留旧值直到新值到达——星标按钮不闪空，工具栏保持稳定。
@MainActor
private final class ArticleMetaObserver: ObservableObject {
    @Published private(set) var value: Article?
    private let db: AppDatabase
    private var cancellable: AnyDatabaseCancellable?
    private var trackedId: Int64?

    init(db: AppDatabase) {
        self.db = db
    }

    func track(_ articleId: Int64) {
        guard trackedId != articleId else { return }
        trackedId = articleId
        cancellable = ValueObservation
            .tracking { db in try Article.fetchOne(db, key: articleId) }
            .start(
                in: db.pool,
                scheduling: .async(onQueue: .main),
                onError: { error in fatalError("数据库观察失败: \(error)") },
                onChange: { [weak self] article in self?.value = article })
    }
}
