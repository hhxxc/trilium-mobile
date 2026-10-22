import Foundation

/// HTML 包装工具（抽离，供阅读页复用）
enum NoteHTML {

/// 代码块增强：给每个 pre 动态包一层 + 右上角「复制」按钮（纯 JS，无需原生桥）。
    /// clipboard API 不可用时降级 execCommand；完整 HTML 文档分支同样注入。
    private static let codeEnhance = """
    <style>
      .code-wrap { position: relative; }
      .code-wrap .copy-btn {
        position: absolute; top: 6px; right: 6px; z-index: 5;
        font-size: 12px; padding: 2px 8px; border-radius: 6px;
        border: 1px solid rgba(120,120,128,0.3);
        background: rgba(255,255,255,0.88); color: #333; opacity: 0.85;
      }
      @media (prefers-color-scheme: dark) {
        .code-wrap .copy-btn { background: rgba(60,60,67,0.88); color: #ddd; }
      }
      img { -webkit-touch-callout: none; }
      /* 回到顶部：长文翻到下面就懒得往回滑了，滚动过一屏才浮出来 */
      #to-top-btn {
        position: fixed; right: 14px; bottom: calc(24px + env(safe-area-inset-bottom));
        width: 40px; height: 40px; border-radius: 20px;
        border: 1px solid rgba(120,120,128,0.28);
        background: rgba(255,255,255,0.94); color: #333;
        font-size: 18px; line-height: 38px; text-align: center;
        opacity: 0; pointer-events: none; z-index: 9999;
        transition: opacity .2s ease; box-shadow: 0 2px 10px rgba(0,0,0,0.14);
      }
      #to-top-btn.show { opacity: 1; pointer-events: auto; }
      @media (prefers-color-scheme: dark) {
        #to-top-btn { background: rgba(58,58,60,0.94); color: #eee; }
      }
    </style>
    <script>
    // 长按图片 600ms → 通知原生保存到相册（禁掉系统 callout，统一走自家流程）
    (function() {
      var timer;
      document.addEventListener('touchstart', function(e) {
        var img = e.target.closest ? e.target.closest('img') : null;
        if (!img || !img.src) return;
        timer = setTimeout(function() {
          window.webkit && window.webkit.messageHandlers.imgsave &&
            window.webkit.messageHandlers.imgsave.postMessage(img.src);
        }, 600);
      }, { passive: true });
      ['touchend', 'touchmove', 'touchcancel'].forEach(function(ev) {
        document.addEventListener(ev, function() { clearTimeout(timer); }, { passive: true });
      });
    })();
    // 大纲上报：收集 h1~h3 发给原生（大纲目录入口用）
    document.addEventListener('DOMContentLoaded', function() {
      var out = [];
      document.querySelectorAll('h1,h2,h3').forEach(function(h) {
        out.push([parseInt(h.tagName.substring(1), 10), h.textContent.trim()]);
      });
      window.webkit && window.webkit.messageHandlers.outline &&
        window.webkit.messageHandlers.outline.postMessage(out);
    });
    </script>
    <script>
    document.addEventListener('DOMContentLoaded', function() {
      document.querySelectorAll('pre').forEach(function(pre) {
        if (pre.parentElement && pre.parentElement.className === 'code-wrap') return;
        var wrap = document.createElement('div');
        wrap.className = 'code-wrap';
        pre.parentNode.insertBefore(wrap, pre);
        wrap.appendChild(pre);
        var btn = document.createElement('button');
        btn.className = 'copy-btn'; btn.type = 'button'; btn.textContent = '复制';
        wrap.appendChild(btn);
      });
    });
    document.addEventListener('click', function(e) {
      var btn = e.target.closest ? e.target.closest('.copy-btn') : null;
      if (!btn) return;
      var pre = btn.parentElement.querySelector('pre');
      var text = pre ? pre.innerText : '';
      var done = function() {
        btn.textContent = '已复制';
        setTimeout(function() { btn.textContent = '复制'; }, 1500);
      };
      var fallback = function() {
        var ta = document.createElement('textarea');
        ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); done(); } catch (err) {}
        document.body.removeChild(ta);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done).catch(fallback);
      } else { fallback(); }
    });
    </script>
    <script>
    // 回到顶部按钮：纯前端，不经过原生桥；页面没有滚动时自动隐藏
    (function() {
      function makeBtn() {
        if (document.getElementById('to-top-btn')) return;
        var b = document.createElement('div');
        b.id = 'to-top-btn';
        b.textContent = '↑';
        b.addEventListener('click', function() {
          window.scrollTo({ top: 0, behavior: 'smooth' });
        });
        document.body.appendChild(b);
        window.addEventListener('scroll', function() {
          if (window.scrollY > 600) b.classList.add('show');
          else b.classList.remove('show');
        }, { passive: true });
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', makeBtn);
      } else { makeBtn(); }
    })();
    </script>
    """

