import SwiftUI
import WebKit
import UIKit
import Photos

/// 本地 HTML 渲染（loadHTMLString，不加载 Trilium 桌面页）。
/// baseURL 指向服务器：笔记里的相对路径图片/附件才能加载。
/// 传 noteId 时记忆阅读进度：重进笔记自动滚到上次位置。
struct ContentWebView: UIViewRepresentable {
    let html: String
    var noteId: String = ""
    /// 点击笔记内链接时回调（Trilium 链接 → App 内打开该笔记）
    var onOpenNote: ((String) -> Void)? = nil
    /// JS 上报的大纲（h1~h3）
    var onOutline: (([OutlineItem]) -> Void)? = nil
    /// 跳转到大纲第 index 项（变化时驱动 evaluateJavaScript 滚动）
    var jumpToIndex: Int? = nil
    /// ⚠️ 正文是网页：它的 `prefers-color-scheme` 只认 **UIKit 外观**，
    ///    SwiftUI 的 preferredColorScheme 不会自动透传进来（界面黑了、正文还白）。
    ///    靠这个环境变量把当前外观显式塞给 WKWebView。
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(noteId: noteId, onOpenNote: onOpenNote, onOutline: onOutline)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, WKScriptMessageHandler {
        let noteId: String
        let onOpenNote: ((String) -> Void)?
        let onOutline: (([OutlineItem]) -> Void)?
        var lastHTML = ""
        var hasRestored = false
        var lastSaveTime: TimeInterval = 0
        var lastJump: Int?
        weak var webView: WKWebView?

        init(noteId: String, onOpenNote: ((String) -> Void)?, onOutline: (([OutlineItem]) -> Void)?) {
            self.noteId = noteId
            self.onOpenNote = onOpenNote
            self.onOutline = onOutline
        }

        /// JS 长按图片 → postMessage("imgsave") → 下载 → 存相册；"outline" → 大纲上报
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "imgsave":
                guard let src = message.body as? String, !src.isEmpty else { return }
                saveImageToPhotos(src: src)
            case "outline":
                guard let arr = message.body as? [[Any]] else { return }
                var items: [OutlineItem] = []
                for (i, row) in arr.enumerated() {
                    if row.count >= 2, let lvl = row[0] as? Int, let txt = row[1] as? String, !txt.isEmpty {
                        items.append(OutlineItem(id: i, level: lvl, text: txt))
                    }
                }
                DispatchQueue.main.async { [onOutline] in onOutline?(items) }
            default:
                break
            }
        }

        private func saveImageToPhotos(src: String) {
            let url: URL?
            if src.hasPrefix("http://") || src.hasPrefix("https://") {
                url = URL(string: src)
            } else {
                url = URL(string: src, relativeTo: AppSettings.shared.serverURL)
            }
            guard let target = url else { return }
            URLSession.shared.dataTask(with: target) { data, _, _ in
                guard let data, let img = UIImage(data: data) else {
                    DispatchQueue.main.async {
                        AppLogger.shared.log("图片下载失败: \(target.absoluteString.prefix(80))")
                    }
                    return
                }
                // .addOnly：只需「添加到相册」权限，不请求读相册
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    guard status == .authorized || status == .limited else {
                        DispatchQueue.main.async { AppLogger.shared.log("无相册写入权限，保存取消") }
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAsset(from: img)
                    }, completionHandler: { ok, err in
                        DispatchQueue.main.async {
                            if ok {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                AppLogger.shared.log("图片已保存到相册")
                            } else {
                                AppLogger.shared.log("保存失败: \(err?.localizedDescription ?? "?")")
                            }
                        }
                    })
                }
            }.resume()
        }

        private var posKey: String { "trilium.readpos.\(noteId)" }

        /// 链接拦截（loadHTMLString 的 baseURL 指向服务器，不拦的话点链接
        /// 会把整个阅读页导航到 Trilium 桌面页/外部站点，阅读进度全丢）：
        ///   - 站内笔记链接（#root/…=noteId）→ 回调 App 内打开
        ///   - 其他 http/https 外链 → Safari 打开
        ///   - 其余（初始 loadHTMLString、子资源加载）→ 放行
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)

            // 站内笔记链接：形如 <server>/#root/xxx=noteId 或 <server>/xxx?noteId=yyy
            if let nid = Self.noteId(from: url, base: AppSettings.shared.serverURL), !nid.isEmpty {
                DispatchQueue.main.async { [onOpenNote] in onOpenNote?(nid) }
                return
            }

            // 外链交 Safari
            if url.scheme == "http" || url.scheme == "https" {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
        }

        /// 从 Trilium 链接 URL 中提取 noteId（桌面端链接格式 #root/父=noteId）。
        private static func noteId(from url: URL, base: URL) -> String? {
            guard url.host == base.host, url.port == base.port else { return nil }
            // 优先 query 参数 noteId=
            if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let q = comps.queryItems?.first(where: { $0.name == "noteId" })?.value, !q.isEmpty {
                return q
            }
            // fragment "#root/a/b=noteId"：取最后一段 = 后面的部分
            if let frag = url.fragment?.split(separator: "/").last {
                let s = String(frag)
                if let eq = s.lastIndex(of: "=") {
                    return String(s[s.index(after: eq)...])
                }
                return s
            }
            // path 末段兜底
            if let last = url.pathComponents.last, last != "/" {
                return last.contains("=") ? last.split(separator: "=").last.map(String.init) : last
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 首次加载完成：恢复上次的阅读位置（需等内容布局出高度）
            guard !hasRestored, !noteId.isEmpty else { return }
            hasRestored = true
            let y = UserDefaults.standard.double(forKey: posKey)
            guard y > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak webView] in
                guard let sv = webView?.scrollView else { return }
                guard sv.contentSize.height > sv.frame.height else { return }
                let maxY = sv.contentSize.height - sv.frame.height
                sv.setContentOffset(CGPoint(x: 0, y: min(y, maxY)), animated: false)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 节流保存阅读进度（0.5s 一次，避免滚动时高频写盘）
            guard hasRestored, !noteId.isEmpty else { return }
            let now = Date().timeIntervalSince1970
            guard now - lastSaveTime > 0.5 else { return }
            lastSaveTime = now
            UserDefaults.standard.set(scrollView.contentOffset.y, forKey: posKey)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        // 共享进程池：正文/编辑器/服务端页复用同一个 WebContent 进程，
        // 新建 WKWebView 的启动开销和内存都明显更低（以前每篇笔记都单开进程）
        cfg.processPool = FullWebView.sharedProcessPool
        let ucc = cfg.userContentController
        ucc.add(context.coordinator, name: "imgsave")
        ucc.add(context.coordinator, name: "outline")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.webView = wv
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        // 外观透传（深色模式下正文 CSS 的 prefers-color-scheme 才会跟着变）
        wv.overrideUserInterfaceStyle = (colorScheme == .dark) ? .dark : .light
        // 隐藏右侧竖向滚动指示条（用户嫌它像一根「进度条」挡内容）
        wv.scrollView.showsVerticalScrollIndicator = false
        wv.navigationDelegate = context.coordinator
        wv.scrollView.delegate = context.coordinator
        context.coordinator.lastHTML = html
        wv.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 外观切换（系统深色切换 / 设置里改档）→ 同步给网页，正文配色才跟得上
        let style: UIUserInterfaceStyle = (colorScheme == .dark) ? .dark : .light
        if uiView.overrideUserInterfaceStyle != style { uiView.overrideUserInterfaceStyle = style }
        // 跳转索引被重置为 nil 时（同一条目可重复点击）同步清记录
        if jumpToIndex == nil { context.coordinator.lastJump = nil }
        // 大纲跳转：索引变化时驱动 WebView 滚动到对应标题
        if let idx = jumpToIndex, context.coordinator.lastJump != idx {
            context.coordinator.lastJump = idx
            uiView.evaluateJavaScript(
                "document.querySelectorAll('h1,h2,h3')[\(idx)].scrollIntoView({behavior:'smooth'})",
                completionHandler: nil)
        }
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        uiView.loadHTMLString(html, baseURL: AppSettings.shared.serverURL)
    }
}

