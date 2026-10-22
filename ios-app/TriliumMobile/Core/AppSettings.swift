import Foundation
import LocalAuthentication
import SwiftUI
import UIKit

/// 外观模式（设置页三档）。
/// ⚠️ 为什么需要「强制」档：阅读页正文是 WKWebView，它的 `prefers-color-scheme`
/// 只看 **系统** 外观，不会管 App 自己想用什么 —— 所以强制档必须同时把
/// `UIUserInterfaceStyle` 透传给 WebView（见 ContentWebView），否则界面黑了、正文还是白的。
enum ThemeMode: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// SwiftUI 的 preferredColorScheme：nil = 跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// UIKit / WKWebView 用：unspecified = 跟随系统
    var uiStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

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
        static let themeMode = "trilium.themeMode"
        /// 安装标记：UserDefaults 卸载即清，用来识别「重装」
        static let installMarker = "trilium.installed"
    }

    /// 外观：跟随系统 / 浅色 / 深色（默认跟随系统，与以前的行为一致）
    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: Keys.themeMode) }
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
        didSet {
            UserDefaults.standard.set(server, forKey: Keys.server)
            cachedServerURL = nil   // 地址变了，缓存的 URL 作废
        }
    }
    /// 备用服务器地址：当前地址连不上（证书过期 / 出门回家换网）时自动互换
    @Published var serverBackup: String {
        didSet { UserDefaults.standard.set(serverBackup, forKey: Keys.serverBackup) }
    }
    @Published var token: String {
        didSet {
            // 凭据进 Keychain（UserDefaults 是明文）；写失败才退回旧位置，
            // 宁可弱一点，也不能让用户莫名掉登录
            if Keychain.set(token) {
                UserDefaults.standard.removeObject(forKey: Keys.token)
            } else {
                UserDefaults.standard.set(token, forKey: Keys.token)
            }
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
    ///
    /// 缓存结果：每个 API 请求都会读它，而清洗地址要逐字符过白名单 + 解析 URL。
    /// 地址只在设置页/自动切换时变，变时清缓存（见 server didSet）。
    private var cachedServerURL: URL?

    var serverURL: URL {
        if let c = cachedServerURL { return c }
        // 清洗是最后防线：就算存量数据里混了脏字符，请求层拿到的永远是干净的
        let s = Self.sanitizeServerAddress(server)
        let u = URL(string: s) ?? URL(string: AppConfig.defaultServer)!
        cachedServerURL = u
        return u
    }

    // MARK: - 地址清洗（防粘贴脏字符）

    /// 服务器基地址允许的字符集：scheme + host + 端口 + 路径。
    /// 括号/空格/中文/引号等一律视为粘贴带入的脏字符。
    private static let allowedAddressChars =
        Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/@%")

    /// 清洗服务器地址：全角转半角 → 白名单过滤 → 去尾斜杠。
    ///
    /// 背景（2026-10-20 实测事故）：从微信/备忘录粘贴地址会混入全角括号 `（）`。
    /// iOS 的 URL(string:) 对全角字符**放行**，但 DNS 永远解析不出这个域名 →
    /// 所有请求报 "A server with the specified hostname could not be found"，
    /// 请求根本没出手机，服务端日志一片空白 —— 极易误判成「服务端挂了」。
    /// 巢记 NestKeep 同日中招，本端为同款修复。
    ///
    /// 注意不能只「全角转半角」：`https://host）` 转成 `https://host)` 后
    /// 半角括号照样让 DNS 死掉 —— 地址里根本不该出现括号，白名单直接剔除。
    static func sanitizeServerAddress(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if v >= 0xFF01 && v <= 0xFF5E, let half = Unicode.Scalar(v - 0xFEE0) {
                out.unicodeScalars.append(half)      // 全角 ASCII（：／．（）等）→ 半角
            } else if v == 0x3000 {
                out.append(" ")                      // 全角空格 → 半角（随后被白名单剔掉）
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        var s = String(out.filter { allowedAddressChars.contains($0) })
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 地址里是否混入了需要剔除的脏字符（输入框旁贴提示用：全角符号肉眼看不见）
    static func serverAddressHasJunk(_ raw: String) -> Bool {
        raw.contains { !allowedAddressChars.contains($0) }
    }

    /// 清洗后是否是合法地址（http/https + 非空 host）—— 登录/保存按钮的启用条件
    static func isValidServerAddress(_ raw: String) -> Bool {
        let s = sanitizeServerAddress(raw)
        guard let u = URL(string: s),
              let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = u.host, !host.isEmpty else { return false }
        return true
    }

    private init() {
        let d = UserDefaults.standard
        let savedServer = d.string(forKey: Keys.server) ?? AppConfig.defaultServer
        // ⚠️ Keychain 里的数据**卸载重装不会清**，而 UserDefaults 会。
        //   没有安装标记 = 全新安装/重装 → 先把 Keychain 里的历史 token 丢掉，
        //   否则重装后会莫名其妙带着旧登录态（这个行为之前明确被否过）。
        if !d.bool(forKey: Keys.installMarker) {
            Keychain.set("")
            d.set(true, forKey: Keys.installMarker)
        }
        // token 优先 Keychain；老版本存在 UserDefaults 里的明文 → 迁移后清掉
        var savedToken = Keychain.get() ?? ""
        if savedToken.isEmpty, let legacy = d.string(forKey: Keys.token), !legacy.isEmpty {
            savedToken = legacy
            if Keychain.set(legacy) { d.removeObject(forKey: Keys.token) }
        }
        server = savedServer
        serverBackup = d.string(forKey: Keys.serverBackup) ?? AppConfig.defaultBackupServer
        token = savedToken
        inboxNoteId = d.string(forKey: Keys.inboxNoteId) ?? ""
        inboxTitle = d.string(forKey: Keys.inboxTitle) ?? AppConfig.defaultInboxTitle
        readerFontScale = d.object(forKey: Keys.readerFontScale) as? Double ?? 1.0
        lockEnabled = d.bool(forKey: Keys.lockEnabled)
        themeMode = ThemeMode(rawValue: d.object(forKey: Keys.themeMode) as? Int ?? 0) ?? .system
        isLoggedIn = !savedToken.isEmpty  // 用局部变量，避免 init 里访问 self.token 的初始化顺序问题

        // 存量脏地址自愈（2026-10-20）：粘贴混入的全角括号会导致 DNS 直接解析失败，
        // 启动时清洗一次并回写，用户不用退出登录手动改。
        // ⚠️ init 里的赋值不触发 didSet，必须显式 d.set 回写
        let cleanedServer = Self.sanitizeServerAddress(server)
        if cleanedServer != server {
            AppLogger.shared.log("服务器地址含脏字符，已自动修复：[\(server)] → [\(cleanedServer)]")
            server = cleanedServer
            d.set(cleanedServer, forKey: Keys.server)
        }
        let cleanedBackup = Self.sanitizeServerAddress(serverBackup)
        if cleanedBackup != serverBackup {
            AppLogger.shared.log("备用地址含脏字符，已自动修复：[\(serverBackup)] → [\(cleanedBackup)]")
            serverBackup = cleanedBackup
            d.set(cleanedBackup, forKey: Keys.serverBackup)
        }
    }

    /// 弹出生物识别/密码认证（回调回主线程）。
    /// 回调带上失败原因：以前失败只有一个 false，界面上就剩一个点了没反应的「解锁」按钮。
    func authenticate(_ completion: @escaping (Bool, String?) -> Void) {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "用密码解锁"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // 设备既没 Face ID 也没设密码：没有可用的锁，视为通过（否则用户会被永久锁在外面）
            AppLogger.shared.log("应用锁：设备不支持认证（\(err?.localizedDescription ?? "未知")），直接放行")
            completion(true, nil)
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 Trilium") { ok, error in
            let reason = ok ? nil : Self.describeAuthError(error)
            if let reason { AppLogger.shared.log("应用锁认证失败：\(reason)") }
            DispatchQueue.main.async { completion(ok, reason) }
        }
    }

    /// LAError → 一句人话（否则只有 "The operation couldn't be completed"）
    static func describeAuthError(_ error: Error?) -> String {
        guard let e = error as? LAError else {
            return error?.localizedDescription ?? "认证失败"
        }
        switch e.code {
        case .userCancel, .appCancel: return "已取消认证"
        case .systemCancel: return "系统中断了认证，请重试"
        case .biometryNotAvailable: return "Face ID 不可用"
        case .biometryNotEnrolled: return "尚未录入 Face ID（去 设置 → 面容 ID 里添加）"
        case .biometryLockout: return "Face ID 被锁定，请先用密码解锁一次设备"
        case .passcodeNotSet: return "设备未设置密码"
        case .authenticationFailed: return "认证失败，请重试"
        default: return e.localizedDescription
        }
    }

    /// 改服务器地址（设置页直接编辑 / 登录保存共用入口）：
    /// 清洗脏字符 → 地址变了清缓存 → 与备用地址撞车则互换
    func updateServer(_ raw: String) {
        let oldServer = self.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let newServer = Self.sanitizeServerAddress(raw)
        self.server = newServer
        if oldServer != newServer {
            // 服务器地址变了必须清缓存：缓存里的笔记内容/图片来自旧服务器，串台会显示错数据
            NoteCache.shared.clearAll()
            // 手动把「备用地址」填成了主地址 → 把原来那条挪到备用，保证主备始终成对，
            // 之后出门/回家、证书恢复都能自动切回去
            if newServer == self.serverBackup.trimmingCharacters(in: .whitespacesAndNewlines),
               !oldServer.isEmpty {
                self.serverBackup = oldServer
            }
        }
    }

    func save(token: String, server: String) {
        updateServer(server)
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
        // 先清洗：带全角脏字符的地址 DNS 直接解析失败，会误判成「服务器不通」触发误切换
        let s = AppSettings.sanitizeServerAddress(raw)
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
        // 通知界面重拉：首屏不再等探测，列表可能已经对着旧地址失败过一次
        NotificationCenter.default.post(name: .serverSwitched, object: nil)
        return true
    }
}

extension Notification.Name {
    /// 主备地址自动互换完成（列表/目录听到后重拉，避免继续显示旧地址的失败结果）
    static let serverSwitched = Notification.Name("trilium.serverSwitched")
}
