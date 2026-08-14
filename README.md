# 2W

macOS RSS 阅读器，支持逐段双语对照与论坛回帖。

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black) ![Universal](https://img.shields.io/badge/binary-universal-black) ![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-black)

## 安装

从 [Releases](https://github.com/cbl-github/2W/releases) 下载 `2W.dmg`，拖入「应用程序」。

首次打开被 Gatekeeper 拦截时：系统设置 → 隐私与安全性 → 仍要打开。应用为 ad-hoc 签名。

要求 macOS 15 或更高。二进制为 universal，Apple Silicon 与 Intel 均原生运行。

## 功能

### 翻译

- 逐段插入译文，代码块跳过
- 引擎：系统翻译（离线）或 OpenAI 兼容 API
- 目标语言：简体中文、繁體中文、English、日本語
- 译文按段落、引擎与原文哈希缓存
- 外文文章可自动进入对照模式

### 论坛

- V2EX、Hacker News、Reddit、Lobsters
- 全部 Discourse 站点，按引擎识别而非域名白名单
- 回帖参与逐段翻译
- 原地刷新回帖，不改变阅读位置

### 抓取

- RSS、Atom、JSON Feed
- 网页地址自动发现 feed，多个候选可选择
- YouTube 频道页与 `@handle`，可按源过滤 Shorts
- 条件请求与正文指纹
- 按源设置 User-Agent、刷新间隔、HTTP Basic 凭据
- 同域串行，遵守 `Retry-After`
- 死源可查找新地址并替换

### 整理

- 静音规则：匹配方式、字段、范围、动作四段可配，保存后回扫历史
- 跨源去重，按规范化 URL
- 未读徽标按源或分组关闭
- 保留策略按源覆盖
- 批量退订，按未更新时长与近期未读筛选

### 阅读

- 全键盘操作，键位可改
- 摘要源自动抓取全文，可指定 CSS 选择器
- 全文搜索含正文，可限定范围与时间，可保存为智能源
- 保存单篇网页
- 导出 Markdown，含译文与回帖

### 数据

- SQLite，全部本地
- 一致性快照备份与恢复
- 每日 OPML 自动备份
- 无账号，无云端，无遥测

## 构建

```bash
./build.sh --universal
scripts/make-dmg.sh
```

产物为 `dist/2W.app` 与 `dist/2W.dmg`。仅编译当前架构时 `./build.sh` 即可，只需 Command Line Tools；`--universal` 需要完整 Xcode。

测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## 许可证

GPL-3.0
