import Foundation
import WebKit

enum FullTextExtractError: LocalizedError {
    case loadFailed(String)
    case timeout
    case scriptFailed(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .loadFailed(let message): return "页面加载失败：\(message)"
        case .timeout: return "页面加载超时（20 秒）"
        case .scriptFailed(let message): return "正文提取失败：\(message)"
        case .emptyContent: return "未能提取到正文"
        }
    }
}

/// 隐藏 WKWebView 加载文章 URL，注入内置 Readability 精简版提取正文 HTML。
/// 页面 JS 照常执行——很多站点正文靠 JS 渲染，这正是走 WebView 而非裸 HTTP 的意义。
/// 并发 1：提取由用户手动触发，串行排队足够。
@MainActor
final class FullTextExtractor {
    static let shared = FullTextExtractor()
    private init() {}

    /// 串行链队尾。新任务先等它结束（无论成败）再开始，天然排队。
    private var tail: Task<Void, Never>?

    func extract(url: URL, selector: String? = nil) async throws -> String {
        try await extractPage(url: url, selector: selector).html
    }

    /// 正文 + 页面标题。标题取实时 DOM 的 `<title>`（WKWebView.title），JS 改过的标题也拿得到；
    /// 页面没标题时为 nil。手动保存单篇网页（需求 26）用这条。
    func extractPage(url: URL, selector: String? = nil) async throws -> (title: String?, html: String) {
        let previous = tail
        let task = Task<(title: String?, html: String), any Error> {
            _ = await previous?.value
            return try await self.performExtract(url: url, selector: selector)
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: - 单次提取

    private func performExtract(url: URL, selector: String?) async throws -> (title: String?, html: String) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // 隐藏页面不许自动出声
        config.mediaTypesRequiringUserActionForPlayback = .all
        // 1×1、不进视图树。每次新建实例：页面状态干净，提取完随作用域释放。
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter // webView 弱持有 delegate，waiter 靠本作用域保活

        webView.load(URLRequest(url: url))
        let timeout = Task { @MainActor [weak webView] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            webView?.stopLoading()
            waiter.finish(.failure(FullTextExtractError.timeout))
        }
        defer { timeout.cancel() }
        try await waiter.wait()

        // didFinish 只保证主文档加载完，SPA 的正文可能还在渲染：先落定一拍，太短再多等一次
        try? await Task.sleep(for: .seconds(1))
        var html = try await runExtractionScript(in: webView, selector: selector)
        if html.count < 200 {
            try? await Task.sleep(for: .seconds(2.5))
            html = try await runExtractionScript(in: webView, selector: selector)
        }
        guard html.count >= 200 else { throw FullTextExtractError.emptyContent }
        let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil, html)
    }

