# M0 结论：通过，引擎锁定 Apple Translation

日期：2026-08-13。机器：Intel x86_64，macOS 15.7.7 (24G720)。

## 实测数据

| 项 | 值 |
|---|---|
| 可用性 en→zh-Hans | 模型下载后 `installed` |
| 3 段批量翻译（冷） | 2.01 s |
| 3 段批量翻译（热） | 0.34 s |
| 翻译前主进程 RSS | 39.9 MB |
| 翻译后主进程 RSS | 49.5 MB（推理在系统服务进程，不进 app 内存） |
| 译文质量 | 技术文本通顺可用 |

## 决定

1. 翻译引擎 = Apple Translation（TranslationSession），最低系统 macOS 15。
2. DeepL 备选**不实现**（无不必要兜底）；`TranslationEngine` 协议保留，作为引擎边界。

## 学到的坑（已回写 DESIGN.md §8）

- `prepareTranslation()` 在用户点掉下载弹窗后即返回，模型仍在后台下载；此时调 `translations(from:)` 报 `TranslationError … internalError`。返回 ≠ 就绪。
- 正确姿势：翻译入口以 `LanguageAvailability.status == .installed` 为准；`supported` 状态给「下载语言」引导。
- 模型下载走 Apple CDN，本机环境实测约 20 分钟量级，UI 必须把「正在下载」讲清楚，不能看起来像卡死。
