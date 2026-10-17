import SwiftUI
import WebKit

/// 编辑器：WKWebView 加载 Trilium 服务端的网页编辑器（表格/代码/图片完整支持）。
/// 从阅读页点「编辑」进入；编辑完关闭后阅读页自动刷新。
struct EditorView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            TriliumWebView(url: editorURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(note.title.isEmpty ? "编辑" : note.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
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
