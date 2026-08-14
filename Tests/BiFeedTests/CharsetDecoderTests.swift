import XCTest
@testable import BiFeed

final class CharsetDecoderTests: XCTestCase {
    func testGB2312DeclarationDecodes() throws {
        let xml = "<?xml version=\"1.0\" encoding=\"gb2312\"?><rss><channel><title>中文测试标题</title></channel></rss>"
        let gbData = try XCTUnwrap(xml.data(using: CharsetDecoder.gb18030))
        let out = String(decoding: CharsetDecoder.decodeToUTF8(gbData, httpTextEncodingName: nil), as: UTF8.self)
        XCTAssertTrue(out.contains("中文测试标题"), "GB2312 声明的内容应正确解码")
        XCTAssertTrue(out.contains("encoding=\"utf-8\""), "XML 声明应改写为 utf-8")
        XCTAssertFalse(out.contains("gb2312"))
    }

    func testHTTPHeaderCharsetWins() throws {
        let text = "<?xml version=\"1.0\"?><rss><channel><title>标题</title></channel></rss>"
        let gbData = try XCTUnwrap(text.data(using: CharsetDecoder.gb18030))
        let out = String(decoding: CharsetDecoder.decodeToUTF8(gbData, httpTextEncodingName: "gbk"), as: UTF8.self)
        XCTAssertTrue(out.contains("标题"))
    }

    func testUTF8BOMStripped() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><rss/>".utf8))
        let out = String(decoding: CharsetDecoder.decodeToUTF8(data, httpTextEncodingName: nil), as: UTF8.self)
        XCTAssertTrue(out.hasPrefix("<?xml"), "BOM 应被剥掉")
    }

    func testPlainUTF8PassThrough() {
        let text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss><channel><title>Fine — ✓</title></channel></rss>"
        let out = String(decoding: CharsetDecoder.decodeToUTF8(Data(text.utf8), httpTextEncodingName: nil), as: UTF8.self)
        XCTAssertTrue(out.contains("Fine — ✓"))
    }
}