/// 大纲目录条目（id = h1~h3 NodeList 中的下标，跳转时按同序查询）
struct OutlineItem: Identifiable {
    let id: Int
    let level: Int
    let text: String
}

/// 系统分享面板（UIActivityViewController 包装）
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 网页编辑器兜底：加载服务端 Trilium 页面（#root/<noteId>），完整 CKEditor 能力
/// （表格/LaTeX/图片插入/格式刷）。首次使用需在页面里登录一次（密码+验证码），
/// cookie 由 WKWebsiteDataStore 持久化，之后免登录。
struct WebEditorView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            FullWebView(url: editorURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("网页编辑")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }

    private var editorURL: URL {
        let base = AppSettings.shared.serverURL
        return URL(string: base.absoluteString + "/#root/" + note.noteId) ?? base
    }
}

/// 完整网页视图（共享进程池，cookie/登录态跨打开复用）
struct FullWebView: UIViewRepresentable {
    static let sharedProcessPool = WKProcessPool()
    let url: URL
    /// 网页编辑器 / 服务端页面同样只认 UIKit 外观，必须显式透传
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = FullWebView.sharedProcessPool
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        wv.overrideUserInterfaceStyle = (colorScheme == .dark) ? .dark : .light
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let style: UIUserInterfaceStyle = (colorScheme == .dark) ? .dark : .light
        if uiView.overrideUserInterfaceStyle != style { uiView.overrideUserInterfaceStyle = style }
    }
}

/// 图片查看：双指捏合缩放（1x~6x）+ 双击 1x/2x 切换；放大后可拖动平移，缩回 1x 自动复位
struct ZoomableImageView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private func reset() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
        }
    }

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = min(max(lastScale * v, 1), 6) }
                        .onEnded { _ in
                            lastScale = scale
                            if scale <= 1.01 { reset() }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: lastOffset.width + v.translation.width,
                                            height: lastOffset.height + v.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
                .onTapGesture(count: 2) {
                    if scale > 1 { reset() } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { scale = 2; lastScale = 2 }
                    }
                }
        }
    }
}
