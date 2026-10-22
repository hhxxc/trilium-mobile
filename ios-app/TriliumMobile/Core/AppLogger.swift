import Foundation

/// 轻量操作日志：记录关键事件（登录/退出/token 变化/界面切换/错误），
/// 用于排查「点按钮没反应」类问题。存内存 + UserDefaults（最多 200 条），
/// 设置页可查看/复制，便于反馈时带上操作轨迹。
///
/// ⚠️ 性能（2026-10-22 深度优化）：旧版每条日志都同步 `UserDefaults.set`，
///    200 条 × 20KB 的 plist 每次全量重写 —— 列表加载一屏会打十几条日志，
///    全落在主线程上。现在改成「内存立即生效 + 合并落盘（0.8s）」，
///    退出/进后台时再 flush 一次，诊断内容一条不少。
final class AppLogger {
    static let shared = AppLogger()

    private let maxEntries = 200
    private let key = "trilium.applog"
    private let lock = NSLock()
    private var storage: [String] = []
    private var flushWork: DispatchWorkItem?

    /// 只读快照（设置页展示用；跨线程安全）
    var entries: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    private init() {
        storage = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)"
        lock.lock()
        storage.append(line)
        if storage.count > maxEntries {
            storage.removeFirst(storage.count - maxEntries)
        }
        lock.unlock()
        scheduleFlush()
        // 同时打控制台，方便连 Xcode 调试时实时看
        print("[AppLog] \(line)")
    }

    /// 合并写盘：0.8s 内的多条日志只落一次（执行时取最新 storage，不会丢条目）
    private func scheduleFlush() {
        lock.lock()
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let latest = self.storage
            self.lock.unlock()
            UserDefaults.standard.set(latest, forKey: self.key)
        }
        flushWork = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// 立即落盘（进后台 / 退出登录 / 用户手动复制日志前调用）
    func flush() {
        lock.lock()
        flushWork?.cancel()
        let latest = storage
        lock.unlock()
        UserDefaults.standard.set(latest, forKey: key)
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        flushWork?.cancel()
        lock.unlock()
        UserDefaults.standard.removeObject(forKey: key)
    }

    // 缓存 formatter：DateFormatter 创建开销大，不能每次 log 都新建
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}
