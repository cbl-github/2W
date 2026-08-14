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
