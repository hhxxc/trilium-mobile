import Foundation
import LocalAuthentication

/// 服务器连接设置（服务器地址 + ETAPI token），持久化到 UserDefaults。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let server = "trilium.server"
        static let serverBackup = "trilium.serverBackup"
        static let token = "trilium.token"
        static let inboxNoteId = "trilium.inboxNoteId"
        static let inboxTitle = "trilium.inboxTitle"
        static let readerFontScale = "trilium.readerFontScale"
        static let lockEnabled = "trilium.lockEnabled"
    }

    /// 生物识别锁开关（FaceID/触控ID，失败回退设备密码；RootView 门禁）
    @Published var lockEnabled: Bool {
        didSet { UserDefaults.standard.set(lockEnabled, forKey: Keys.lockEnabled) }
    }

    /// 设备是否可用生物识别/密码认证（SettingsView 决定开关是否可用）
    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// 阅读页字号缩放（1.0 = 标准；详情页 Aa 菜单调节，持久化）
    @Published var readerFontScale: Double {
        didSet { UserDefaults.standard.set(readerFontScale, forKey: Keys.readerFontScale) }
    }

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: Keys.server) }
    }
    /// 备用服务器地址：当前地址连不上（证书过期 / 出门回家换网）时自动互换
    @Published var serverBackup: String {
        didSet { UserDefaults.standard.set(serverBackup, forKey: Keys.serverBackup) }
    }
    @Published var token: String {
        didSet {
            UserDefaults.standard.set(token, forKey: Keys.token)
            // 显式同步登录态，确保 RootView 的条件切换可靠触发
            isLoggedIn = !token.isEmpty
        }
    }
    @Published var inboxNoteId: String {
        didSet { UserDefaults.standard.set(inboxNoteId, forKey: Keys.inboxNoteId) }
    }
    @Published var inboxTitle: String {
        didSet { UserDefaults.standard.set(inboxTitle, forKey: Keys.inboxTitle) }
    }
    /// 登录态：独立 @Published，不用计算属性（避免 sheet/environmentObject 嵌套下响应断裂）
    @Published var isLoggedIn: Bool

    /// 规范化后的服务器基地址（去尾部斜杠）
    var serverURL: URL {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? URL(string: AppConfig.defaultServer)!
    }

    private init() {
        let d = UserDefaults.standard
        let savedServer = d.string(forKey: Keys.server) ?? AppConfig.defaultServer
        let savedToken = d.string(forKey: Keys.token) ?? ""
        server = savedServer
        serverBackup = d.string(forKey: Keys.serverBackup) ?? AppConfig.defaultBackupServer
        token = savedToken
        inboxNoteId = d.string(forKey: Keys.inboxNoteId) ?? ""
        inboxTitle = d.string(forKey: Keys.inboxTitle) ?? AppConfig.defaultInboxTitle
        readerFontScale = d.object(forKey: Keys.readerFontScale) as? Double ?? 1.0
        lockEnabled = d.bool(forKey: Keys.lockEnabled)
        isLoggedIn = !savedToken.isEmpty  // 用局部变量，避免 init 里访问 self.token 的初始化顺序问题
    }

    /// 弹出生物识别/密码认证（回调回主线程）
    func authenticate(_ completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "用密码解锁"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            completion(true)  // 设备没设任何锁，视为通过
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Trilium") { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func save(token: String, server: String) {
        // 服务器地址变了必须清缓存：缓存里的笔记内容/图片来自旧服务器，串台会显示错数据
        let oldServer = self.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let newServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = server
        if oldServer != newServer {
            NoteCache.shared.clearAll()
            // 手动把「备用地址」填成了主地址 → 把原来那条挪到备用，保证主备始终成对，
            // 之后出门/回家、证书恢复都能自动切回去
            if newServer == self.serverBackup.trimmingCharacters(in: .whitespacesAndNewlines),
               !oldServer.isEmpty {
                self.serverBackup = oldServer
            }
        }
        self.token = token  // token 的 didSet 会自动更新 isLoggedIn
    }

    func logout() {
        // 退出登录清本地缓存：隐私（换人/换设备不留痕）+ 防下次登录串台
        NoteCache.shared.clearAll()
        self.token = ""  // token 的 didSet 会自动把 isLoggedIn 置 false
    }
}

/// 服务器可达性探测 + 主备地址自动互换。
///
/// 为什么需要（都是真发生过的）：
///   - 穿透服务的通配证书到期（实测：ddnsto 证书 2026-10-17 19:36 过期，公网整条链路 TLS 失败）
///   - 出门 / 回家换网：内网地址出门就废，公网地址在家虽通但绕远
/// 策略：当前地址不通、备用地址通 → **两者互换**并持久化。
/// token 是服务端签发的、与访问地址无关，所以换地址**不需要重新登录**。
enum ServerProbe {
    /// 探活：401/403 也算「通」（说明服务端活着，只是没带 token）
    static func reachable(_ raw: String, timeout: TimeInterval = 4) async -> Bool {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let url = URL(string: s + "/etapi/app-info") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let token = AppSettings.shared.token
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "Authorization") }
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<500).contains(http.statusCode)
    }

    /// 保证至少有一个地址可用；当前地址不通就用备用地址顶替（两边互换）
    @discardableResult
    static func ensureReachable() async -> Bool {
        let s = AppSettings.shared
        let primary = s.server
        let backup = s.serverBackup
        guard !backup.isEmpty, backup != primary else { return true }
        if await reachable(primary) { return true }

        AppLogger.shared.log("当前地址不可达，尝试备用: \(backup)")
        guard await reachable(backup) else {
            AppLogger.shared.log("备用地址同样不可达: \(backup)")
            return false
        }
        s.serverBackup = primary
        s.server = backup
        AppLogger.shared.log("已切到备用地址 \(backup)（原地址转为备用）")
        return true
    }
}
