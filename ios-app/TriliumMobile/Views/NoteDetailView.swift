import SwiftUI
import WebKit

/// 笔记详情（原生阅读页）：ETAPI 拿内容，本地渲染成移动端友好排版。
/// 只有点「编辑」才进 Trilium 网页编辑器（完整编辑能力）。
struct NoteDetailView: View {
    let note: Note

    @State private var html: String = ""
    @State private var loading = true
    @State private var errorMsg = ""
    @State private var showEditor = false

    var body: some View {
        Group {
            if loading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !errorMsg.isEmpty {
                VStack(spacing: 12) {
                    Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                    Button("重试") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentWebView(html: html)
            }
        }
        .navigationTitle(note.title.isEmpty ? "笔记" : note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("编辑") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor, onDismiss: { Task { await load() } }) {
            EditorView(note: note)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        do {
            let raw = try await ETAPIClient.shared.getContent(note.noteId)
            // 诊断：把实际拿到的内容概况写日志，便于排查「正文空白」类问题
            AppLogger.shared.log("阅读[\(note.title)]: type=\(note.type) 长度=\(raw.count) 开头=\(String(raw.prefix(80)).replacingOccurrences(of: "\n", with: " "))")
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                html = Self.wrapForMobile(title: note.title, raw: "<p style='color:#8e8e93'>（空笔记）</p>", noteType: "text")
            } else {
                html = Self.wrapForMobile(title: note.title, raw: raw, noteType: note.type)
            }
            errorMsg = ""
        } catch {
            AppLogger.shared.log("阅读[\(note.title)]失败: \(error.localizedDescription)")
            errorMsg = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    /// 把笔记内容包进移动端友好的 HTML 骨架：
    /// viewport / 字号 / 行距 / 图片自适应 / 代码块横向滚动 / 暗色模式适配。
    /// code 类笔记内容不是 HTML，按纯文本转义后放 <pre>。
    static func wrapForMobile(title: String, raw: String, noteType: String) -> String {
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
            // text 笔记 content 本身就是 HTML，直接用
            bodyContent = raw
        }

        // 防御：若服务端返回的是完整 HTML 文档（含 <html>/<body>），不能嵌进骨架
        //（嵌套文档标签会被浏览器丢弃，head 里的脚本/样式可能干扰渲染）。
        // 此时直接用原文档，把移动端样式注入 </head> 前。
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if noteType != "code" && (trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html")) {
            let mobileCSS = """
            <style>
              body { font-family: -apple-system, "PingFang SC", sans-serif;
                     font-size: 17px; line-height: 1.75; padding: 16px 18px 60px;
                     word-wrap: break-word; -webkit-text-size-adjust: 100%; }
              img { max-width: 100%; height: auto; }
              pre { overflow-x: auto; }
            </style>
            """
            if raw.lowercased().contains("</head>") {
                return raw.replacingOccurrences(of: "</head>", with: mobileCSS + "</head>", options: .caseInsensitive)
            }
            return raw
        }

        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">
        <style>
          * { box-sizing: border-box; }
          body {
            font-family: -apple-system, "PingFang SC", sans-serif;
            font-size: 17px; line-height: 1.75; color: #1c1c1e;
            margin: 0; padding: 16px 18px 60px;
            word-wrap: break-word; -webkit-text-size-adjust: 100%;
          }
          @media (prefers-color-scheme: dark) {
            body { background: #000; color: #e5e5e7; }
            a { color: #6bb3ff; }
            img { background: #1c1c1e; }
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
    }
}

/// 本地 HTML 渲染（loadHTMLString，不加载 Trilium 桌面页）。
/// baseURL 指向服务器：笔记里的相对路径图片/附件（/api/attachments/...）才能加载。
struct ContentWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.tag = html.hashValue
        wv.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 内容变化时重载（如编辑返回后刷新）；tag 记上次已渲染内容，避免重复加载
        if uiView.tag != html.hashValue {
            uiView.tag = html.hashValue
            uiView.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
        }
    }
}
