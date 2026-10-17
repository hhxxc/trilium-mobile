import Foundation

/// 错误类型
enum APIError: LocalizedError {
    case invalidURL
    case http(status: Int)
    case invalidResponse
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效"
        case .http(let status): return "HTTP \(status)"
        case .invalidResponse: return "响应格式异常"
        case .server(let msg): return msg
        }
    }
}

/// Trilium ETAPI 客户端（原生 URLSession，无第三方依赖）。
///
/// 关键契约（与旧网页壳 api.js 一致，踩过的坑勿忘）：
///   - 登录 POST /etapi/auth/login {password, tokenName} → 201 { authToken }
///     （字段是 authToken，不是 token）
///   - 鉴权头是**裸 token**，无 "Bearer " 前缀
///   - text 笔记 content 是 HTML 字符串
///   - v0.106 无 /etapi/search-notes，搜索走 GET /etapi/notes?search=…
///   - token 随服务端重启失效 → 业务接口 401 必须清 token 踢回登录
struct ETAPIClient {
    static let shared = ETAPIClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    private var baseURL: URL { AppSettings.shared.serverURL }
    private var token: String { AppSettings.shared.token }

    // MARK: - 底层请求

    /// 发请求，返回 (data, response)；401（非登录接口）时抛 SessionExpired 信号
    private func raw(_ path: String, method: String = "GET", query: [URLQueryItem] = [],
                     body: Data? = nil, contentType: String = "application/json",
                     auth: Bool = true) async throws -> Data {
        guard var comp = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty { comp.queryItems = query }
        guard let url = comp.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth && !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "Authorization") // 裸 token，无 Bearer
        }
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            if http.statusCode == 401 && !path.hasSuffix("/auth/login") {
                // 服务端重启导致 token 失效：广播会话过期，踢回登录
                NotificationCenter.default.post(name: .sessionExpired, object: nil)
                throw APIError.http(status: 401)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw APIError.http(status: http.statusCode)
            }
        }
        return data
    }

    private func getJSON<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await raw(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - 认证

    /// 用密码换 ETAPI token（服务端返回 { authToken }，兼容 { token }）
    func login(password: String) async throws -> String {
        struct LoginResp: Decodable { let authToken: String?; let token: String? }
        let body = try JSONSerialization.data(withJSONObject: [
            "password": password, "tokenName": "trilium-mobile"
        ])
        let data = try await raw("/etapi/auth/login", method: "POST", body: body, auth: false)
        let resp = try JSONDecoder().decode(LoginResp.self, from: data)
        if let t = resp.authToken ?? resp.token, !t.isEmpty { return t }
        throw APIError.invalidResponse
    }

    func logout() async {
        try? await raw("/etapi/auth/logout", method: "POST")
    }

    func appInfo() async throws -> AppInfo {
        try await getJSON("/etapi/app-info")
    }

    // MARK: - 笔记

    func getNote(_ id: String) async throws -> Note {
        try await getJSON("/etapi/notes/\(id)")
    }

    func getContent(_ id: String) async throws -> String {
        let data = try await raw("/etapi/notes/\(id)/content")
        return String(data: data, encoding: .utf8) ?? ""
    }

    func putContent(_ id: String, content: String) async throws {
        let body = content.data(using: .utf8)
        _ = try await raw("/etapi/notes/\(id)/content", method: "PUT",
                          body: body, contentType: "text/plain")
    }

    func patchNote(_ id: String, fields: [String: Any]) async throws -> Note {
        let body = try JSONSerialization.data(withJSONObject: fields)
        let data = try await raw("/etapi/notes/\(id)", method: "PATCH", body: body)
        return try JSONDecoder().decode(Note.self, from: data)
    }

    func createNote(parentNoteId: String, title: String, content: String = "", type: String = "text") async throws -> CreateNoteResponse {
        var dict: [String: Any] = ["parentNoteId": parentNoteId, "title": title, "type": type]
        if type == "text" { dict["mime"] = "text/html" }
        if !content.isEmpty { dict["content"] = content }
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await raw("/etapi/notes", method: "POST", body: body)
        return try JSONDecoder().decode(CreateNoteResponse.self, from: data)
    }

    /// 搜索笔记。
    /// ⚠️ 关键（2026-10-17 实测根因）：v0.106 的 GET /etapi/notes 用的是**参数化排序**，
    ///   排序走 `orderBy` + `orderDirection` + `limit` 三个独立参数，**不是**搜索语法字符串。
    ///   旧代码把 "order by dateModified desc limit 30" 塞进 search 参数 → 被当成全文搜索词
    ///   → 永远搜不到 → 列表空白。
    func searchNotes(_ query: String, limit: Int = 30) async throws -> [Note] {
        var q = [URLQueryItem(name: "search", value: query)]
        q.append(URLQueryItem(name: "limit", value: String(limit)))
        let data = try await raw("/etapi/notes", query: q)
        if let resp = try? JSONDecoder().decode(SearchResponse.self, from: data), let r = resp.results {
            return r
        }
        return (try? JSONDecoder().decode([Note].self, from: data)) ?? []
    }

    /// 最近修改的笔记：参数化排序（orderBy=dateModified + orderDirection=desc + limit）
    func recentNotes(limit: Int = 30) async throws -> [Note] {
        var q = [URLQueryItem(name: "search", value: "")]
        q.append(URLQueryItem(name: "orderBy", value: "dateModified"))
        q.append(URLQueryItem(name: "orderDirection", value: "desc"))
        q.append(URLQueryItem(name: "limit", value: String(limit)))
        let data = try await raw("/etapi/notes", query: q)
        if let resp = try? JSONDecoder().decode(SearchResponse.self, from: data), let r = resp.results {
            return r
        }
        return (try? JSONDecoder().decode([Note].self, from: data)) ?? []
    }

    /// 子树下的直接子笔记（树的展开用；参数化，不走搜索语法）
    func childNotes(of parentId: String) async throws -> [Note] {
        var q = [URLQueryItem(name: "search", value: "")]
        q.append(URLQueryItem(name: "ancestorNoteId", value: parentId))
        q.append(URLQueryItem(name: "ancestorDepth", value: "eq1"))
        q.append(URLQueryItem(name: "orderBy", value: "title"))
        q.append(URLQueryItem(name: "orderDirection", value: "asc"))
        q.append(URLQueryItem(name: "limit", value: "500"))
        let data = try await raw("/etapi/notes", query: q)
        if let resp = try? JSONDecoder().decode(SearchResponse.self, from: data), let r = resp.results {
            return r
        }
        return (try? JSONDecoder().decode([Note].self, from: data)) ?? []
    }

    // MARK: - 收件箱

    /// 确保收件箱存在：root 下找标题匹配的，没有就创建
    func ensureInbox() async throws -> String {
        let s = AppSettings.shared
        if !s.inboxNoteId.isEmpty {
            if (try? await getNote(s.inboxNoteId)) != nil { return s.inboxNoteId }
        }
        let root = try await getNote("root")
        // 并发拉 root 子笔记（旧版串行逐个 getNote，N+1 慢）
        let children: [Note] = await withTaskGroup(of: Note?.self) { group -> [Note] in
            for id in root.childNoteIds ?? [] {
                group.addTask { try? await self.getNote(id) }
            }
            var out: [Note] = []
            for case let n? in group { out.append(n) }
            return out
        }
        if let hit = children.first(where: { $0.title == s.inboxTitle }) {
            s.inboxNoteId = hit.noteId
            return hit.noteId
        }
        let created = try await createNote(parentNoteId: "root", title: s.inboxTitle)
        s.inboxNoteId = created.note.noteId
        return created.note.noteId
    }
}

extension Notification.Name {
    /// 会话过期（服务端重启导致 token 失效），Root 视图据此踢回登录页
    static let sessionExpired = Notification.Name("trilium.sessionExpired")
    /// 请求退出登录：由 MainView 接收（sheet 持有者）显式关闭面板后再清 token
    static let performLogout = Notification.Name("trilium.performLogout")
}
