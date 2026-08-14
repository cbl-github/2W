import Foundation

struct OPMLOutline {
    var title: String
    var xmlURL: String?      // 有 = 订阅
    var children: [OPMLOutline] = []
}

enum OPML {
    // MARK: - 导入

    static func parse(data: Data) throws -> [OPMLOutline] {
        let delegate = OPMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseFailure.unparseable(parser.parserError?.localizedDescription ?? "OPML 格式错误")
        }
        return delegate.roots
    }

    /// 顶层无 xmlUrl 的 outline 当分组；分组只认一层（OPML 常见形态），更深的嵌套拍平进最近的分组。
    static func importOutlines(_ outlines: [OPMLOutline], into db: AppDatabase) async throws -> Int {
        var imported = 0
        func feeds(in outline: OPMLOutline) -> [OPMLOutline] {
            var result: [OPMLOutline] = []
            if outline.xmlURL != nil { result.append(outline) }
            for child in outline.children { result.append(contentsOf: feeds(in: child)) }
            return result
        }
        for outline in outlines {
            if outline.xmlURL != nil {
                if let f = try? await db.addFeed(url: outline.xmlURL!, title: outline.title, siteURL: nil, folderId: nil), f.id != nil {
                    imported += 1
                }
            } else {
                let folder = try await db.addFolder(name: outline.title)
                for feedOutline in feeds(in: outline) {
                    if let f = try? await db.addFeed(url: feedOutline.xmlURL!, title: feedOutline.title,
                                                     siteURL: nil, folderId: folder.id), f.id != nil {
                        imported += 1
                    }
                }
            }
        }
        return imported
    }

    // MARK: - 导出

    /// 非 http(s) 的源不导出：手动保存的容器源（bifeed://）对别的阅读器没有意义，订也订不了。
    static func export(folders: [Folder], feeds allFeeds: [Feed]) -> String {
        let feeds = allFeeds.filter(\.isFetchable)
        var body = ""
        func outline(_ feed: Feed, indent: String) -> String {
            "\(indent)<outline type=\"rss\" text=\"\(escape(feed.title))\" title=\"\(escape(feed.title))\" xmlUrl=\"\(escape(feed.url))\"\(feed.siteURL.map { " htmlUrl=\"\(escape($0))\"" } ?? "")/>\n"
        }
        for feed in feeds.filter({ $0.folderId == nil }) {
            body += outline(feed, indent: "    ")
        }
        for folder in folders {
            body += "    <outline text=\"\(escape(folder.name))\" title=\"\(escape(folder.name))\">\n"
            for feed in feeds.filter({ $0.folderId == folder.id }) {
                body += outline(feed, indent: "      ")
            }
            body += "    </outline>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>BiFeed 订阅</title></head>
          <body>
        \(body)  </body>
        </opml>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class OPMLParserDelegate: NSObject, XMLParserDelegate {
    var roots: [OPMLOutline] = []
    private var stack: [OPMLOutline] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard name == "outline" else { return }
        let title = attributes["title"] ?? attributes["text"] ?? "(未命名)"
        stack.append(OPMLOutline(title: title, xmlURL: attributes["xmlUrl"]))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "outline", let finished = stack.popLast() else { return }
        if stack.isEmpty {
            roots.append(finished)
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }
}
