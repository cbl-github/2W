// CLI：打印 en->zh-Hans 的可用状态（installed / supported / unsupported）
import Foundation
import Translation

@main
struct CheckAvail {
    static func main() async {
        let st = await LanguageAvailability().status(
            from: .init(identifier: "en"),
            to: .init(identifier: "zh-Hans"))
        print(String(describing: st))
    }
}
