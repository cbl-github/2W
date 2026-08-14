# 2W

一款RSS阅读器。

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black) ![Universal](https://img.shields.io/badge/binary-universal-black) ![SwiftUI](https://img.shields.io/badge/SwiftUI-%2B%20GRDB-black)

## 背景

我一直认为质量低的vibe软件不配收费，所以做出来了这一款阅读器狙击同类竞品。软件开发过程参考了reddit上用户的痛点和需求，以及我个人的一些想法。


## 功能实现

### 双语对照

- 段落翻译，本地orAI
- 外文文章可设为自动进入对照模式

### 论坛特殊适配

抓取论坛例如V2EX的评论：

- **V2EX**（官方 API）、**Hacker News**（Algolia，嵌套评论树）
- **Reddit**（评论树 + RSS 正文重排）
- **所有 Discourse 站点**——按引擎识别而不是域名白名单，`linux.do`、Rust/Swift 官方论坛开箱即用；
- **Lobsters**
- 「刷新回帖」原地更新楼层，阅读位置不动

### 订阅与抓取

- RSS / Atom / JSON Feed；贴网页地址自寻 feed
- YouTube 频道页或 `@handle` 直接订阅，可按源过滤 Shorts
- 同域名串行抓取、跨域并发，遵守 `Retry-After`
- 403/429 只暂缓不判死刑，404/410 才停自动重试并标红
- 拖拽整理分组，OPML 导入导出

### 让信息量可控

- **静音规则**：包含或正则 × 标题/正文/作者/URL/分类 × 全局/分组/单源 × 隐藏/标已读/折叠，可加例外词。
- **跨源去重**：不同订阅的同一篇文章在聚合视图里只出现一次，标注来源数。
- **未读徽标可按源或按分组关闭**，高频源不再淹没未读总数
- **保留策略**可全局设也可按源覆盖，星标永久保留
- **源健康面板**：可批量退订阅读量少的源


> Swift 模块名不能以数字开头，所以仓库里的 target 仍叫 `BiFeed`——那是这个项目的旧名字，产物和界面都是 2W。
