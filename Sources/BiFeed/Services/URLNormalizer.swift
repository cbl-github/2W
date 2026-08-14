import Foundation

enum URLNormalizer {
    /// YouTube 的分享参数 si / feature 也在内（需求 18）：同一个视频从不同来源进来才能去重。
    private static let trackingNames: Set<String> = [
        "fbclid", "gclid", "dclid", "igshid", "mc_cid", "mc_eid", "ref_src", "si", "feature",
    ]

    /// 只做可解释的严格规范化；不合并 http/https、www/裸域名或相似路径。
    static func normalized(_ raw: String?) -> String? {
        guard let raw, var parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased() else { return nil }
        parts.scheme = scheme
        parts.host = host
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) {
            parts.port = nil
        }
        while parts.percentEncodedPath.count > 1 && parts.percentEncodedPath.hasSuffix("/") {
            parts.percentEncodedPath.removeLast()
        }
        parts.fragment = nil
        let query = (parts.queryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingNames.contains(name)
        }.sorted {
            let left = ($0.name.lowercased(), $0.value ?? "")
            let right = ($1.name.lowercased(), $1.value ?? "")
            return left < right
        }
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url?.absoluteString
    }
}
