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

/// 崩溃面包屑：只是为了让「闪退」在诊断日志里留下痕迹。
/// 判定依据：正常退到后台会打一次 background 时间戳；如果上次启动之后没有这个戳，
/// 说明上次是异常结束（被系统杀掉 / 崩溃），下次启动就在日志里写一句。
enum CrashBreadcrumb {
    private static let launchKey = "trilium.lastLaunchAt"
    private static let backgroundKey = "trilium.lastBackgroundAt"

    static func markLaunch() {
        let d = UserDefaults.standard
        let prevLaunch = d.double(forKey: launchKey)
        let prevBackground = d.double(forKey: backgroundKey)
        if prevLaunch > 0, prevBackground < prevLaunch {
            AppLogger.shared.log("⚠️ 上次会话未正常结束（疑似闪退）")
        }
        d.set(Date().timeIntervalSince1970, forKey: launchKey)
    }

    static func markBackground() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: backgroundKey)
    }
}

@main
struct TriliumMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // 全 App 唯一的设置实例（单例），所有视图通过 @ObservedObject 引用，
    // 避免 @StateObject 包装单例造成的「多实例/通知断裂」隐患。
    @ObservedObject private var settings = AppSettings.shared

    init() {
        // ⚠️ 这里只做**不会抛异常**的初始化。
        //   以前这里建 background URLSession，而 background 会话在
        //   TrollStore/ad-hoc 签名 + 重装场景下可能抛 NSException（Swift 接不住 → 闪退）。
        //   现在 UpdateCenter 用的是普通会话，创建它不会抛。
        _ = UpdateCenter.shared
        CrashBreadcrumb.markLaunch()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
        }
    }
}
