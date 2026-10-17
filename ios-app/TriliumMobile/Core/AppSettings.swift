import Foundation

/// 服务器连接设置（服务器地址 + ETAPI token），持久化到 UserDefaults。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let server = "trilium.server"
        static let token = "trilium.token"
        static let inboxNoteId = "trilium.inboxNoteId"
        static let inboxTitle = "trilium.inboxTitle"
        static let readerFontScale = "trilium.readerFontScale"
    }

    /// 阅读页字号缩放（1.0 = 标准；详情页 Aa 菜单调节，持久化）
    @Published var readerFontScale: Double {
        didSet { UserDefaults.standard.set(readerFontScale, forKey: Keys.readerFontScale) }
    }

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: Keys.server) }
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
        token = savedToken
        inboxNoteId = d.string(forKey: Keys.inboxNoteId) ?? ""
        inboxTitle = d.string(forKey: Keys.inboxTitle) ?? AppConfig.defaultInboxTitle
        readerFontScale = d.object(forKey: Keys.readerFontScale) as? Double ?? 1.0
        isLoggedIn = !savedToken.isEmpty  // 用局部变量，避免 init 里访问 self.token 的初始化顺序问题
    }

    func save(token: String, server: String) {
        // 服务器地址变了必须清缓存：缓存里的笔记内容/图片来自旧服务器，串台会显示错数据
        let oldServer = self.server.trimmingCharacters(in: .whitespacesAndNewlines)
        let newServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = server
        if oldServer != newServer {
            NoteCache.shared.clearAll()
        }
        self.token = token  // token 的 didSet 会自动更新 isLoggedIn
    }

    func logout() {
        // 退出登录清本地缓存：隐私（换人/换设备不留痕）+ 防下次登录串台
        NoteCache.shared.clearAll()
        self.token = ""  // token 的 didSet 会自动把 isLoggedIn 置 false
    }
}
