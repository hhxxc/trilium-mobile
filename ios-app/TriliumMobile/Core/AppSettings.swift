import Foundation

/// 服务器连接设置（服务器地址 + ETAPI token），持久化到 UserDefaults。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let server = "trilium.server"
        static let token = "trilium.token"
        static let inboxNoteId = "trilium.inboxNoteId"
        static let inboxTitle = "trilium.inboxTitle"
    }

    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: Keys.server) }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: Keys.token) }
    }
    @Published var inboxNoteId: String {
        didSet { UserDefaults.standard.set(inboxNoteId, forKey: Keys.inboxNoteId) }
    }
    @Published var inboxTitle: String {
        didSet { UserDefaults.standard.set(inboxTitle, forKey: Keys.inboxTitle) }
    }

    /// 规范化后的服务器基地址（去尾部斜杠）
    var serverURL: URL {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s) ?? URL(string: AppConfig.defaultServer)!
    }

    /// 是否已登录（有 token 即视为已登录，业务接口 401 时再踢回登录）
    var isLoggedIn: Bool { !token.isEmpty }

    private init() {
        let d = UserDefaults.standard
        server = d.string(forKey: Keys.server) ?? AppConfig.defaultServer
        token = d.string(forKey: Keys.token) ?? ""
        inboxNoteId = d.string(forKey: Keys.inboxNoteId) ?? ""
        inboxTitle = d.string(forKey: Keys.inboxTitle) ?? AppConfig.defaultInboxTitle
    }

    func save(token: String, server: String) {
        self.token = token
        self.server = server
    }

    func logout() {
        token = ""
    }
}
