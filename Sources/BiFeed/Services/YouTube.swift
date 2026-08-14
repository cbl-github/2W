import Foundation

/// YouTube 专项（需求 18）的纯判定：频道地址 → feed 地址、Shorts 识别、feed 源识别。
/// 只做字符串与 URL 计算，网络在 SubscribeResolver 里发。
enum YouTube {
    /// 订阅输入解析出的目标：feed 地址能直接拼出来，或需要先抓频道页找 channel_id。
    enum ChannelTarget: Equatable {
        case feed(URL)
        case page(URL)
    }

    static func feedURL(channelID: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")
    }

    /// 是不是 YouTube 官方 feed 地址（UI 靠它决定要不要显示 YouTube 专项设置）。
    static func isFeedURL(_ url: String) -> Bool {
        url.contains("youtube.com/feeds/videos.xml")
    }

    /// 频道输入 → 目标。返回 nil = 不是频道地址，交回既有的通用解析流程。
    /// 认这几种形态：`youtube.com/channel/UCxxx`（直接拼）、`youtube.com/@handle`、
    /// `youtube.com/c/xxx`、`youtube.com/user/xxx`、裸 `@handle`（都要抓页面）。
    static func channelTarget(_ input: String) -> ChannelTarget? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 裸 handle 没有主机名，先补成频道页地址；带斜杠或空格的不算
        if text.hasPrefix("@"), !text.contains("/"), !text.contains(" ") {
            return URL(string: "https://www.youtube.com/\(text)").map(ChannelTarget.page)
        }
        // 主机判定必须在补 scheme 之后：没有 scheme 时 URL.host() 恒为 nil
        guard let url = URL(string: text.contains("://") ? text : "https://" + text),
              let host = url.host()?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        if first == "channel", parts.count >= 2, parts[1].hasPrefix("UC") {
            return feedURL(channelID: parts[1]).map(ChannelTarget.feed)
        }
        if first.hasPrefix("@") { return .page(url) }
        if ["c", "user"].contains(first), parts.count >= 2 { return .page(url) }
        return nil // feeds/videos.xml、watch 等一律原样交给通用流程
    }

    /// 频道页 HTML 里的 channel_id。两种来源都试：内嵌 JSON 的 `"channelId":"UCxxx"`，
    /// 和 `<link rel="canonical" href=".../channel/UCxxx">`——不同入口页给的不一样。
    static func channelID(inHTML html: String) -> String? {
        if let m = html.firstMatch(of: /"channelId"\s*:\s*"(UC[A-Za-z0-9_-]{20,})"/) {
            return String(m.1)
        }
        if let m = html.firstMatch(of: /canonical[^>]*\/channel\/(UC[A-Za-z0-9_-]{20,})/) {
            return String(m.1)
        }
        return nil
    }

    /// 条目是不是 Shorts。只认 YouTube 主机上的 `/shorts/` 路径，别的站点同名路径不误伤。
    static func isShorts(_ url: String?) -> Bool {
        guard let url, let parsed = URL(string: url), let host = parsed.host()?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return false }
        return parsed.path().hasPrefix("/shorts/")
    }
}
