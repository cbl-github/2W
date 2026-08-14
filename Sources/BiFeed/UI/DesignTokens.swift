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
        static let control: CGFloat = 14
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
