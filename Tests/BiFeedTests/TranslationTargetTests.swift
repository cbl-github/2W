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
}
