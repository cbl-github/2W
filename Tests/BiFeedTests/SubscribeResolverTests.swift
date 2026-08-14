import XCTest
@testable import BiFeed

final class SubscribeResolverTests: XCTestCase {
    func testProbeURLsOrderAndSiteRoot() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/blog/2026/post.html?x=1"))
        XCTAssertEqual(SubscribeResolver.probeURLs(for: page).map(\.absoluteString), [
            "https://example.com/feed",
            "https://example.com/rss",
            "https://example.com/atom.xml",
            "https://example.com/index.xml",
            "https://example.com/feed.json",
            "https://example.com/rss/",
            "https://example.com/?feed=rss2",
        ])
    }

    func testProbeURLsKeepPortAndScheme() throws {
        let page = try XCTUnwrap(URL(string: "http://example.com:8080/a/b"))
        let urls = SubscribeResolver.probeURLs(for: page)
        XCTAssertEqual(urls.count, 7)
        XCTAssertEqual(urls.first?.absoluteString, "http://example.com:8080/feed")
        XCTAssertEqual(urls.last?.absoluteString, "http://example.com:8080/?feed=rss2")
    }
}
