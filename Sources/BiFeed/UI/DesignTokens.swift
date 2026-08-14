import SwiftUI

/// 稳定且跨视图复用的视觉常量。系统语义色和一次性尺寸不进令牌表。
enum DesignTokens {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 24
    }

    enum Typography {
        static let micro: CGFloat = 9
        static let caption: CGFloat = 11
        static let metadata: CGFloat = 12
        static let body: CGFloat = 13
        static let control: CGFloat = 14
        static let readerBody: CGFloat = 17.5
    }

    enum Radius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 6
        static let large: CGFloat = 8
    }

    enum Icon {
        static let status: CGFloat = 10
        static let sidebar: CGFloat = 16 // 底栏加号/齿轮；12 时 Paul 反馈太小
        static let control: CGFloat = 15 // 列表头的过滤/搜索圆钮
        /// 阅读器工具栏。ToolbarItemGroup 会把成员挤成一排，图标本身要够大、
        /// 再靠 toolbarIcon() 补左右留白，否则五个图标糊成一团（Paul 反馈）。
        static let toolbar: CGFloat = 16
    }

    /// 工具栏图标的统一尺寸与呼吸空间。间距走 padding 而不是 ToolbarItemGroup 的
    /// 默认排布——后者在 macOS 上不给成员之间留空隙。
    enum ToolbarMetrics {
        static let iconSpacing: CGFloat = 5
    }

    enum Opacity {
        static let readLight = 0.5
        static let readDark = 0.62
        static let subtle = 0.06
    }

    enum Reader {
        static let backgroundLightHex = "#FCFCFC"
        static let backgroundDarkHex = "#1E1E20"

        static let backgroundLight = Color(
            red: 0xFC / 255, green: 0xFC / 255, blue: 0xFC / 255)
        static let backgroundDark = Color(
            red: 0x1E / 255, green: 0x1E / 255, blue: 0x20 / 255)

        static func background(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? backgroundDark : backgroundLight
        }
    }
}

extension View {
    /// 阅读器工具栏按钮的统一外观：放大字形 + 左右留白。
    /// 五个按钮原本紧贴在一起且偏小，看不清也点不准（Paul 反馈）。
    func readerToolbarIcon() -> some View {
        font(.system(size: DesignTokens.Icon.toolbar))
            .padding(.horizontal, DesignTokens.ToolbarMetrics.iconSpacing)
    }
}
