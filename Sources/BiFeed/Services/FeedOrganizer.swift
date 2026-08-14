import Foundation

/// 辅助手动整理，不自动执行（Paul 明确：不要一键整理，要"整理时更顺手"）。
/// 只在两处出现：右键「移动到分组」子菜单置顶的建议项、拖拽目标高亮。
enum FeedOrganizer {
    /// 给未分组的 feed 建议一个已存在的分组。两条确定性启发式，按置信度排序：
    /// 1. 同根域名跟随：某分组里已有同根域名的源。
    /// 2. 组名关键词：分组名含关键词，feed 的域名/标题命中该关键词的特征集。
    static func suggestFolder(for feed: Feed, folders: [Folder], feeds: [Feed]) -> Folder? {
        guard feed.folderId == nil, !folders.isEmpty else { return nil }

        if let host = rootDomain(of: feed) {
            for other in feeds where other.folderId != nil && other.id != feed.id {
                if rootDomain(of: other) == host {
                    return folders.first { $0.id == other.folderId }
                }
            }
        }

        let haystack = "\(feed.title) \(feed.siteURL ?? feed.url)".lowercased()
        for folder in folders {
            let name = folder.name.lowercased()
            for (keywords, patterns) in Self.keywordMap {
                guard keywords.contains(where: { name.contains($0) }) else { continue }
                if patterns.contains(where: { haystack.contains($0) }) { return folder }
            }
        }
        return nil
    }

    /// 组名关键词 → feed 特征。特征只认高置信的站点/词，宁缺毋滥。
    private static let keywordMap: [([String], [String])] = [
        (["论坛", "社区", "forum"], ["v2ex", "ycombinator", "reddit", "chiphell", "hostloc", "linux.do"]),
        (["新闻", "资讯", "news"], ["news", "日报", "早报", "reuters", "bbc", "nytimes", "theverge", "36kr", "ithome"]),
        (["博客", "blog"], ["blog", "博客", ".me/", "willison", "daringfireball"]),
        (["开发", "技术", "编程", "dev"], ["github", "developer", "engineering", "swift", "rust", "python"]),
    ]

    /// 取注册域（粗版：末两段），失败返回 nil。
    static func rootDomain(of feed: Feed) -> String? {
        guard let host = URL(string: feed.siteURL ?? feed.url)?.host() else { return nil }
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return parts.suffix(2).joined(separator: ".")
    }
}
