import SwiftUI

extension Notification.Name {
    /// T 翻译开关。ArticleListView 发，ReaderView 收。
    static let bifeedToggleTranslate = Notification.Name("bifeedToggleTranslate")
    /// ⌘↩ 沉浸模式开关。ArticleListView 发，ContentView 收。
    static let bifeedToggleImmersive = Notification.Name("bifeedToggleImmersive")
    /// Space 阅读流。ArticleListView 发，ReaderPane 收。
    static let bifeedSpaceAdvance = Notification.Name("bifeedSpaceAdvance")
}

/// 订阅源确定性配色：标题 FNV-1a 哈希→色相。同一标题永远同色。
enum FeedColor {
    static func color(for title: String) -> Color {
        // 饱和度/亮度固定在深浅主题都够对比的区间
        Color(hue: Double(fnv1a(title) % 360) / 360, saturation: 0.60, brightness: 0.72)
    }

    private static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

/// 圆角方块 + 标题首字符，代替千篇一律的 RSS 图标。
struct FeedChip: View {
    let title: String
    let size: CGFloat

    init(title: String, size: CGFloat = 18) {
        self.title = title
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(FeedColor.color(for: title))
            .frame(width: size, height: size)
            .overlay {
                Text(title.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.58, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}
