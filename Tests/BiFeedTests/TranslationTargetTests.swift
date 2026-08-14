import XCTest
@testable import BiFeed

/// 同族判定决定翻译按钮显隐：判错要么给中文文章挂上翻译按钮，要么让外文文章翻不了。
final class TranslationTargetTests: XCTestCase {
    func testChineseTargetTreatsDialectTagsAsSameFamily() {
        for source in ["zh", "zh-Hans", "zh-Hant", "yue", "wuu"] {
            XCTAssertTrue(
                TranslationService.sameLanguageFamily(source: source, target: "zh-Hans"),
                "\(source) 对中文目标应视为同族")
        }
        XCTAssertFalse(TranslationService.sameLanguageFamily(source: "ja", target: "zh-Hant"))
        XCTAssertFalse(TranslationService.sameLanguageFamily(source: "en", target: "zh-Hans"))
    }

    func testNonChineseTargetComparesPrimarySubtag() {
        XCTAssertTrue(TranslationService.sameLanguageFamily(source: "en", target: "en"))
        XCTAssertTrue(TranslationService.sameLanguageFamily(source: "en-GB", target: "en"))
        XCTAssertTrue(TranslationService.sameLanguageFamily(source: "ja", target: "ja"))
        XCTAssertFalse(TranslationService.sameLanguageFamily(source: "fr", target: "en"))
        XCTAssertFalse(TranslationService.sameLanguageFamily(source: "zh-Hans", target: "en"),
                       "目标是英文时中文源要能翻译")
        XCTAssertFalse(TranslationService.sameLanguageFamily(source: "ja", target: "en"))
    }

    // MARK: - 源语言判定（Paul 实测：中文文章被判成荷兰语，去下载用不到的模型）

    func testChineseArticleIsNotTranslatedToChinese() {
        // 中英混排的中文资讯：大量英文产品名，但汉字占比高
        let sample = """
        概览 要闻
        Google 发布 Gemini 3.7 Flash 模型
        DeepSeek 发布开源智能体框架 DeepSeek Harness 开发者预览版
        OpenAI 联合 Cerebras 推出 GPT-5.6 Sol Ultrafast 模式
        视频版：哔哩哔哩 YouTube
        """
        XCTAssertNil(TranslationService.detectSourceLanguage(sample: sample, target: "zh-Hans"),
                     "汉字占比够高就是中文，不该判成别的语言再去下模型")
    }

    func testChineseArticleStillTranslatesToNonChineseTarget() {
        let sample = "这是一篇完全由中文写成的文章，用来验证目标语言不是中文时仍然会翻译。"
        XCTAssertEqual(TranslationService.detectSourceLanguage(sample: sample, target: "en"), "zh")
    }

    func testEnglishArticleDetected() {
        let sample = """
        The quick brown fox jumps over the lazy dog. This paragraph is long enough
        for the recognizer to be confident about the language it is written in.
        """
        XCTAssertEqual(TranslationService.detectSourceLanguage(sample: sample, target: "zh-Hans"), "en")
        XCTAssertNil(TranslationService.detectSourceLanguage(sample: sample, target: "en-US"),
                     "同族不翻")
    }

    func testTooShortSampleIsNotGuessed() {
        XCTAssertNil(TranslationService.detectSourceLanguage(sample: "Hi", target: "zh-Hans"))
        XCTAssertNil(TranslationService.detectSourceLanguage(sample: "", target: "zh-Hans"))
        XCTAssertNil(TranslationService.detectSourceLanguage(sample: "2026-08-14  #1 #2", target: "zh-Hans"),
                     "几乎没有字母的样本不该拿去猜语言")
    }

    // MARK: - 按源自动翻译（Paul：让我自己设置哪些源自动翻译）

    func testAutoTranslateModeResolution() {
        XCTAssertTrue(AutoTranslateMode.inherit.resolved(global: true))
        XCTAssertFalse(AutoTranslateMode.inherit.resolved(global: false))
        XCTAssertTrue(AutoTranslateMode.always.resolved(global: false), "按源始终，压过全局关闭")
        XCTAssertFalse(AutoTranslateMode.never.resolved(global: true), "按源从不，压过全局开启")
    }

    func testAutoTranslateModePersistsPerFeed() async throws {
        let db = try makeTempDB()
        let feed = try await db.addFeed(url: "https://a.example/rss", title: "A", siteURL: nil, folderId: nil)
        let fresh = try await db.feed(id: feed.id!)
        XCTAssertEqual(fresh?.autoTranslateMode, .inherit, "默认跟随全局")

        try await db.setAutoTranslate(feedId: feed.id!, .never)
        let stored = try await db.feed(id: feed.id!)
        XCTAssertEqual(stored?.autoTranslateMode, .never)

        // 阅读器要拿得到，否则按源开关形同虚设
        try await db.applyFetchSuccess(
            feedId: feed.id!, etag: nil, lastModified: nil,
            items: [MuteEvaluation(item: ParsedItem(
                guid: "g", url: nil, title: "t", author: nil, publishedAt: Date(),
                contentHTML: "<p>x</p>", summaryText: ""), action: nil)])
        let articleId = try await db.pool.read { try Int64.fetchOne($0, sql: "SELECT id FROM article")! }
        let data = try await db.readerData(articleId: articleId)
        XCTAssertEqual(data?.autoTranslateMode, .never)
    }

    /// HN 的 feed 正文只有一个 Comments 链接，样本不足以判语言——
    /// 真正的文字要等楼层注入之后才有（回归见 0.1.3）。
    func testForumStubIsNotEnoughToDetectButThreadTextIs() {
        let stub = "Comments"
        XCTAssertNil(TranslationService.detectSourceLanguage(sample: stub, target: "zh-Hans"),
                     "一个单词判不出语言，不该猜")

        let thread = """
        This is exactly the kind of problem that shows up once you have enough users.
        I ran into the same thing last year and ended up rewriting the whole pipeline.
        """
        XCTAssertEqual(TranslationService.detectSourceLanguage(sample: thread, target: "zh-Hans"), "en",
                       "楼层文字足够长，识别得出来")
    }
}
