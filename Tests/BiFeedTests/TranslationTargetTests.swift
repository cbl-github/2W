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
}
