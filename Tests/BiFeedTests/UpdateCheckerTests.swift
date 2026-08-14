import XCTest
@testable import BiFeed

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"), "按数字比而不是按字符串比")

        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.0", than: "0.1.0"), "只是 tag 带 v 前缀，不算新版本")
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"), "段数不同补 0 后相等")
        XCTAssertFalse(UpdateChecker.isNewer("0.0.9", than: "0.1.0"))
    }

    func testParsesReleasePayload() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/cbl-github/2W/releases/tag/v0.2.0",
         "draft":false,"prerelease":false,"body":"* 修复深色模式黑底黑字\\n* 新增检查更新",
         "assets":[{"name":"2W.dmg","browser_download_url":"https://example.com/2W.dmg"},
                   {"name":"source.zip","browser_download_url":"https://example.com/s.zip"}]}
        """
        let info = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(info.version, "0.2.0")
        XCTAssertEqual(info.tag, "v0.2.0")
        XCTAssertEqual(info.downloadURL?.lastPathComponent, "2W.dmg", "只挑 .dmg 资产")
        XCTAssertTrue(info.notes.hasPrefix("* 修复"))
    }

    func testIgnoresDraftAndPrerelease() {
        let draft = #"{"tag_name":"v9.0.0","html_url":"https://x.example","draft":true}"#
        let pre = #"{"tag_name":"v9.0.0","html_url":"https://x.example","prerelease":true}"#
        XCTAssertNil(UpdateChecker.parse(Data(draft.utf8)), "草稿不推给用户")
        XCTAssertNil(UpdateChecker.parse(Data(pre.utf8)), "预发布不推给用户")
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"v1.0.0"}"#.utf8)), "缺 html_url 不认")
    }
}
