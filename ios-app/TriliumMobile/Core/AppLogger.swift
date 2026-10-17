import Foundation

/// 轻量操作日志：记录关键事件（登录/退出/token 变化/界面切换/错误），
/// 用于排查「点按钮没反应」类问题。存内存 + UserDefaults（最多 200 条），
/// 设置页可查看/复制，便于反馈时带上操作轨迹。
final class AppLogger {
    static let shared = AppLogger()

    private let maxEntries = 200
    private let key = "trilium.applog"

    private(set) var entries: [String] = []

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func log(_ message: String) {
        let line = "[\(Self.timestamp())] \(message)"
        entries.append(line)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        UserDefaults.standard.set(entries, forKey: key)
        // 同时打控制台，方便连 Xcode 调试时实时看
        print("[AppLog] \(line)")
    }

    func clear() {
        entries.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
