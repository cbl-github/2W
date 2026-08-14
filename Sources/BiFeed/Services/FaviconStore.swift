import AppKit
import SwiftUI

/// Favicon 存取：内存 NSCache → 磁盘 favicons/<feedId>.img → nil。
/// .img 存原始字节，格式交给 NSImage 嗅探（ico/png/jpg 都认）。
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    /// 新图标落盘时 +1，驱动 FeedIcon 重新取图。
    @Published private(set) var version = 0

    private let cache = NSCache<NSNumber, NSImage>()
    private let directory: URL
    private var inFlight: Set<Int64> = []
    /// 本会话失败过的源不重试，下次启动自然重试。
    private var failedThisSession: Set<Int64> = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = appSupport.appendingPathComponent("BiFeed/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for feedId: Int64) -> NSImage? {
        let key = NSNumber(value: feedId)
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: feedId)),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// 已有图标/本会话已失败/在途 → 直接返回。
    /// 网络与解析在文件底部的非隔离函数里做，主线程只记账。
    func ensureIcon(feed: Feed, fetcher: FeedFetcher) async {
        guard let feedId = feed.id else { return }
        if FileManager.default.fileExists(atPath: fileURL(for: feedId).path) { return }
        if failedThisSession.contains(feedId) || inFlight.contains(feedId) { return }
        inFlight.insert(feedId)
        defer { inFlight.remove(feedId) }

        guard let page = faviconPageURL(for: feed),
              let data = await fetchBestIconData(page: page, fetcher: fetcher) else {
            failedThisSession.insert(feedId)
            return
        }
        do {
            try data.write(to: fileURL(for: feedId), options: .atomic)
            cache.removeObject(forKey: NSNumber(value: feedId))
            version += 1
        } catch {
            failedThisSession.insert(feedId)
        }
    }

    private func fileURL(for feedId: Int64) -> URL {
        directory.appendingPathComponent("\(feedId).img")
    }
}

/// 有 favicon 显示之，否则回退首字符色块 FeedChip。
struct FeedIcon: View {
    private let feed: Feed
    private let size: CGFloat
    @ObservedObject private var store: FaviconStore

    @MainActor
    init(feed: Feed, size: CGFloat) {
        self.feed = feed
        self.size = size
        self._store = ObservedObject(wrappedValue: FaviconStore.shared)
    }

    var body: some View {
        if let feedId = feed.id, let image = store.image(for: feedId) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            FeedChip(title: feed.title, size: size)
        }
    }
}

// MARK: - 图标发现（文件级私有函数，非隔离：不占主线程）

private struct IconCandidate {
    var url: URL
    var isAppleTouch: Bool
    var size: Int // sizes 属性里最大的数值，没有为 0
}

/// 图标发现的起点页：siteURL 优先，否则退回 feed URL 的 origin。
private func faviconPageURL(for feed: Feed) -> URL? {
    if let site = feed.siteURL, let url = URL(string: site), url.host() != nil {
        return url
    }
    return URL(string: feed.url).flatMap(originURL(of:))
}

private func originURL(of url: URL) -> URL? {
    guard let scheme = url.scheme, let host = url.host() else { return nil }
    let port = url.port.map { ":\($0)" } ?? ""
    return URL(string: "\(scheme)://\(host)\(port)")
}

/// 依次尝试页面声明的候选，最后兜底 <origin>/favicon.ico。
/// 返回第一个能被 NSImage 解码且短边 >= 16 的原始字节。
private func fetchBestIconData(page: URL, fetcher: FeedFetcher) async -> Data? {
    var candidates: [URL] = []
    if let outcome = try? await fetcher.fetch(url: page),
       case .success(let data, _, _, let charset, let finalURL) = outcome {
        let html = CharsetDecoder.decodeToString(data, httpTextEncodingName: charset)
        candidates = iconCandidates(html: html, base: finalURL)
    }
    if let fallback = originURL(of: page)?.appendingPathComponent("favicon.ico"),
       !candidates.contains(fallback) {
        candidates.append(fallback)
    }
    for url in candidates {
        guard let outcome = try? await fetcher.fetch(url: url),
              case .success(let data, _, _, _, _) = outcome,
              let image = NSImage(data: data),
              min(image.size.width, image.size.height) >= 16 else { continue }
        return data
    }
    return nil
}

/// 扫 `<link rel~=icon>` 收集候选：apple-touch-icon 优先，其次 sizes 大者。
/// 跳过 SVG——NSImage 不认。
private func iconCandidates(html: String, base: URL) -> [URL] {
    var found: [IconCandidate] = []
    var seen = Set<URL>()
    for m in html.matches(of: /<link\b[^>]*>/.ignoresCase()) {
        let tag = String(m.0)
        guard tag.contains(/rel\s*=\s*["']?[^"'>]*\bicon\b/.ignoresCase()) else { continue }
        if tag.contains(/type\s*=\s*["']?image\/svg/.ignoresCase()) { continue }
        guard let hrefMatch = tag.firstMatch(of: /href\s*=\s*["']([^"']+)["']/.ignoresCase()) else { continue }
        let href = HTMLTools.decodeEntities(String(hrefMatch.1))
        guard let url = URL(string: href, relativeTo: base)?.absoluteURL else { continue }
        if url.pathExtension.lowercased() == "svg" { continue }
        guard seen.insert(url).inserted else { continue }
        var size = 0
        if let sizesMatch = tag.firstMatch(of: /sizes\s*=\s*["']([^"']+)["']/.ignoresCase()) {
            size = String(sizesMatch.1).matches(of: /\d+/).compactMap { Int($0.0) }.max() ?? 0
        }
        found.append(IconCandidate(
            url: url,
            isAppleTouch: tag.contains(/rel\s*=\s*["']?[^"'>]*apple-touch-icon/.ignoresCase()),
            size: size))
    }
    return found
        .sorted { a, b in
            if a.isAppleTouch != b.isAppleTouch { return a.isAppleTouch }
            return a.size > b.size
        }
        .map(\.url)
}
