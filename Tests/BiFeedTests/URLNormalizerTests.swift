import XCTest
@testable import BiFeed

final class URLNormalizerTests: XCTestCase {
    func testStrictNormalizationRemovesOnlyMechanicalAndTrackingDifferences() {
        XCTAssertEqual(
            URLNormalizer.normalized("HTTPS://Example.COM:443/path/?b=2&utm_source=x&a=1#section"),
            "https://example.com/path?a=1&b=2")
        XCTAssertEqual(URLNormalizer.normalized("http://example.com/path"),
                       "http://example.com/path", "http 与 https 不应误合并")
        XCTAssertNil(URLNormalizer.normalized("mailto:hello@example.com"))
    }

    func testYouTubeShareParametersAreStrippedButVideoIDKept() {
        XCTAssertEqual(
            URLNormalizer.normalized("https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=abc123&feature=share"),
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "si/feature 是分享跟踪参数，v 是视频身份")
        XCTAssertEqual(
            URLNormalizer.normalized("https://youtu.be/dQw4w9WgXcQ?si=abc123"),
            "https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(URLNormalizer.normalized("https://example.com/a?id=7&b=1"),
                       "https://example.com/a?b=1&id=7", "普通链接不受这批改动影响")
        XCTAssertEqual(
            URLNormalizer.normalized("https://example.com/a?feature=1&si=2&keep=3"),
            "https://example.com/a?keep=3", "已知跟踪参数表全站生效，不只 YouTube")
    }
}
