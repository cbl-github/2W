import XCTest
@testable import BiFeed

final class OPMLTests: XCTestCase {
    func testParseNestedOutlines() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>t</title></head><body>
          <outline text="孤儿源" type="rss" xmlUrl="https://a.example/feed"/>
          <outline text="技术">
            <outline text="HN" type="rss" xmlUrl="https://news.ycombinator.com/rss"/>
            <outline text="子层">
              <outline text="Deep" type="rss" xmlUrl="https://deep.example/rss"/>
            </outline>
          </outline>
        </body></opml>
        """
        let roots = try OPML.parse(data: Data(opml.utf8))
        XCTAssertEqual(roots.count, 2)
        XCTAssertEqual(roots[0].xmlURL, "https://a.example/feed")
        XCTAssertNil(roots[1].xmlURL)
        XCTAssertEqual(roots[1].children.count, 2)
        XCTAssertEqual(roots[1].children[1].children.first?.xmlURL, "https://deep.example/rss")
    }

    func testImportAndExportRoundTrip() async throws {
        let db = try makeTempDB()
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0"><head><title>t</title></head><body>
          <outline text="孤儿源" type="rss" xmlUrl="https://a.example/feed"/>
          <outline text="技术">
            <outline text="HN" type="rss" xmlUrl="https://news.ycombinator.com/rss"/>
          </outline>
        </body></opml>
        """
        let imported = try await OPML.importOutlines(OPML.parse(data: Data(opml.utf8)), into: db)
        XCTAssertEqual(imported, 2)

        let (folders, feeds) = try await db.pool.read { db in
            (try Folder.fetchAll(db), try Feed.fetchAll(db))
        }
        XCTAssertEqual(folders.map(\.name), ["技术"])
        XCTAssertEqual(feeds.count, 2)
        XCTAssertEqual(feeds.first { $0.title == "HN" }?.folderId, folders[0].id)

        let exported = OPML.export(folders: folders, feeds: feeds)
        XCTAssertTrue(exported.contains("xmlUrl=\"https://news.ycombinator.com/rss\""))
        XCTAssertTrue(exported.contains("<outline text=\"技术\""))
    }
}

func makeTempDB() throws -> AppDatabase {
    let path = NSTemporaryDirectory() + "bifeed-test-\(UUID().uuidString)/t.sqlite"
    return try AppDatabase(path: path)
}
