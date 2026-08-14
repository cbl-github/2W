import CryptoKit
import Foundation
import NaturalLanguage

/// 逐段文本块，i 与 ReaderTemplate 内 extract() 输出的段落序号对应。
struct BlockText: Codable {
    var i: Int
    var text: String
}

/// 翻译服务：查缓存、缺的分批喂引擎、新译文落库。状态只在这个类里变。
@MainActor
final class TranslationService: ObservableObject {
    enum State: Equatable {
        case idle
        case translating
        case needsDownload
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// 自动翻译发现模型没装时调用：把按钮切成「下载翻译模型」，但不替用户按下去。
    func markNeedsDownload() { state = .needsDownload }

    /// 译文缓存表按 targetLang 分键，换目标语言后旧译文自然 miss，不需要清缓存。
    nonisolated static var targetLang: String {
        UserDefaults.standard.string(forKey: SettingsKey.translationTargetLang) ?? "zh-Hans"
    }

    /// 源语言与目标语言同族 = 不必翻译（阅读器据此隐藏翻译按钮）。
    /// 目标是中文时沿用方言名单（NLLanguageRecognizer 会把粤语识别成 yue、吴语成 wuu）；
    /// 其他目标语言按 BCP-47 主标签比较，en-GB 对 en 算同族。
    /// 从正文样本判断该不该翻译，以及源语言是什么。返回 nil = 不翻（同族、太短、识别不可信）。
    ///
    /// 不直接信 NLLanguageRecognizer 的三个理由，都是实测撞出来的：
    /// 1. 中英混排的中文资讯（大量英文产品名 + 链接）会被判成荷兰语之类的小语种，
    ///    于是拿一篇纯中文文章去下载「荷兰语」模型。所以先按汉字占比短路。
    /// 2. 样本太短时识别基本是掷骰子，宁可不翻。
    /// 3. 置信度低的结果同样不可用——翻错语言比不翻更烦人。
    nonisolated static func detectSourceLanguage(sample: String, target: String) -> String? {
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 24 else { return nil }
        // CJK 统一表意文字；汉字够多就是中文，不管识别器怎么说
        let cjk = letters.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        let source: String
        if Double(cjk.count) / Double(letters.count) >= 0.15 {
            source = "zh"
        } else {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            let best = recognizer.languageHypotheses(withMaximum: 1).max { $0.value < $1.value }
            guard let best, best.value >= 0.5 else { return nil }
            source = best.key.rawValue
        }
        return sameLanguageFamily(source: source, target: target) ? nil : source
    }

    nonisolated static func sameLanguageFamily(source: String, target: String) -> Bool {
        let source = source.lowercased()
        let target = target.lowercased()
        if target.hasPrefix("zh") { return ["zh", "yue", "wuu"].contains(where: source.hasPrefix) }
        return source.split(separator: "-").first == target.split(separator: "-").first
    }

    private static let batchSize = 40 // 每批喂引擎的段数上限

    private let db: AppDatabase
    private var engine: any TranslationEngine
    private(set) var engineId: String // "apple" | "api"，缓存按引擎隔离

    init(db: AppDatabase, engine: any TranslationEngine, engineId: String) {
        self.db = db
        self.engine = engine
        self.engineId = engineId
    }

    /// 阅读面板改为跨文章复用（修工具栏闪烁）后，切引擎不再靠重建面板生效，
    /// 而是换文章时由面板调这里同步设置。
    func reconfigure(engine: any TranslationEngine, engineId: String) {
        guard engineId != self.engineId else { return }
        self.engine = engine
        self.engineId = engineId
        state = .idle
    }

    /// 返回请求段落的完整译文（按 i 升序）；nil = 引擎失败，原因在 state。
    /// 命中判定 = 缓存行存在且 sourceHash 与当前段落一致；原文变了按未命中重翻并覆盖。
    /// 空白段落不参与翻译也不进返回。DB 错误按工程原则 fail fast。
    func translations(articleId: Int64, blocks: [BlockText], sourceLang: String) async -> [(Int, String)]? {
        let wanted = blocks.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let cache = try! await db.fetchTranslations(articleId: articleId, lang: Self.targetLang, engine: engineId)
        let hashes = Dictionary(uniqueKeysWithValues: wanted.map { ($0.i, Self.sourceHash($0.text)) })
        let missing = wanted.filter { cache[$0.i]?.hash != hashes[$0.i] }.sorted { $0.i < $1.i }

        if missing.isEmpty {
            return wanted.map { ($0.i, cache[$0.i]!.text) }.sorted { $0.0 < $1.0 }
        }

        state = .translating
        var fresh: [(Int, String)] = []
        do {
            for start in stride(from: 0, to: missing.count, by: Self.batchSize) {
                let batch = Array(missing[start ..< min(start + Self.batchSize, missing.count)])
                let translated = try await engine.translate(
                    batch.map(\.text), source: sourceLang, target: Self.targetLang)
                fresh.append(contentsOf: zip(batch, translated).map { ($0.i, $1) })
            }
        } catch {
            if await engine.availability(source: sourceLang, target: Self.targetLang) == .downloadable {
                state = .needsDownload
            } else {
                state = .failed(error.localizedDescription)
            }
            return nil
        }

        try! await db.storeTranslations(
            articleId: articleId, lang: Self.targetLang, engine: engineId,
            rows: fresh.map { (i: $0.0, hash: hashes[$0.0]!, text: $0.1) })
        state = .idle

        // hash 不匹配的段在 cache 里也有旧行，必须先取 fresh。
        let freshByIndex = Dictionary(uniqueKeysWithValues: fresh)
        return wanted.map { ($0.i, freshByIndex[$0.i] ?? cache[$0.i]!.text) }.sorted { $0.0 < $1.0 }
    }

    /// 只读缓存，按 i 升序。
    func cached(articleId: Int64) async -> [(Int, String)] {
        let cache = try! await db.fetchTranslations(articleId: articleId, lang: Self.targetLang, engine: engineId)
        return cache.sorted { $0.key < $1.key }.map { ($0.key, $0.value.text) }
    }

    /// 段落原文指纹，与 FeedParsing.stableHash 同风格：SHA256 全 hex。
    private static func sourceHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
