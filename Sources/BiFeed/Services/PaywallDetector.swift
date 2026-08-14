import Foundation

/// 需求 28：疑似付费墙标记。只按域名判断，渲染时算，不写库不加列。
/// 长度异常联合判定有意不做——阈值要等真实抓取样本才定得出来。
enum PaywallDetector {
    /// 已知整站或大部分文章需要订阅的站点。子域自动命中（www.nytimes.com → nytimes.com）。
    static let domains: Set<String> = [
        "nytimes.com", "wsj.com", "ft.com", "economist.com", "bloomberg.com",
        "washingtonpost.com", "newyorker.com", "theatlantic.com", "wired.com",
        "theinformation.com", "caixin.com", "ftchinese.com",
    ]

    static func isLikelyPaywalled(urlString: String?) -> Bool {
        guard let urlString, let host = URL(string: urlString)?.host()?.lowercased() else { return false }
        // 后缀匹配带点，`notnytimes.com` 不会被 `nytimes.com` 命中
        return domains.contains(host) || domains.contains { host.hasSuffix("." + $0) }
    }
}
