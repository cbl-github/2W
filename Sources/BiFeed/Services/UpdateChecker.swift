import Foundation

struct UpdateInfo: Equatable, Sendable {
    var version: String       // 规范化后的版本号，如 "0.2.0"
    var tag: String           // release 的原始 tag，如 "v0.2.0"
    var notes: String
    var pageURL: URL
    /// release 里的 .dmg 直链；没有就为 nil，只能去页面下载。
    var downloadURL: URL?
}

enum UpdateError: LocalizedError {
    case rateLimited
    case badResponse

    var errorDescription: String? {
        switch self {
        case .rateLimited: "GitHub 暂时限制了请求频率，过一会儿再试。"
        case .badResponse: "没能读到 GitHub 上的版本信息。"
        }
    }
}

/// 检查 GitHub 上有没有更新版本。应用是 ad-hoc 签名、DMG 分发，装不了自动更新框架，
/// 所以这里只负责「发现并告知」，下载安装交给用户点一下。
enum UpdateChecker {
    static let repo = "cbl-github/2W"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 有更新返回 UpdateInfo，已是最新返回 nil。
    static func check(currentVersion: String = UpdateChecker.currentVersion) async throws -> UpdateInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        // GitHub 要求带 UA，否则 403；未登录额度是每小时 60 次，日检一次绰绰有余。
        request.setValue("2W/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
        guard http.statusCode == 200 else { throw UpdateError.badResponse }
        guard let info = parse(data) else { throw UpdateError.badResponse }
        return isNewer(info.version, than: currentVersion) ? info : nil
    }

    static func parse(_ data: Data) -> UpdateInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        // 草稿和预发布不推给用户
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }
        let dmg = (root["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) }
        return UpdateInfo(
            version: normalized(tag), tag: tag,
            notes: (root["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: page, downloadURL: dmg)
    }

    /// 去掉常见前缀，只留数字段：`v0.2.0` → `0.2.0`。
    static func normalized(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        while let first = s.first, !first.isNumber { s.removeFirst() }
        return s
    }

    /// 按数字段逐位比较，段数不同时短的那个补 0（`0.2` 与 `0.2.0` 相等）。
    /// 非数字段一律当 0——宁可漏报也不要因为 tag 写法怪就天天弹更新。
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalized(candidate).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = normalized(current).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
