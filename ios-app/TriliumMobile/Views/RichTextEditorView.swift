import SwiftUI
import WebKit
import UIKit

/// 富文本编辑器控制器：SwiftUI 工具条 → WKWebView 里的 JS 命令。
/// （工具条按钮不是网页元素，点了不会把焦点从 contenteditable 抢走，
///   但选区会丢，所以 JS 侧自己记了 selection 并在执行命令前恢复。）
final class RichTextController: ObservableObject {
    weak var webView: WKWebView?

    func js(_ code: String) {
        guard let webView = webView else { return }
        webView.evaluateJavaScript(code, completionHandler: nil)
    }

    /// 取当前正文 HTML（空内容归一化成 ""，避免存一堆 <br>）
    func currentHTML(_ completion: @escaping (String) -> Void) {
        guard let webView = webView else { completion(""); return }
        webView.evaluateJavaScript("window.__getHTML ? window.__getHTML() : ''") { value, _ in
            completion((value as? String) ?? "")
        }
    }

    /// 收起键盘：JS 的 blur() 停不掉 WKWebView 的键盘，必须走 responder
    func dismissKeyboard() {
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
    }
}

/// contenteditable 网页编辑器（本地页面，不加载服务端桌面版）
struct RichTextWebView: UIViewRepresentable {
    let pageHTML: String
    let controller: RichTextController
    let onDirty: () -> Void
    let onReady: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(onDirty: onDirty, onReady: onReady)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onDirty: () -> Void
        let onReady: () -> Void

        init(onDirty: @escaping () -> Void, onReady: @escaping () -> Void) {
            self.onDirty = onDirty
            self.onReady = onReady
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "dirty" { onDirty() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onReady()
            // 进入编辑就把光标落到正文末尾（用户是点「编辑」进来的，键盘该出来）
            webView.evaluateJavaScript("window.__focusEnd && window.__focusEnd()", completionHandler: nil)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = FullWebView.sharedProcessPool
        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "dirty")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.keyboardDismissMode = .interactive
        wv.overrideUserInterfaceStyle = (colorScheme == .dark) ? .dark : .light
        controller.webView = wv
        wv.loadHTMLString(pageHTML, baseURL: AppSettings.shared.serverURL)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let style: UIUserInterfaceStyle = (colorScheme == .dark) ? .dark : .light
        if uiView.overrideUserInterfaceStyle != style { uiView.overrideUserInterfaceStyle = style }
    }
}

/// 富文本编辑页：标题 + 格式工具条 + 可编辑正文。
/// 为什么不用服务端网页编辑器：那套是桌面版 Trilium 页面，手机上要登录、字号小、
/// 还要来回滚；这里只做「改正文」这一件事，进页面就能打字。
struct RichTextEditorView: View {
    let note: Note
    @State private var initialHTML: String
    @State private var title: String
    @State private var pageHTML: String
    @State private var reloadID = UUID()
    @State private var dirty = false
    @State private var ready = false
    @State private var busy = false
    @State private var errorMsg = ""
    @State private var showDiscard = false
    @State private var showConflict = false
    @State private var showLinkInput = false
    @State private var linkDraft = ""
    /// 冲突裁决「覆盖」时用：跳过再次比对
    @State private var forceWrite = false
    @State private var baseStamp: String?
    @StateObject private var controller = RichTextController()

    @Environment(\.dismiss) private var dismiss
    /// 直接观察单例（不用 @EnvironmentObject：少一个「忘注入就崩」的隐患）
    @ObservedObject private var settings = AppSettings.shared

    init(note: Note, initialContent: String, initialTitle: String) {
        self.note = note
        let body = Self.editableBody(from: initialContent)
        _initialHTML = State(initialValue: body)
        _title = State(initialValue: initialTitle)
        _baseStamp = State(initialValue: note.versionStamp)
        _pageHTML = State(initialValue: Self.pageHTML(body: body,
                                                      fontScale: AppSettings.shared.readerFontScale))
    }

