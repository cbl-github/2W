# 本地化

支持简体中文、英语、日语、西班牙语、法语。系统语言不在其中时回落英语
（`Info.plist` 的 `CFBundleDevelopmentRegion` 是 `en`）。

## 目录

```
Localization/
  zh-Hans.lproj/Localizable.strings   源语言，key 的权威清单
  en.lproj/Localizable.strings
  ja.lproj/Localizable.strings
  es.lproj/Localizable.strings
  fr.lproj/Localizable.strings
```

`build.sh` 把这些目录整个拷进 `2W.app/Contents/Resources/`，运行时经 `Bundle.main` 查表。

## 加一条新文案

1. 代码里写 `L("area.component.meaning")`，**不要**直接写中文字面量。
2. 五个 `.strings` 各加一行。
3. `./build.sh` —— 构建前会跑 `scripts/check-localization.sh`，漏了哪个语言会直接报出来并中止。

只想单独跑检查：

```bash
scripts/check-localization.sh
```

## key 的命名

`<区域>.<组件>.<含义>`，全小写，点号分隔。区域取自界面结构：

| 前缀 | 范围 |
|---|---|
| `sidebar.` | 侧栏、订阅右键菜单 |
| `list.` | 文章列表与其工具栏 |
| `reader.` | 阅读器与其工具栏 |
| `settings.` | 设置窗各分类 |
| `feed.` | 订阅相关的表单与弹窗 |
| `search.` | 搜索与保存的搜索 |
| `data.` | 备份、恢复、导入导出 |
| `update.` | 检查更新 |
| `forum.` | 论坛楼层 |
| `error.` | 错误描述 |
| `export.` | 导出的文档内容 |

**改文案不要改 key。** key 是稳定标识，改了等于四个语言集体失配；
只改对应语言那一行的值即可。

## 占位符

`%@` 放字符串，`%lld` 放整数（Swift 的 `Int` 是 64 位，`%d` 在大数上会出错）。

语序不同的语言用编号占位符：

```
"feed.reload.confirm" = "Reload %1$@ after removing %2$lld articles";
```

检查脚本会比对各语言的占位符数量，少写一个会在构建时报出来——
否则 `String(format:)` 要到运行时才崩。

## 不要本地化的中文

- `Services/FeedOrganizer.swift` 里的关键词：那是分组建议的**匹配规则**，翻译等于改逻辑
- `UI/ReaderTemplate.swift` 的 HTML/CSS、`Database/Queries.swift` 的 SQL
- 写到 stderr 的日志（`[2W] …`）：给开发者看的
- OPML 导出文件里的结构性文本
- 数据库 raw value、UserDefaults 的键、URL、bundle id
