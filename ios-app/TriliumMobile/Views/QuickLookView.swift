import UIKit
import QuickLook

/// 系统 QuickLook 预览（PDF / Office / 图片 / 文本），走 UIKit 原生 present。
///
/// ⚠️ 为什么不用 SwiftUI `.sheet` 包 UIViewControllerRepresentable：
///   - 嵌在 sheet 里的 QLPreviewController **拿不到自己的「完成」按钮**
///     （它只在作为被 present 的控制器时才显示导航栏按钮）→ 用户「关不掉」
///   - 它的内部滚动视图和 sheet 的下拉关闭手势抢事件 → 用户「上滑下滑滑不动」
///   原生 present 之后：Done 按钮、捏合缩放、滚动、分享全由系统接管。
final class QuickLookPresenter: NSObject, QLPreviewControllerDataSource {
    static let shared = QuickLookPresenter()

    private var url: URL?
    private var lastKey: String = ""
    private var lastPresentAt: Date = .distantPast

    func present(_ url: URL) {
        // ⚠️ 防重复打开（2026-10-20 日志实证）：同一个文件在 1 秒内被 present 了两次，
        //    中间还夹了一次根视图重建。重复 present 会叠两层 QuickLook，
        //    用户关掉一层下面还有一层，也会白白多占一份内存（大 PDF 尤其明显）。
        let key = url.absoluteString
        if key == lastKey, Date().timeIntervalSince(lastPresentAt) < 2 {
            AppLogger.shared.log("QuickLook 忽略重复打开: \(url.lastPathComponent)")
            return
        }
        lastKey = key
        lastPresentAt = Date()
        self.url = url
        let ql = QLPreviewController()
        ql.dataSource = self
        guard let top = Self.topViewController() else {
            AppLogger.shared.log("QuickLook 打开失败：找不到顶层控制器")
            return
        }
        top.present(ql, animated: true)
        AppLogger.shared.log("QuickLook 打开: \(url.lastPathComponent)")
        // 闪退面包屑：预览大附件是内存压力最大的场景之一，死在这儿要能看出来
        CrashBreadcrumb.markStage("预览附件 \(url.lastPathComponent)")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        url == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        (url ?? URL(fileURLWithPath: "/dev/null")) as NSURL
    }

    /// 最顶层控制器（多层 present 要一路往下找，否则 present 会失败）
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
