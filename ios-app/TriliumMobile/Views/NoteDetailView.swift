import SwiftUI
import WebKit

/// 笔记详情（原生阅读页）：ETAPI 拿内容，按类型原生渲染。
/// text → 富文本 HTML；code → 代码；image → 图片；file → 附件；其他 → 降级提示。
/// 编辑统一用原生编辑（text/code 用 TextEditor 改标题+正文；复杂类型给「用网页编辑器」兜底）。
struct NoteDetailView: View {
    let note: Note

    @State private var textContent: String = ""
    @State private var imageData: Data?
    @State private var loading = true
    @State private var hasLoadedOnce = false
    @State private var errorMsg = ""
    @State private var showEditor = false
    /// 编辑改标题后的最新标题（note 是 let，PATCH 后靠这里刷新显示）
    @State private var freshTitle: String = ""
    @State private var freshType: String = ""

    private var displayTitle: String { freshTitle.isEmpty ? note.title : freshTitle }

    var body: some View {
        Group {
            if loading && !hasLoadedOnce { // 编辑返回的静默刷新不闪全屏 loading
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !errorMsg.isEmpty {
                VStack(spacing: 12) {
                    Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                    Button("重试") { Task { await load(force: true) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .navigationTitle(displayTitle.isEmpty ? "笔记" : displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if note.type == "text" || note.type == "code" {
                    Button("编辑") { showEditor = true }
                }
            }
        }
        // ⚠️ 编辑返回必须 force 刷新：普通 load() 会命中本地缓存显示**旧内容**（编辑白改）
        .sheet(isPresented: $showEditor, onDismiss: { Task { await load(force: true) } }) {
            NativeEditorView(note: note, initialContent: textContent)
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch note.type {
        case "image":
            if let data = imageData, let img = UIImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
            } else {
                fallback(typeName: "图片", icon: "photo")
            }
        case "file":
            fileView
        case "code":
            ContentWebView(html: NoteHTML.wrap(title: note.title, raw: textContent, noteType: "code"))
        case "render":
            ContentWebView(html: NoteHTML.wrap(title: note.title, raw: textContent, noteType: "render"))
        case "text":
            ContentWebView(html: NoteHTML.wrap(title: note.title, raw: textContent, noteType: "text"))
        default:
            fallback(typeName: note.type, icon: "doc.text")
        }
    }

    private var fileView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.fill")
                .font(.system(size: 48)).foregroundColor(.blue)
            Text(note.title)
                .font(.headline)
            Text("附件类型（\(note.mime ?? "未知")）")
                .font(.footnote).foregroundColor(.secondary)
            Text("请在网页端下载或查看此附件")
                .font(.caption).foregroundColor(.secondary)
            Link("在网页端打开", destination: AppSettings.shared.serverURL)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fallback(typeName: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundColor(.secondary)
            Text("「\(typeName)」类型暂不支持原生展示")
                .font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// force=true：跳过缓存直拉网络（编辑保存后必须用，否则读到旧缓存）
    private func load(force: Bool = false) async {
        if !force { loading = true } // 静默刷新不置 loading，保留屏上旧内容
        do {
            if force {
                // 顺带拉最新元数据：编辑器里改过标题/类型时同步显示
                if let fresh = try await ETAPIClient.shared.getNote(note.noteId) {
                    freshTitle = fresh.title
                    freshType = fresh.type
                }
            }
            switch note.type {
            case "image":
                if !force, let cached = NoteCache.shared.loadBlob(note.noteId) {
                    imageData = cached
                } else if let data = try? await ETAPIClient.shared.getContentData(note.noteId) {
                    imageData = data
                    NoteCache.shared.saveBlob(note.noteId, data: data)
                }
            case "text", "code", "render":
                if !force, let cached = NoteCache.shared.loadContent(note.noteId) {
                    textContent = cached
                } else {
                    let raw = try await ETAPIClient.shared.getContent(note.noteId)
                    textContent = raw
                    NoteCache.shared.saveContent(note.noteId, text: raw)
                }
            default:
                break
            }
            errorMsg = ""
        } catch {
            // 静默刷新失败且屏上已有内容：不打断阅读，只记日志
            let hasContent = !textContent.isEmpty || imageData != nil
            if !(force && hasContent) {
                errorMsg = "加载失败：\(error.localizedDescription)"
            }
            AppLogger.shared.log("阅读[\(note.title)]加载失败: \(error.localizedDescription)")
        }
        hasLoadedOnce = true
        loading = false
    }
}

/// 原生编辑器：text/code 笔记直接改标题 + 正文（纯 SwiftUI，不再依赖网页编辑器）
struct NativeEditorView: View {
    let note: Note
    let initialContent: String

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var saving = false
    @State private var errorMsg = ""

    var body: some View {
        NavigationView {
            Form {
                Section("标题") {
                    TextField("标题", text: $title)
                }
                Section("内容") {
                    if note.type == "code" {
                        TextEditor(text: $content)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 300)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    } else {
                        // text 笔记正文是 HTML，纯文本编辑会破坏格式；
                        // 这里给一个说明 + 用网页编辑器兜底
                        Text("富文本笔记建议用网页编辑器编辑（保留格式）。\n如需纯文本编辑可切 code 类型。")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }
                if !errorMsg.isEmpty {
                    Section { Text(errorMsg).font(.footnote).foregroundColor(.red) }
                }
            }
            .navigationTitle("编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(saving)
                }
            }
            .onAppear {
                title = note.title
                content = initialContent
            }
        }
    }

    private func save() {
        saving = true
        Task {
            do {
                // 标题变化 → PATCH；正文变化（code 类型）→ PUT content
                if title != note.title {
                    _ = try await ETAPIClient.shared.patchNote(note.noteId, fields: ["title": title])
                }
                if note.type == "code" && content != initialContent {
                    try await ETAPIClient.shared.putContent(note.noteId, content: content)
                }
                // 更新缓存
                NoteCache.shared.saveContent(note.noteId, text: content)
                dismiss()
            } catch {
                errorMsg = "保存失败：\(error.localizedDescription)"
            }
            saving = false
        }
    }
}

/// HTML 包装工具（抽离，供阅读页复用）
enum NoteHTML {
    static func wrap(title: String, raw: String, noteType: String) -> String {
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
/// baseURL 指向服务器：笔记里的相对路径图片/附件才能加载。
struct ContentWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String = ""
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        uiView.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
    }
}