    /// mermaid.min.js 全文（Bundle 内联，~2.6MB；只加载一次）
    private static let mermaidJS: String = {
        guard let url = Bundle.main.url(forResource: "mermaid", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            AppLogger.shared.log("mermaid.js 资源缺失")
            return ""
        }
        // 保险：防止 JS 字符串中出现的 </script> 截断 HTML
        return s.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
    }()

    /// mermaid 类型笔记：代码 → 本地渲染图表（无外网也能看，官方移动端没有的能力）
    static func wrapMermaid(title: String, code: String) -> String {
        guard !mermaidJS.isEmpty else {
            return wrap(title: title, raw: "<pre>\(code)</pre>", noteType: "code")
        }
        let escaped = code
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
          body { font-family: -apple-system, "PingFang SC", sans-serif;
                 margin: 0; padding: 16px 18px 60px; word-wrap: break-word;
                 -webkit-text-size-adjust: 100%; background: #fff; }
          @media (prefers-color-scheme: dark) { body { background: #000; } }
          h1 { font-size: 24px; margin: 8px 0 16px; }
          .mermaid { display: flex; justify-content: center; }
          .mermaid svg { max-width: 100%; height: auto; }
          .err { color: #c0392b; font-size: 13px; white-space: pre-wrap; }
        </style>
        </head><body>
        <h1>\(title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</h1>
        <pre class="mermaid">
        \(escaped)
        </pre>
        <script>\(mermaidJS)</script>
        <script>
        mermaid.initialize({
          startOnLoad: true,
          theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
          securityLevel: 'loose'
        });
        mermaid.parseError = function(err) {
          var el = document.querySelector('.mermaid');
          if (el) { el.className = 'err'; el.textContent = '图表语法错误：' + err; }
        };
        </script>
        </body></html>
        """
    }

    /// 给任意 HTML 注入代码块增强（有 </head> 插头部，否则放开头）
    private static func injectEnhance(_ html: String) -> String {
        // ⚠️ 别用 html.lowercased().contains(...)：正文动辄几百 KB～几 MB，
        //    为了找个标签把整篇小写复制一遍，纯浪费内存和 CPU。
        if html.range(of: "</head>", options: .caseInsensitive) != nil {
            return html.replacingOccurrences(of: "</head>", with: codeEnhance + "</head>", options: .caseInsensitive)
        }
        return codeEnhance + html
    }

    /// fontScale：阅读页字号缩放（1.0 = 17px 标准）
    static func wrap(title: String, raw: String, noteType: String, fontScale: Double = 1.0) -> String {
        let fontSize = Int((17 * fontScale).rounded())
        let escapedTitle = title
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let bodyContent: String
        if noteType == "code" {
            let escaped = raw
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            bodyContent = "<pre>\(escaped)</pre>"
        } else {
            bodyContent = raw
        }

        // 只取开头几十个字符判类型：以前对整篇 raw 做 lowercased()，
        // 一篇 1MB 的笔记就要白复制 1MB 字符串
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24).lowercased()
        if noteType != "code" && (head.hasPrefix("<!doctype") || head.hasPrefix("<html")) {
            let mobileCSS = """
            <style>
              body { font-family: -apple-system, "PingFang SC", sans-serif;
                     font-size: \(fontSize)px; line-height: 1.75; color: #1c1c1e;
                     padding: 16px 18px 60px;
                     word-wrap: break-word; -webkit-text-size-adjust: 100%; }
              @media (prefers-color-scheme: dark) {
                body { background: #000; color: #e5e5e7; }
                a { color: #6bb3ff; }
                img { background: #1c1c1e; }
                blockquote { color: #98989d; }
              }
              h1 { font-size: 24px; line-height: 1.3; margin: 8px 0 16px; }
              h2 { font-size: 20px; margin: 24px 0 10px; }
              h3 { font-size: 18px; margin: 20px 0 8px; }
              p { margin: 10px 0; }
              img { max-width: 100%; height: auto; border-radius: 8px; }
              pre {
                background: rgba(120,120,128,0.12); border-radius: 8px;
                padding: 12px; overflow-x: auto; font-size: 14px; line-height: 1.5;
              }
              code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
              p code, li code {
                background: rgba(120,120,128,0.12); border-radius: 4px; padding: 1px 5px;
              }
              blockquote {
                border-left: 3px solid rgba(120,120,128,0.4);
                margin: 12px 0; padding: 2px 0 2px 14px; color: #6e6e73;
              }
              table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 15px; }
              th, td { border: 1px solid rgba(120,120,128,0.35); padding: 7px 10px; text-align: left; }
              ul, ol { padding-left: 24px; }
              a { color: #0a66c2; }
              hr { border: none; border-top: 1px solid rgba(120,120,128,0.3); margin: 20px 0; }
            </style>
            """
            if raw.range(of: "</head>", options: .caseInsensitive) != nil {
                return injectEnhance(raw.replacingOccurrences(of: "</head>", with: mobileCSS + "</head>", options: .caseInsensitive))
            }
            return injectEnhance(raw)
        }

        let template = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, "PingFang SC", sans-serif;
            font-size: \(fontSize)px; line-height: 1.75; color: #1c1c1e;
            margin: 0; padding: 16px 18px 60px;
            word-wrap: break-word; -webkit-text-size-adjust: 100%;
          }
          @media (prefers-color-scheme: dark) {
            body { background: #000; color: #e5e5e7; }
            a { color: #6bb3ff; }
            img { background: #1c1c1e; }
            blockquote { color: #98989d; }
          }
          h1 { font-size: 24px; line-height: 1.3; margin: 8px 0 16px; }
          h2 { font-size: 20px; margin: 24px 0 10px; }
          h3 { font-size: 18px; margin: 20px 0 8px; }
          p { margin: 10px 0; }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          pre {
            background: rgba(120,120,128,0.12); border-radius: 8px;
            padding: 12px; overflow-x: auto; font-size: 14px; line-height: 1.5;
          }
          code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; }
          p code, li code {
            background: rgba(120,120,128,0.12); border-radius: 4px; padding: 1px 5px;
          }
          blockquote {
            border-left: 3px solid rgba(120,120,128,0.4);
            margin: 12px 0; padding: 2px 0 2px 14px; color: #6e6e73;
          }
          table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 15px; }
          th, td { border: 1px solid rgba(120,120,128,0.35); padding: 7px 10px; text-align: left; }
          ul, ol { padding-left: 24px; }
          a { color: #0a66c2; }
          hr { border: none; border-top: 1px solid rgba(120,120,128,0.3); margin: 20px 0; }
        </style>
        </head><body>
        <h1>\(escapedTitle)</h1>
        \(bodyContent)
        </body></html>
        """
        return injectEnhance(template)
    }
}