    private var accent: Color { Theme.accent }
    private var titleChanged: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines) != note.title
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            titleField
            if !errorMsg.isEmpty {
                Text(errorMsg)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
            }
            Divider()
            formatBar
            Divider()
            RichTextWebView(pageHTML: pageHTML, controller: controller,
                            onDirty: { dirty = true },
                            onReady: { ready = true })
                .id(reloadID)
        }
        .background(Color(UIColor.systemBackground))
        .interactiveDismissDisabled(dirty || titleChanged)
        .confirmationDialog("放弃未保存的修改？", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("这篇笔记在别处被修改过", isPresented: $showConflict, titleVisibility: .visible) {
            Button("用我的改动覆盖") {
                forceWrite = true
                commit()
            }
            Button("载入服务端最新版，放弃我的改动", role: .destructive) {
                Task { await reloadFromServer() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("你编辑期间这篇笔记在别处（桌面端/网页）被改过。直接保存会覆盖对方的改动。")
        }
        .sheet(isPresented: $showLinkInput) {
            linkSheet
        }
        .onChange(of: settings.readerFontScale) { _ in
            // 字号档位变了：按新字号重建页面，并把当前正文带过去。
            // ⚠️ 不能动 initialHTML —— 它是「服务端那一版」的基准，改了就没法判断有没有改动/冲突
            let scale = settings.readerFontScale
            controller.currentHTML { html in
                DispatchQueue.main.async {
                    pageHTML = Self.pageHTML(body: html, fontScale: scale)
                    ready = false
                    reloadID = UUID()
                    dirty = true
                }
            }
        }
    }

    // MARK: - 头部 / 标题 / 工具条

    private var header: some View {
        HStack {
            Button("取消") {
                cancelTapped()
            }
            .font(.body)
            .foregroundColor(accent)
            .buttonStyle(.plain)
            Spacer()
            Text("编辑")
                .font(.headline)
            Spacer()
            Button {
                commit()
            } label: {
                if busy {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Text("保存").font(.body.weight(.semibold))
                }
            }
            .foregroundColor(accent)
            .buttonStyle(.plain)
            .disabled(busy || !ready)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var titleField: some View {
        TextField("标题", text: $title)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
    }

    private var formatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tool("bold") { controller.js("cmd('bold')") }
                tool("italic") { controller.js("cmd('italic')") }
                tool("underline") { controller.js("cmd('underline')") }
                tool("strikethrough") { controller.js("cmd('strikeThrough')") }
                divider
                textTool("H1") { controller.js("block('h1')") }
                textTool("H2") { controller.js("block('h2')") }
                textTool("H3") { controller.js("block('h3')") }
                divider
                tool("list.bullet") { controller.js("cmd('insertUnorderedList')") }
                tool("list.number") { controller.js("cmd('insertOrderedList')") }
                tool("text.quote") { controller.js("block('blockquote')") }
                tool("curlybraces") { controller.js("block('pre')") }
                divider
                tool("link") { showLinkInput = true }
                tool("arrow.uturn.backward") { controller.js("cmd('undo')") }
                tool("arrow.uturn.forward") { controller.js("cmd('redo')") }
                tool("keyboard.chevron.compact.down") {
                    controller.dismissKeyboard()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color(UIColor.separator)).frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private func tool(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 38, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableIconStyle())
    }

    private func textTool(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 38, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableIconStyle())
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("插入链接").font(.headline)
            TextField("https://", text: $linkDraft)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .keyboardType(.URL)
            HStack {
                Button("取消") { showLinkInput = false }
                Spacer()
                Button("插入") {
                    let url = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    showLinkInput = false
                    linkDraft = ""
                    guard !url.isEmpty else { return }
                    let escaped = url.replacingOccurrences(of: "'", with: "\\'")
                    controller.js("cmd('createLink', '\(escaped)')")
                }
                .fontWeight(.semibold)
                .disabled(linkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - 保存

    private func cancelTapped() {
        guard ready, controller.webView != nil else { dismiss(); return }
        controller.currentHTML { html in
            DispatchQueue.main.async {
                if dirty || titleChanged || html != initialHTML {
                    showDiscard = true
                } else {
                    dismiss()
                }
            }
        }
    }

    private func commit() {
        guard !busy, ready else { return }
        busy = true
        controller.currentHTML { html in
            DispatchQueue.main.async {
                // ⚠️ 这里不能把 initialHTML 改成 html：initialHTML 是「服务端那一版」，
                //    改了之后 write() 里的 cChanged 恒为 false，正文永远不会提交
                dirty = false
                Task { await write(html: html) }
            }
        }
    }

    private func write(html: String) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmedTitle.isEmpty ? "无标题" : String(trimmedTitle.prefix(120))
        let tChanged = newTitle != note.title
        let cChanged = html != initialHTML

        guard tChanged || cChanged else {
            busy = false
            dismiss()
            return
        }

        // 保存前比对版本戳：别处改过就先问用户（和原生编辑器一致）
        if !forceWrite, let base = baseStamp, !base.isEmpty {
            let fresh: Note? = try? await ETAPIClient.shared.getNote(note.noteId)
            if let cur = fresh?.versionStamp, !cur.isEmpty, cur != base {
                AppLogger.shared.log("富文本保存冲突[\(note.noteId)]：服务端 \(cur) ≠ 基准 \(base)")
                busy = false
                showConflict = true
                return
            }
        }

        do {
            if tChanged {
                _ = try await ETAPIClient.shared.patchNote(note.noteId, fields: ["title": newTitle])
            }
            if cChanged {
                try await ETAPIClient.shared.putContent(note.noteId, content: html)
            }
        } catch {
            // 断网：标题/正文分别入队，回线按序补交（正文带版本戳，补交前再比对一次）
            AppLogger.shared.log("富文本保存失败，转离线队列: \(error.localizedDescription)")
            if tChanged {
                NoteCache.shared.enqueue(PendingOp(kind: "patchTitle", id: UUID().uuidString,
                    noteId: note.noteId, title: newTitle, content: nil, parentNoteId: nil,
                    createdAt: Date(), baseStamp: baseStamp))
            }
            if cChanged {
                NoteCache.shared.enqueue(PendingOp(kind: "putContent", id: UUID().uuidString,
                    noteId: note.noteId, title: nil, content: html, parentNoteId: nil,
                    createdAt: Date(), baseStamp: baseStamp))
            }
        }

        NoteCache.shared.saveContent(note.noteId, text: html)
        NotificationCenter.default.post(name: .noteMetaChanged, object: nil)
        if !NoteCache.shared.pendingOps.isEmpty {
            Task { await NoteCache.shared.flushPendingOps() }
        }
        busy = false
        forceWrite = false
        dismiss()
    }

    private func reloadFromServer() async {
        do {
            let fresh = try await ETAPIClient.shared.getNote(note.noteId)
            let content = (try? await ETAPIClient.shared.getContent(note.noteId)) ?? ""
            let body = Self.editableBody(from: content)
            NoteCache.shared.saveContent(note.noteId, text: content)
            initialHTML = body
            title = fresh.title
            baseStamp = fresh.versionStamp
            pageHTML = Self.pageHTML(body: body, fontScale: settings.readerFontScale)
            ready = false
            reloadID = UUID()
            dirty = false
            forceWrite = false
            errorMsg = "已载入服务端最新版"
        } catch {
            errorMsg = "载入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - HTML 组装

    /// 去掉整篇 HTML 文档外壳（<!doctype>/<html>/<body>），只留可编辑的正文片段。
    /// Trilium 的 text 笔记大多是片段，但历史笔记里确实有整篇 HTML 的。
    static func editableBody(from html: String) -> String {
        var s = html
        if let r = s.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...])
        }
        if let r = s.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
            s = String(s[..<r.lowerBound])
        }
        s = s.replacingOccurrences(of: "<!doctype[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</?html[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pageHTML(body: String, fontScale: Double) -> String {
        let fontSize = Int((17 * fontScale).rounded())
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0">
        <style>
          html, body { min-height: 100%; }
          body {
            margin: 0; padding: 12px 16px 48px;
            font-family: -apple-system, "PingFang SC", sans-serif;
            font-size: \(fontSize)px; line-height: 1.72; color: #1c1c1e;
            -webkit-text-size-adjust: 100%; word-wrap: break-word;
            -webkit-user-select: text; user-select: text;
          }
          #editor { outline: none; min-height: 60vh; }
          h1 { font-size: 24px; line-height: 1.3; margin: 10px 0 14px; }
          h2 { font-size: 20px; margin: 20px 0 8px; }
          h3 { font-size: 18px; margin: 16px 0 6px; }
          p { margin: 8px 0; }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          pre { background: rgba(120,120,128,0.12); border-radius: 8px; padding: 10px 12px; overflow-x: auto; font-size: 14px; }
          code { font-family: ui-monospace, Menlo, monospace; font-size: 0.92em; }
          blockquote { border-left: 3px solid rgba(120,120,128,0.4); margin: 10px 0; padding: 2px 0 2px 12px; color: #6e6e73; }
          ul, ol { padding-left: 22px; }
          a { color: #0a66c2; }
          table { border-collapse: collapse; width: 100%; margin: 8px 0; }
          th, td { border: 1px solid rgba(120,120,128,0.35); padding: 6px 8px; text-align: left; }
          hr { border: none; border-top: 1px solid rgba(120,120,128,0.3); margin: 16px 0; }
          @media (prefers-color-scheme: dark) {
            body { background: #000; color: #e5e5e7; }
            a { color: #6bb3ff; }
            blockquote { color: #98989d; }
          }
        </style>
        </head><body>
        <div id="editor" contenteditable="true" spellcheck="true">\(body)</div>
        <script>
        var __savedRange = null;
        function __markDirty() {
          window.webkit && window.webkit.messageHandlers.dirty &&
            window.webkit.messageHandlers.dirty.postMessage(true);
        }
        document.addEventListener('selectionchange', function () {
          var s = window.getSelection();
          if (s && s.rangeCount > 0) { __savedRange = s.getRangeAt(0).cloneRange(); }
        });
        function __restore() {
          var e = document.getElementById('editor');
          if (!e) return;
          e.focus();
          if (__savedRange) {
            var s = window.getSelection();
            try { s.removeAllRanges(); s.addRange(__savedRange); } catch (err) {}
          }
        }
        function cmd(name, value) {
          __restore();
          document.execCommand(name, false, (value === undefined ? null : value));
          __markDirty();
        }
        function block(tag) {
          __restore();
          var cur = '';
          try { cur = document.queryCommandValue('formatBlock') || ''; } catch (err) {}
          var target = (cur.toLowerCase() === tag.toLowerCase()) ? 'div' : tag;
          document.execCommand('formatBlock', false, target);
          __markDirty();
        }
        function __getHTML() {
          var e = document.getElementById('editor');
          if (!e) return '';
          var text = (e.textContent || '').trim();
          if (!text && !e.querySelector('img,table,hr,pre')) return '';
          return e.innerHTML;
        }
        function __focusEnd() {
          var e = document.getElementById('editor');
          if (!e) return;
          e.focus();
          var r = document.createRange();
          r.selectNodeContents(e);
          r.collapse(false);
          var s = window.getSelection();
          s.removeAllRanges();
          s.addRange(r);
        }
        document.addEventListener('input', __markDirty);
        </script>
        </body></html>
        """
    }
}
