import AppKit
import Foundation

/// 可重绑定的快捷键动作。rawValue 兼作 UserDefaults 存储键的一部分，改名即迁移断裂——别改。
enum KeyAction: String, CaseIterable, Identifiable {
    case nextArticle, prevArticle, nextUnread
    case toggleRead, toggleReadAlias, toggleStar
    case translate, openOriginal, immersive, spaceAdvance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nextArticle: "下一篇"
        case .prevArticle: "上一篇"
        case .nextUnread: "下一篇未读"
        case .toggleRead: "已读/未读"
        case .toggleReadAlias: "已读/未读（备用键）"
        case .toggleStar: "星标"
        case .translate: "双语对照"
        case .openOriginal: "在浏览器打开原文"
        case .immersive: "阅读模式"
        case .spaceAdvance: "翻一屏 / 到底跳下一篇未读"
        }
    }
}

/// 单个键位：主键字符（小写；特殊键用 "return"/"space"/"escape"）+ 修饰键集合。
struct KeyStroke: Codable, Equatable {
    var key: String
    var command = false
    var option = false
    var control = false
    var shift = false

    /// 展示用符号串，如 "⌘↩"、"T"、"Space"
    var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "return": s += "↩"
        case "space": s += "Space"
        case "escape": s += "Esc"
        default: s += key.uppercased()
        }
        return s
    }

    static func from(event: NSEvent) -> KeyStroke? {
        let mods = event.modifierFlags
        let key: String
        switch event.keyCode {
        case 36: key = "return"
        case 49: key = "space"
        case 53: key = "escape"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
                  let scalar = chars.unicodeScalars.first,
                  scalar.properties.isAlphabetic || scalar.properties.numericType != nil else { return nil }
            key = chars
        }
        return KeyStroke(
            key: key,
            command: mods.contains(.command),
            option: mods.contains(.option),
            control: mods.contains(.control),
            shift: mods.contains(.shift))
    }
}

/// 键位表：默认值 + UserDefaults 覆盖层。监听器与设置页共用这一份真相。
@MainActor
final class KeyBindings: ObservableObject {
    static let shared = KeyBindings()
    private static let storeKey = "keyBindings" // [action.rawValue: JSON(KeyStroke)]

    static let defaults: [KeyAction: KeyStroke] = [
        .nextArticle: KeyStroke(key: "j"),
        .prevArticle: KeyStroke(key: "k"),
        .nextUnread: KeyStroke(key: "n"),
        .toggleRead: KeyStroke(key: "m"),
        .toggleReadAlias: KeyStroke(key: "u"),
        .toggleStar: KeyStroke(key: "s"),
        .translate: KeyStroke(key: "t"),
        .openOriginal: KeyStroke(key: "return"),
        .immersive: KeyStroke(key: "return", command: true),
        .spaceAdvance: KeyStroke(key: "space"),
    ]

    @Published private(set) var bindings: [KeyAction: KeyStroke]
    /// 设置页录制新键位期间置真：全局监听器让路，避免录制的键被当成动作消费
    @Published var isRecording = false

    private init() {
        bindings = Self.defaults
        if let raw = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: Data] {
            for (name, data) in raw {
                if let action = KeyAction(rawValue: name),
                   let stroke = try? JSONDecoder().decode(KeyStroke.self, from: data) {
                    bindings[action] = stroke
                }
            }
        }
    }

    /// 事件 → 动作。修饰键必须精确相等（含"无修饰"），避免 T 吃掉 ⌘T 之类的歧义。
    func action(for event: NSEvent) -> KeyAction? {
        guard let stroke = KeyStroke.from(event: event) else { return nil }
        return bindings.first { $0.value == stroke }?.key
    }

    /// 返回与新键位冲突的既有动作（排除自己）。
    func conflict(of stroke: KeyStroke, excluding action: KeyAction) -> KeyAction? {
        bindings.first { $0.key != action && $0.value == stroke }?.key
    }

    func set(_ stroke: KeyStroke, for action: KeyAction) {
        bindings[action] = stroke
        persist()
    }

    func reset(_ action: KeyAction) {
        bindings[action] = Self.defaults[action]
        persist()
    }

    func resetAll() {
        bindings = Self.defaults
        UserDefaults.standard.removeObject(forKey: Self.storeKey)
    }

    private func persist() {
        var raw: [String: Data] = [:]
        for (action, stroke) in bindings where stroke != Self.defaults[action] {
            raw[action.rawValue] = try! JSONEncoder().encode(stroke)
        }
        UserDefaults.standard.set(raw, forKey: Self.storeKey)
    }
}
