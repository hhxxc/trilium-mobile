import SwiftUI
import WebKit

/// 编辑器：WKWebView 加载 Trilium 服务端的网页编辑器（表格/代码/图片完整支持）。
///
/// 首版策略：直接加载服务端编辑页。因服务端开启了两步验证（TOTP），网页登录态与
/// ETAPI token 是两套体系；这里先加载服务端首页，用户若需登录可在 WebView 内完成。
/// 后续优化：注入 ETAPI token 或做单点登录打通。
struct EditorView: View {
    let note: Note

    var body: some View {
        TriliumWebView(url: editorURL)
            .navigationTitle(note.title.isEmpty ? "笔记" : note.title)
            .navigationBarTitleDisplayMode(.inline)
    }

    /// 编辑器 URL：跳转到服务端的笔记页。
    /// TriliumNext 前端 hash 路由格式是 #root/<noteId>（内部链接格式），
    /// 直接定位到具体笔记。
    private var editorURL: URL {
        let base = AppSettings.shared.serverURL
        let urlStr = base.absoluteString + "/#" + "root/" + note.noteId
        return URL(string: urlStr) ?? base
    }
}

/// 包装 WKWebView 的 SwiftUI 视图
struct TriliumWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {}
}