    private func runExtractionScript(in webView: WKWebView, selector: String?) async throws -> String {
        do {
            // 脚本保证返回字符串：async 版 evaluateJavaScript 桥接 nil 会崩，不能返回 undefined/null
            let literal = selector.flatMap {
                try? JSONEncoder().encode($0)
            }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            let script = Self.extractionScript.replacingOccurrences(
                of: "CUSTOM_SELECTOR_JSON", with: literal)
            let result = try await webView.evaluateJavaScript(script)
            return (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            throw FullTextExtractError.scriptFailed(error.localizedDescription)
        }
    }
}

/// 导航结果的一次性等待器：didFinish / didFail / 超时谁先到谁算，后到的静默丢弃。
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            continuation = c
        }
    }

    func finish(_ result: Result<Void, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(.failure(FullTextExtractError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        finish(.failure(FullTextExtractError.loadFailed(error.localizedDescription)))
    }
}

// MARK: - 内置提取脚本

extension FullTextExtractor {
    /// Readability 精简版：p/pre 密度选正文容器 → 清噪声标签与噪声类名 → 绝对化 img/a 地址。
    /// 永远返回字符串（找不到正文返回 ""）。
    private static let extractionScript = #"""
    (function () {
      "use strict";
      if (!document.body) { return ""; }

      var customSelector = CUSTOM_SELECTOR_JSON;

      var NOISE_TAGS = "script,style,noscript,template,link,meta,nav,aside,footer,header," +
        "form,button,input,select,textarea,iframe,object,embed,svg,canvas,video,audio,source,dialog";
      var NOISE_PATTERN = /(^|[\s_-])(comments?|share|social|related|sidebar|widget|adverts?|ads?|sponsor|promo|newsletter|subscribe|breadcrumbs?|pagination|menu|cookie|popup|modal|masthead)([\s_-]|$)/i;

      function hintOf(el) {
        // svg 元素的 className 是 SVGAnimatedString，不是字符串
        var cls = typeof el.className === "string" ? el.className : "";
        return cls + " " + (el.id || "");
      }

      // —— 选容器：p/pre 按文本量给父级、祖级打分（Readability 的核心思路） ——
      var scores = new Map();
      var paras = document.body.querySelectorAll("p, pre");
      for (var i = 0; i < paras.length; i++) {
        var text = paras[i].textContent || "";
        if (text.length < 25) { continue; }
        var score = 1 + Math.min(Math.floor(text.length / 100), 3)
          + Math.min((text.match(/[,，。;；]/g) || []).length, 5);
        var parent = paras[i].parentElement;
        if (parent) { scores.set(parent, (scores.get(parent) || 0) + score); }
        var grand = parent && parent.parentElement;
        if (grand) { scores.set(grand, (scores.get(grand) || 0) + score / 2); }
      }

      var best = null;
      var bestScore = 0;
      scores.forEach(function (score, el) {
        if (NOISE_PATTERN.test(hintOf(el))) { return; }
        // 链接文字占比过半的是目录/导航块，不是正文
        var linkLen = 0;
        var links = el.getElementsByTagName("a");
        for (var j = 0; j < links.length; j++) { linkLen += (links[j].textContent || "").length; }
        var totalLen = (el.textContent || "").length || 1;
        if (linkLen / totalLen > 0.5) { return; }
        if (score > bestScore) { bestScore = score; best = el; }
      });

      var custom = null;
      if (customSelector) {
        custom = document.querySelector(customSelector);
        if (!custom) { throw new Error("CSS 选择器未匹配任何内容：" + customSelector); }
      }
      var container = custom || best || document.querySelector("article") || document.body;

      // —— 清理：在克隆上做，原页面不动（太短时的二次提取要求幂等） ——
      var clone = container.cloneNode(true);
      var junk = clone.querySelectorAll(NOISE_TAGS);
      for (var k = 0; k < junk.length; k++) { junk[k].remove(); }
      var classed = clone.querySelectorAll("[class], [id]");
      for (var m = 0; m < classed.length; m++) {
        if (NOISE_PATTERN.test(hintOf(classed[m]))) { classed[m].remove(); }
      }

      // —— 绝对化：克隆的 ownerDocument 还是当前页，src/href 属性访问器按 baseURI 解析 ——
      var imgs = clone.querySelectorAll("img");
      var seenImages = new Set();
      for (var n = 0; n < imgs.length; n++) {
        var img = imgs[n];
        // 懒加载站点把真实地址放 data-src/data-original，src 是占位图
        var raw = img.getAttribute("data-src") || img.getAttribute("data-original") || img.getAttribute("src");
        if (!raw && img.getAttribute("srcset")) {
          raw = img.getAttribute("srcset").split(",")[0].trim().split(/\s+/)[0];
        }
        if (raw) {
          try { img.setAttribute("src", new URL(raw, document.baseURI).href); } catch (e) { /* 非法地址原样保留 */ }
        }
        var absoluteSrc = img.getAttribute("src") || "";
        if (absoluteSrc && seenImages.has(absoluteSrc)) { img.remove(); continue; }
        if (absoluteSrc) { seenImages.add(absoluteSrc); }
        img.removeAttribute("srcset");
        img.removeAttribute("sizes");
        img.removeAttribute("loading");
      }
      var anchors = clone.querySelectorAll("a[href]");
      for (var q = 0; q < anchors.length; q++) {
        anchors[q].setAttribute("href", anchors[q].href);
      }

      // 标签壳够长但既没文字也没图，等同没提取到
      var textLen = (clone.textContent || "").replace(/\s+/g, "").length;
      if (textLen < 80 && clone.querySelectorAll("img").length === 0) { return ""; }
      return clone.innerHTML;
    })()
    """#
}

enum FullTextPolicy {
    /// 自动模式保守触发：明确“继续阅读”提示，或 80–600 字且只有一个正文块的摘要。
    static func looksTruncated(_ html: String) -> Bool {
        let text = HTMLTools.plainText(html)
        guard text.count >= 8 else { return false }
        let lower = text.lowercased()
        if ["read more", "continue reading", "阅读全文", "继续阅读", "查看全文"]
            .contains(where: lower.contains) { return true }
        guard text.count >= 80, text.count <= 600 else { return false }
        let blocks = html.matches(of: /<(?:p|div|section|article|blockquote|pre)\b/.ignoresCase()).count
        return blocks <= 1
    }
}
