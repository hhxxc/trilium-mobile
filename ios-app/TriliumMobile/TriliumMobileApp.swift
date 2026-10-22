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

    /// 内存警告：先丢内存里的附件/摘要副本（磁盘缓存不动）。
    /// 大图笔记的原图位图是 OOM 头号来源，清掉后下次读盘/降采样重来即可。
    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        NoteCache.shared.trimMemory()
    }
}

/// 崩溃面包屑：只是为了让「闪退」在诊断日志里留下痕迹。
/// 判定依据：正常退到后台会打一次 background 时间戳；如果上次启动之后没有这个戳，
/// 说明上次是异常结束（被系统杀掉 / 崩溃），下次启动就在日志里写一句。
enum CrashBreadcrumb {
    private static let launchKey = "trilium.lastLaunchAt"
    private static let backgroundKey = "trilium.lastBackgroundAt"
    private static let stageKey = "trilium.lastStage"

    /// 在「重」节点记一笔当前在干什么（下载 / 预览附件 / 编辑…）。
    /// ⚠️ 光有「疑似闪退」没用——不知道死在哪个阶段就只能瞎猜。
    ///    2026-10-20 日志实证：一次死在下载 v1.6.9 中途（有「开始下载」无「下载完成」），
    ///    一次死在打开 PDF 前后，靠 stage 下次就能直接说出来。
    ///    只在关键节点调，别在列表加载这种高频路径上调（频繁写 UserDefaults 没意义）。
    static func markStage(_ stage: String) {
        UserDefaults.standard.set(stage, forKey: stageKey)
    }

    static func markLaunch() {
        let d = UserDefaults.standard
        let prevLaunch = d.double(forKey: launchKey)
        let prevBackground = d.double(forKey: backgroundKey)
        if prevLaunch > 0, prevBackground < prevLaunch {
            let stage = d.string(forKey: stageKey) ?? "未知"
            let held = Int(Date().timeIntervalSince1970 - prevLaunch)
            AppLogger.shared.log("⚠️ 上次会话未正常结束（疑似闪退），最后停留在：\(stage)（距上次启动 \(held)s）")
        }
        d.set(Date().timeIntervalSince1970, forKey: launchKey)
        markStage("启动")
    }

    static func markBackground() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: backgroundKey)
        // 留一条可见的日志：下次排查时能直接从日志里看出上次是**正常**退到后台的，
        // 而不是只有个时间戳、还得去猜
        AppLogger.shared.log("会话进入后台（正常结束标记，下次启动不会再报闪退）")
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
                // 外观三档：nil = 跟随系统。设在最外层才能连 sheet / UIKit 弹出层一起覆盖
                .preferredColorScheme(settings.themeMode.colorScheme)
        }
    }
}
