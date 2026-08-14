import Foundation

/// 正文页模板。视觉规格见 docs/UI-GUIDELINES.md：纸面底色、40em 版心、双主题、代码块横向滚动。
/// CSS/HTML 内嵌为字符串：省掉 SPM 资源 bundle 的打包环节，构建产物只有一个可执行文件。
enum ReaderTemplate {
    static func page(_ data: ReaderData) -> String {
        let title = escape(data.article.title)
        let feed = escape(data.feedTitle)
        let author = data.article.author.map(escape) ?? ""
        let date = data.article.publishedAt.map { Self.dateFormatter.string(from: $0) } ?? ""
        // NNW 式页头：来源名一行在标题上方，日期 · 作者一行在标题下方
        let meta = [date, author].filter { !$0.isEmpty }.joined(separator: " · ")
        let metaHTML = meta.isEmpty ? "" : "<div class=\"meta\">\(meta)</div>"
        let titleHTML: String
        if let url = data.article.url {
            titleHTML = "<a href=\"\(escape(url))\">\(title)</a>"
        } else {
            titleHTML = title
        }
        // 全文抓取结果优先；「恢复原文」由调用方把 extractedHTML 置 nil 后重渲染
        let body = data.extractedHTML ?? data.html
        let content = body.isEmpty
            ? "<p class=\"bf-empty\">这篇没有正文，试试右上角在浏览器打开原文。</p>"
            : body
        // 字号档位（设置 → 阅读），默认 17.5；模板生成时代入，换档对之后打开的文章生效
        let base = UserDefaults.standard.double(forKey: SettingsKey.articleFontSize)
        let sizedCSS = css.replacingOccurrences(
            of: "BASE_FONT_PX",
            with: String(base > 0 ? base : DesignTokens.Typography.readerBody))
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(sizedCSS)</style>
        </head>
        <body>
        <div id="bf-progress"></div>
        <article>
          <header>
            <div class="meta-feed">\(feed)</div>
            <h1>\(titleHTML)</h1>
            \(metaHTML)
          </header>
          <div id="bf-content">\(content)</div>
        </article>
        <script>\(js)</script>
        <script>
        /* 图片软浮现：onload 后加类淡入；楼层注入后由 ReaderView 再调一次 */
        window.__bifeedWireImgs = function () {
          document.querySelectorAll('#bf-content img:not(.bf-ready)').forEach(function (m) {
            var done = function () { m.classList.add('bf-ready'); };
            if (m.complete) { done(); }
            else { m.addEventListener('load', done, { once: true }); m.addEventListener('error', done, { once: true }); }
          });
        };
        window.__bifeedWireImgs();
        </script>
        </body>
        </html>
        """
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 楼层区内层 HTML（不含 <section> 标签本身），经 JS 侧 setForum 注入 #bf-forum。
    /// author/timeText 转义；post.html 是源站渲染好的富文本，原样嵌入。
    static func forumHTML(_ thread: ForumThread) -> String {
        // v2ex/discourse 是平铺楼层（有楼号），hn/reddit/lobsters 是树（楼号无意义，靠 --depth 缩进）
        let isFlat = thread.source == "v2ex" || thread.source == "discourse"
        var out = #"<h2 class="bf-forum-title">\#(isFlat ? "回帖" : "评论") <span class="bf-forum-count">\#(thread.postCount)</span></h2>"#
        for post in thread.posts {
            let badge = post.isOP ? #"<span class="bf-op">\#(isFlat ? "楼主" : "OP")</span>"# : ""
            var meta = isFlat ? "#\(post.index) · \(escape(post.timeText))" : escape(post.timeText)
            if let score = post.score { meta += " · \(score) 分" }
            // 作者为空的是 Reddit 未展开的 more 占位，只有一行正文，不出头部
            let head = post.author.isEmpty ? "" :
                #"<div class="bf-post-head"><span class="bf-post-author">\#(escape(post.author))</span>\#(badge)<span class="bf-post-meta">\#(meta)</span></div>"#
            out += #"<div class="bf-post" style="--depth:\#(post.depth)">\#(head)<div class="bf-post-body">\#(post.html)</div></div>"#
        }
        return out
    }

    static let css = """
    :root {
      color-scheme: light dark;
      --bg: \(DesignTokens.Reader.backgroundLightHex); --fg: #1D1D1F; --fg2: #6E6E73; --fg3: #A0A0A6;
      --link: #0A5DC2; --accent: #0A5DC2;
      --line: #E8E8EA; --code-bg: #F4F4F5;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: \(DesignTokens.Reader.backgroundDarkHex); --fg: #E6E6E8; --fg2: #98989E; --fg3: #6E6E74;
        --link: #6CA6FF; --accent: #6CA6FF;
        --line: #333336; --code-bg: #2A2A2D;
      }
    }
    /* feed 正文常自带内联配色（公众号、老博客大量 `style="color:#000;background:#fff"`），
       深色主题下要么黑底黑字，要么在深色页面里糊一块白板。
       处理原则：**让字变亮，不让背景变白**——纸面底色由模板统一给，正文不该自己刷背景。
       带 !important 的作者样式能压过无 !important 的内联声明，这是不改正文 HTML 的唯一办法。 */
    @media (prefers-color-scheme: dark) {
      /* 1. 正文里的一切背景一律取消，落回模板底色。
         例外是代码块和模板自己的 bf- 元素（它们的背景是本模板画的，不是 feed 带的）。 */
      article *:not(pre):not(code):not([class^="bf-"]) {
        background-color: transparent !important;
        background-image: none !important;
      }
      /* 2. 近黑到中灰的字改成前景色。
         前缀匹配会误伤 #33ccff 这类以相同两位开头的彩色字——它们会变成亮前景色，
         在深色下仍然可读；反过来漏掉一个深色就是一片看不见的字，所以宁可多接管。 */
      [style*="color:#0"], [style*="color: #0"],
      [style*="color:#1"], [style*="color: #1"],
      [style*="color:#2"], [style*="color: #2"],
      [style*="color:#3"], [style*="color: #3"],
      [style*="color:#4"], [style*="color: #4"],
      [style*="color:#5"], [style*="color: #5"],
      [style*="color:#6"], [style*="color: #6"],
      [style*="color:black"], [style*="color: black"],
      [style*="color:rgb(0"], [style*="color: rgb(0"],
      font[color="#000000"], font[color="#000"], font[color="black"] {
        color: var(--fg) !important;
      }
    }
    * { box-sizing: border-box; }
    html { background: var(--bg); }
    body {
      margin: 0; background: var(--bg); color: var(--fg);
      font: BASE_FONT_PXpx/1.72 -apple-system, "SF Pro Text", "PingFang SC", sans-serif;
      -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
      overflow-wrap: break-word;
    }
    article { max-width: 40em; margin: 0 auto; padding: 44px 32px 96px; }
    header { margin-bottom: 1.8em; padding-bottom: 1.1em; border-bottom: 1px solid var(--line); }
    .meta-feed { font-size: 13px; font-weight: 600; color: var(--link); letter-spacing: 0.01em; margin-bottom: 0.5em; }
    h1 { font-size: 30px; line-height: 1.22; letter-spacing: -0.021em; margin: 0 0 0.45em; font-weight: 800; }
    h1 a { color: var(--fg); text-decoration: none; border: none; }
    h1 a:hover { color: var(--link); }
    .meta { font-size: 12px; color: var(--fg2); letter-spacing: 0.02em; }
    .bf-empty { color: var(--fg2); }
    p { margin: 0 0 0.9em; }
    a { color: var(--link); text-decoration: none; border-bottom: 1px solid transparent; transition: border-color 0.15s; cursor: pointer; }
    a:hover { border-bottom-color: var(--link); }
    /* 竖长图限高保比例（用户反馈：细长截图过大）；加载完成前占位透明，onload 后软浮现 */
    img { max-width: 100%; max-height: 68vh; width: auto; height: auto; border-radius: 6px; }
    #bf-content img { opacity: 0; transition: opacity 0.25s ease; }
    #bf-content img.bf-ready { opacity: 1; }
    @media (prefers-reduced-motion: reduce) { #bf-content img { transition: none; } }
    figure { margin: 1.2em 0; }
    figcaption { font-size: 13px; color: var(--fg2); text-align: center; margin-top: 0.5em; }
    pre {
      background: var(--code-bg); border: 1px solid var(--line); border-radius: 8px;
      padding: 14px 16px; overflow-x: auto; font-size: 13px; line-height: 1.55; margin: 1.1em 0;
    }
    code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.85em; background: var(--code-bg); padding: 0.15em 0.4em; border-radius: 4px; }
    pre code { background: none; padding: 0; font-size: inherit; }
    blockquote { margin: 1.2em 0; padding: 0.1em 0 0.1em 1.1em; border-left: 3px solid var(--line); color: var(--fg2); font-size: 15px; }
    hr { border: none; border-top: 1px solid var(--line); margin: 2em 0; }
    table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; font-size: 14px; }
    th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; }
    h2 { font-size: 21px; font-weight: 700; margin: 1.6em 0 0.6em; letter-spacing: -0.01em; }
    h3 { font-size: 17px; font-weight: 700; margin: 1.4em 0 0.5em; }
    h4, h5, h6 { font-size: 16px; margin: 1.3em 0 0.4em; }
    ul, ol { padding-left: 1.4em; margin: 0 0 0.9em; }
    li { margin: 0.3em 0; }
    iframe, video { max-width: 100%; }
    ::selection { background: color-mix(in srgb, var(--accent) 24%, transparent); }
    /* 译文段（M2 启用）：与原文同级的阅读对象，强调线区分，不弱化 */
    .bf-tr { border-left: 3px solid var(--accent); padding-left: 14px; margin: 0.35em 0 0.9em; line-height: 1.85; }
    /* 楼层区（M3）：#bf-forum 在 #bf-content 内，.bf-tr 译文样式自动适用 */
    .bf-forum-loading { color: var(--fg3); font-size: 13px; }
    .bf-forum-title { margin-top: 2.2em; padding-top: 1.4em; border-top: 1px solid var(--line); }
    .bf-forum-count { color: var(--fg3); font-weight: 400; }
    /* depth 超过 6 视觉封顶，hn 深楼不至于挤成一列字 */
    .bf-post { border-top: 1px solid var(--line); padding: 14px 0; margin-left: calc(min(var(--depth), 6) * 20px); }
    .bf-post-head { margin-bottom: 0.3em; }
    .bf-post-author { font-size: 12.5px; font-weight: 600; }
    .bf-post-meta { font-size: 11.5px; color: var(--fg2); margin-left: 8px; } /* fg3 对比度 2.5:1 不达标，升 fg2 */
    .bf-post-body { font-size: 14.5px; line-height: 1.65; }
    .bf-post-body p { margin: 0 0 0.5em; }
    /* V2EX 表情图/长图别撑爆楼层 */
    .bf-post-body img { max-height: 420px; }
    .bf-op { font-size: 11px; color: var(--accent); background: color-mix(in srgb, var(--accent) 10%, transparent); border-radius: 4px; padding: 1px 6px; margin-left: 6px; }
    /* 阅读进度条：宽度由 JS 按滚动比例维护；滚动本身连续，不加过渡 */
    #bf-progress { position: fixed; top: 0; left: 0; height: 2px; width: 0%; background: var(--accent); transform-origin: left; }
    @media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
    """

    /// 桥接脚本，挂在 window.__bifeed：翻译 extract / inject / clear（M2），
    /// 楼层 forumLoading / setForum（M3），滚动 getScroll / setScroll（M4，进度条自维护），
    /// Space 阅读流 pageDown。
    /// 全部幂等。原始字符串省去 JS 引号的转义。
    static let js = #"""
    (function () {
      var SEL = 'p, li, blockquote, h1, h2, h3, h4, h5, h6';
      function collect() {
        var out = [];
        var all = document.getElementById('bf-content').querySelectorAll(SEL);
        for (var k = 0; k < all.length; k++) {
          var el = all[k];
          if (el.closest('pre, code')) continue;
          // 只留最内层，避免 blockquote>p、li>p 嵌套时同一句翻两次。
          // 候选全部在 #bf-content 内，所以"包含另一个候选"等价于自身有 SEL 命中的后代。
          if (el.querySelector(SEL)) continue;
          if (el.innerText.trim().length < 2) continue;
          if (el.classList.contains('bf-tr')) continue;
          out.push(el);
        }
        return out;
      }
      // LI 的译文 append 在自身末尾，其余插在紧后的兄弟位置，幂等判定与之对应
      function translated(node) {
        var probe = node.tagName === 'LI' ? node.lastElementChild : node.nextElementSibling;
        return probe !== null && probe.classList.contains('bf-tr');
      }
      function forumSection() {
        var sec = document.getElementById('bf-forum');
        if (sec === null) {
          sec = document.createElement('section');
          sec.id = 'bf-forum';
          document.getElementById('bf-content').appendChild(sec);
        }
        return sec;
      }
      // 滚动比例 0..1；页面不足一屏（分母 <= 0）按 0。夹取应对 macOS 橡皮筋越界。
      function scrollFraction() {
        var max = document.documentElement.scrollHeight - window.innerHeight;
        if (max <= 0) return 0;
        var f = window.scrollY / max;
        return f < 0 ? 0 : (f > 1 ? 1 : f);
      }
      // 顶部进度条：scroll 监听 + rAF 节流。setForum 注入后页面变高，下次滚动自动按新高度重算。
      var bar = document.getElementById('bf-progress');
      var ticking = false;
      function updateBar() {
        ticking = false;
        bar.style.width = (scrollFraction() * 100) + '%';
      }
      window.addEventListener('scroll', function () {
        if (!ticking) { ticking = true; requestAnimationFrame(updateBar); }
      }, { passive: true });
      updateBar();
      window.__bifeed = {
        _nodes: null,
        extract: function () {
          this._nodes = collect();
          var out = [];
          for (var k = 0; k < this._nodes.length; k++) {
            out.push({ i: k, text: this._nodes[k].innerText });
          }
          return JSON.stringify(out);
        },
        inject: function (jsonString) {
          if (this._nodes === null) this.extract();
          var pairs = JSON.parse(jsonString);
          var n = 0;
          for (var k = 0; k < pairs.length; k++) {
            var node = this._nodes[pairs[k][0]];
            if (translated(node)) continue;
            var div = document.createElement('div');
            div.className = 'bf-tr';
            div.textContent = pairs[k][1];
            if (node.tagName === 'LI') {
              node.appendChild(div);
            } else {
              node.insertAdjacentElement('afterend', div);
            }
            n++;
          }
          return n;
        },
        clear: function () {
          var trs = document.querySelectorAll('#bf-content .bf-tr');
          for (var k = 0; k < trs.length; k++) trs[k].remove();
        },
        // 楼层区：占位与注入都整体替换 innerHTML，天然幂等
        forumLoading: function () {
          forumSection().innerHTML = '<div class="bf-forum-loading">正在加载回帖…</div>';
        },
        setForum: function (jsonString) {
          forumSection().innerHTML = JSON.parse(jsonString);
          // 楼层插入后旧节点索引失效，置空让下次 extract 重算，翻译才能覆盖楼层
          this._nodes = null;
          return 1;
        },
        getScroll: function () {
          return scrollFraction();
        },
        // setScroll 触发 scroll 事件，进度条随之更新，不用手动刷
        setScroll: function (fraction) {
          var f = fraction < 0 ? 0 : (fraction > 1 ? 1 : fraction);
          var max = document.documentElement.scrollHeight - window.innerHeight;
          window.scrollTo(0, max > 0 ? f * max : 0);
        },
        // Space 阅读流：余量 < 40px 视为已到底，返回 false 让原生侧跳下一篇未读
        pageDown: function () {
          var remain = document.documentElement.scrollHeight - window.innerHeight - window.scrollY;
          if (remain < 40) return false;
          var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
          window.scrollBy({ top: window.innerHeight * 0.9, behavior: reduced ? 'auto' : 'smooth' });
          return true;
        }
      };
    })();
    """#
}
