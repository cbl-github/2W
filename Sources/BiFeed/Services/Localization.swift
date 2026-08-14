import AppKit
import Foundation

/// 取本地化文案。**所有面向用户的文字都必须经过这里**，没有例外。
///
/// 为什么统一走一个函数，而不是让 SwiftUI 自动本地化字面量：
/// 自动本地化只对 `LocalizedStringKey` 类型的参数生效，`String` 类型的（错误描述、
/// enum 的 label、拼装出来的句子）不生效——两套规则混用，漏掉哪个只能靠人眼发现。
/// 全部走 `L()` 之后，「哪些字符串要翻译」变成一个可以被脚本精确提取的事实，
/// `scripts/check-localization.sh` 才能在每次构建时校验有没有漏译。
///
/// key 用符号名（`sidebar.today`）而不是中文原文：改一个字不会让四个语言的表
/// 集体失配，也不会在 .strings 里留下一堆长句当键。
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// 带参数的本地化文案。key 里用 `%@`（字符串）或 `%lld`（整数，Swift 的 Int 是 64 位）。
///
/// 参数顺序在某些语言里必须调换，翻译时用 `%1$@` `%2$@` 显式编号即可，
/// String(format:) 原生支持。
func L(_ key: String, _ arguments: any CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}

// MARK: - 界面语言

/// 应用界面语言。跟随系统时不写覆盖，交给 macOS 按系统偏好挑 .lproj。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case spanish = "es"
    case french = "fr"

    var id: String { rawValue }

    /// 每种语言用它自己的写法呈现——语言选择器里让人认得出自己的母语，
    /// 而不是翻译成当前界面语言（macOS 系统设置也是这么做的）。
    var label: String {
        switch self {
        case .system: L("settings.language.system")
        case .zhHans: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .spanish: "Español"
        case .french: "Français"
        }
    }

    /// 写进 AppleLanguages。bundle 的 .lproj 在启动时就已选定，所以改完要重启才生效。
    func apply() {
        let defaults = UserDefaults.standard
        switch self {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        default: defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    static var current: AppLanguage {
        guard let override = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        else { return .system }
        return AppLanguage(rawValue: override) ?? .system
    }
}

/// 重启应用。改界面语言与恢复备份都要用。
@MainActor
func relaunchApp() {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
