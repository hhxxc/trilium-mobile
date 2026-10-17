import SwiftUI
import UIKit

/// 后台下载会话的事件入口。
/// 系统把后台传输的结果全部交付完后，通过这个方法把 completionHandler 交给 App；
/// 必须转交给 UpdateCenter，等它的 urlSessionDidFinishEvents 再还回去 ——
/// 否则系统会认为后台任务没结束，多次之后会限制 App 的后台唤醒。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        UpdateCenter.shared.backgroundCompletionHandler = completionHandler
        AppLogger.shared.log("后台下载会话被唤醒: \(identifier)")
    }
}

@main
struct TriliumMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // 全 App 唯一的设置实例（单例），所有视图通过 @ObservedObject 引用，
    // 避免 @StateObject 包装单例造成的「多实例/通知断裂」隐患。
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // 启动即建好后台上传会话：恢复上次的下载进度、接管还活着的任务
        _ = UpdateCenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
        }
    }
}
