import Foundation

/// 错误类型
enum APIError: LocalizedError {
    case invalidURL
    case http(status: Int)
    case invalidResponse
    /// 数据能拿到但解析不了（服务端换版本、隧道返回 HTML 错误页等）。
    /// ⚠️ 必须和「真的没有数据」区分开：旧代码解析失败直接返回空数组，
    ///   界面上表现为「列表空白」，看不出到底是没笔记还是解析炸了（历史踩坑）。
    case decodeFailed(context: String)
    case server(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "地址无效"
        case .http(let status): return "HTTP \(status)"
        case .invalidResponse: return "响应格式异常"
        case .decodeFailed(let context): return "数据解析失败（\(context)）"
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
        cfg.timeoutIntervalForRequest = 30   // 空闲超时（两次数据间隔）
        // ⚠️ 资源总时长上限：60s 实测不够——大附件走 ddnsto 慢隧道必然超时
        //   （日志铁证 "The request timed out"）。给 10 分钟，小请求几秒完成不受影响。
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    private var baseURL: URL { AppSettings.shared.serverURL }
    private var token: String { AppSettings.shared.token }

    // MARK: - 诊断辅助
    //
    // 目的：任何「打开是空的」「点了没反应」都能在设置页的诊断日志里看到一句原因，
    // 而不是只有上层一句干巴巴的 localizedDescription。
    // 约束：只记结构线索（字节数 / JSON 顶层键 / 报错原文前 160 字），不记笔记正文，避免刷屏。

    /// 把响应体压成一行短摘要（用于日志，不进 UI 正文）
    private func snippet(_ data: Data, limit: Int = 160) -> String {
        guard !data.isEmpty else { return "<空响应>" }
        guard let text = String(data: data, encoding: .utf8) else {
            return "<\(data.count) 字节，非 UTF-8>"
        }
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }

    /// JSON 顶层形状，例如 `object{results:[…]}`
    private func shape(of data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return "非 JSON：\(snippet(data))"
        }
        if let dict = obj as? [String: Any] {
            let keys = dict.keys.sorted().prefix(8).joined(separator: ",")
            return "object{\(keys)}"
        }
        if let arr = obj as? [Any] {
            return "array(\(arr.count))"
        }
        return "标量"
    }

    /// 解码笔记列表：兼容 `{results:[…]}` 与裸数组两种返回；
    /// 两种都不认时记日志 + 抛错（不再静默返回空数组）。
    private func decodeNotes(_ data: Data, context: String) throws -> [Note] {
        let decoder = JSONDecoder()
        if let resp = try? decoder.decode(SearchResponse.self, from: data), let r = resp.results {
            AppLogger.shared.log("\(context)：{results} 包裹格式，\(r.count) 条")
            return r
        }
        if let arr = try? decoder.decode([Note].self, from: data) {
            AppLogger.shared.log("\(context)：裸数组格式，\(arr.count) 条")
            return arr
        }
        AppLogger.shared.log("❌ \(context)：解析失败 bytes=\(data.count) 形状=\(shape(of: data))")
        throw APIError.decodeFailed(context: context)
    }

    // MARK: - 底层请求

    /// 发请求，返回 data；401（非登录接口）时广播会话过期
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
                AppLogger.shared.log("⚠️ \(method) \(path) → 401（token 失效，广播会话过期）")
                NotificationCenter.default.post(name: .sessionExpired, object: nil)
                throw APIError.http(status: 401)
            }
            guard (200..<300).contains(http.statusCode) else {
                // 记 path + 状态码 + 响应摘要：401/403/429/502 各自原因差别很大，
                // 只抛「HTTP 502」等于没信息（ddnsto 隧道 502 是历史常客）
                AppLogger.shared.log("⚠️ \(method) \(path) → HTTP \(http.statusCode)：\(snippet(data))")
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
        guard let text = String(data: data, encoding: .utf8) else {
            // ⚠️ 不能静默返回 ""：编辑页会把它当正文加载，一保存就把服务端内容清空
            AppLogger.shared.log("❌ 正文解码失败[\(id)]：\(data.count) 字节非 UTF-8")
            throw APIError.decodeFailed(context: "正文[\(id)]")
        }
        return text
    }

    /// 二进制内容（image/file 笔记的 content 是二进制）
    func getContentData(_ id: String) async throws -> Data {
        try await raw("/etapi/notes/\(id)/content")
    }

    /// 二进制内容 + 下载进度回调（附件预览用；逐块读取，每 64KB 上报一次）
    func getContentData(_ id: String, onProgress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Data {
        guard var comp = URLComponents(url: baseURL.appendingPathComponent("/etapi/notes/\(id)/content"),
                                       resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        comp.query = nil
        guard let url = comp.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "Authorization")

        let (bytes, resp) = try await session.bytes(for: req)
        let total = (resp as? HTTPURLResponse).flatMap {
            $0.expectedContentLength > 0 ? $0.expectedContentLength : nil
        }

        var data = Data()
        data.reserveCapacity(total.map(Int.init) ?? 64 * 1024)
        var sinceReport: Int64 = 0
        for try await byte in bytes {
            data.append(byte)
            sinceReport += 1
            if sinceReport >= 64 * 1024 {
                onProgress(Int64(data.count), total)
                sinceReport = 0
            }
        }
        onProgress(Int64(data.count), total)
        return data
    }

    /// 附件下载（笔记的 attachment，如 file 笔记的附件内容）
    func getAttachmentContent(_ attachmentId: String) async throws -> Data {
        try await raw("/etapi/attachments/\(attachmentId)/content")
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

    /// 删除笔记（Trilium 语义：标记 deleted，子笔记级联）
    func deleteNote(_ id: String) async throws {
        _ = try await raw("/etapi/notes/\(id)", method: "DELETE")
    }

    // MARK: - 整理：收藏 / 克隆 / 移动
    //
    // 能力来源（读容器内 v0.106 实际路由代码确认，不是猜的）：
    //   POST /etapi/attributes(/:id)   → 收藏 = 打一个 label
    //   POST /etapi/branches           → 分支（父子挂载）= 克隆
    //   DELETE /etapi/branches/:id     → 摘掉某条挂载 = 移动的一半
    //   PATCH /etapi/branches/:id      → 只接受 notePosition/prefix/isExpanded，
    //                                    **改不了 parentNoteId** → 移动必须「先挂后摘」两步

    /// 新建属性（收藏 = 给笔记打一个 bookmarked 标签）
    @discardableResult
    func createAttribute(noteId: String, name: String, value: String = "",
                         type: String = "label") async throws -> Attribute {
        let dict: [String: Any] = ["noteId": noteId, "type": type, "name": name,
                                   "value": value, "isInheritable": false, "position": 0]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await raw("/etapi/attributes", method: "POST", body: body)
        return try JSONDecoder().decode(Attribute.self, from: data)
    }

    func deleteAttribute(_ attributeId: String) async throws {
        _ = try await raw("/etapi/attributes/\(attributeId)", method: "DELETE")
    }

    /// 在目标父目录下挂一条分支（= 克隆到另一处；同父级重复调用只是重置位置）
    @discardableResult
    func addBranch(noteId: String, parentNoteId: String, position: Int = 0) async throws -> Branch {
        let dict: [String: Any] = ["noteId": noteId, "parentNoteId": parentNoteId,
                                   "notePosition": position, "isExpanded": false]
        let body = try JSONSerialization.data(withJSONObject: dict)
        let data = try await raw("/etapi/branches", method: "POST", body: body)
        return try JSONDecoder().decode(Branch.self, from: data)
    }

    func deleteBranch(_ branchId: String) async throws {
        _ = try await raw("/etapi/branches/\(branchId)", method: "DELETE")
    }

    func getBranch(_ branchId: String) async throws -> Branch {
        try await getJSON("/etapi/branches/\(branchId)")
    }

    /// 移动笔记：先在目标父级挂分支，再摘掉原父级的分支。
    /// ⚠️ 顺序不能反——先摘会让笔记短暂成为孤儿（万一第二步失败就找不回来了）。
    func moveNote(_ noteId: String, from parentNoteId: String, to targetParentId: String) async throws {
        guard parentNoteId != targetParentId else { return }
        let note = try await getNote(noteId)
        let branchIds = note.parentBranchIds ?? []
        // 用 branch 详情核对父级：parentNoteIds / parentBranchIds 的顺序不保证一一对应
        var oldBranchId: String?
        for bid in branchIds {
            do {
                let b = try await getBranch(bid)
                if b.parentNoteId == parentNoteId {
                    oldBranchId = bid
                    break
                }
            } catch {
                // 单个分支查不到不该直接中断移动，但要知道是哪一个
                AppLogger.shared.log("移动：分支 \(bid) 详情查询失败（\(error.localizedDescription)）")
            }
        }
        if oldBranchId == nil, branchIds.count == 1 {
            oldBranchId = branchIds[0] // 单父级兜底
            AppLogger.shared.log("移动：未匹配到父级分支，按单父级兜底用 \(branchIds[0])")
        }
        try await addBranch(noteId: noteId, parentNoteId: targetParentId)
        if let old = oldBranchId { try await deleteBranch(old) }
    }

    /// 收藏列表。主路径是 Trilium 的标签搜索语法 `#label`；
    /// 万一该语法在当前版本不生效，退回「最近 200 条里按 attributes 过滤」——
    /// 两条都失败也不至于把收藏页做成永久空白。
    func bookmarkedNotes(limit: Int = 50) async throws -> [Note] {
        do {
            let r = try await searchNotes("#bookmarked", limit: limit)
            if !r.isEmpty { return r }
            AppLogger.shared.log("收藏：标签搜索返回 0 条 → 走「最近 200 条按 attributes 过滤」兜底")
        } catch {
            // 标签语法在个别版本不生效时会 400/解析失败，兜底继续，但必须留痕
            AppLogger.shared.log("收藏：标签搜索失败（\(error.localizedDescription)）→ 走兜底")
        }
        let recent = try await recentNotes(limit: 200)
        let hits = recent.filter { $0.isBookmarked }
        AppLogger.shared.log("收藏：兜底命中 \(hits.count)/\(recent.count) 条")
        return hits
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
        return try decodeNotes(data, context: "搜索「\(query)」")
    }

    /// 「匹配所有笔记」的搜索表达式。
    /// ⚠️ 服务端校验 search 必须 trim 后非空（空串 400，服务端日志铁证：
    ///   "'search' query parameter is mandatory"）。
    /// 用官方属性比较语法 note.noteId != '…' 恒真，即匹配全部笔记。
    private static let matchAll = "note.noteId != 'zzz_no_match_zzz'"

    /// 最近修改的笔记：属性表达式匹配全部 + 参数化排序
    func recentNotes(limit: Int = 30) async throws -> [Note] {
        var q = [URLQueryItem(name: "search", value: Self.matchAll)]
        q.append(URLQueryItem(name: "orderBy", value: "dateModified"))
        q.append(URLQueryItem(name: "orderDirection", value: "desc"))
        q.append(URLQueryItem(name: "limit", value: String(limit)))
        let data = try await raw("/etapi/notes", query: q)
        return try decodeNotes(data, context: "最近列表(\(limit))")
    }

    /// 子树下的直接子笔记（树的展开用）。
    /// ⚠️ 不要用 GET /etapi/notes?search + ancestorNoteId/ancestorDepth 做这事：
    ///   实测 ancestorDepth=eq1 不生效（返回全部后代而非直接子级），再并发补全详情
    ///   会打成几百个并发请求把隧道打挂（v1.2.3 卡「加载目录…」的根因）。
    /// 正确做法：getNote(parent).childNoteIds（单笔记接口 childNoteIds 是填充的），
    /// 然后并发（限流）getNote 每个子笔记补全详情。树层浅、每层节点少，开销可控。
    func childNotes(of parentId: String) async throws -> [Note] {
        let parent = try await getNote(parentId)
        let ids = parent.childNoteIds ?? []
        AppLogger.shared.log("childNotes[\(parentId)]: childNoteIds=\(ids.count)")
        if ids.isEmpty {
            // 回退：childNoteIds 未填充时，用全量搜索 + notePath 推导层级
            return try await childrenViaNotePath(of: parentId)
        }

        // 分批并发（每批 6 个），防止大目录瞬间打爆隧道
        var out: [(Int, Note, Bool)] = []
        let batchSize = 6
        for start in stride(from: 0, to: ids.count, by: batchSize) {
            let batch = Array(ids.enumerated())[start..<min(start + batchSize, ids.count)]
            let results = await withTaskGroup(of: (Int, Note, Bool).self) { group in
                for (i, id) in batch {
                    group.addTask {
                        do {
                            let full = try await self.getNote(id)
                            return (i, full, true)
                        } catch {
                            AppLogger.shared.log("目录：子笔记 \(id) 详情失败（\(error.localizedDescription)）")
                            return (i, Note(noteId: id, title: "（加载失败）", type: "text",
                                             mime: nil, isProtected: nil, isArchived: nil, blobId: nil,
                                             childNoteIds: [], parentNoteIds: nil, parentBranchIds: nil,
                                             childBranchIds: nil, attributes: nil, dateCreated: nil,
                                             dateModified: nil, utcDateCreated: nil, utcDateModified: nil), false)
                        }
                    }
                }
                var r: [(Int, Note, Bool)] = []
                for await item in group { r.append(item) }
                return r
            }
            out.append(contentsOf: results)
        }
        let failed = out.filter { !$0.2 }.count
        if failed > 0 {
            AppLogger.shared.log("目录[\(parentId)]：\(failed)/\(out.count) 个子笔记详情加载失败（占位显示）")
        }
        return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    // MARK: - 树形层级的回退方案（notePath）

    /// noteId → notePath（形如 "root/abc/def"）。全量拉一次后缓存 60s。
    private static var pathCache: [String: String] = [:]
    private static var pathCacheTime: Date = .distantPast

    /// childNoteIds 不可用时的回退：全量搜索一次，用 notePath 推导父子关系。
    /// notePath 是 Trilium 搜索响应的常见附加字段（形如 root/xxx/yyy），
    /// 父路径 = 去掉最后一段，据此建立 parent→children 映射。
    private func childrenViaNotePath(of parentId: String) async throws -> [Note] {
        let now = Date()
        // 缓存有效则直接算
        if now.timeIntervalSince(Self.pathCacheTime) < 60, !Self.pathCache.isEmpty {
            return Self.childrenFromPathCache(of: parentId)
        }

        // 全量拉（一次请求，limit 放宽）
        var q = [URLQueryItem(name: "search", value: Self.matchAll)]
        q.append(URLQueryItem(name: "limit", value: "2000"))
        q.append(URLQueryItem(name: "orderBy", value: "title"))
        q.append(URLQueryItem(name: "orderDirection", value: "asc"))
        let data = try await raw("/etapi/notes", query: q)

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["results"] as? [[String: Any]] else {
            AppLogger.shared.log("notePath 回退：响应结构无法解析")
            throw APIError.invalidResponse
        }
        // 诊断：记录一条 note 的字段名（确认服务端到底给了什么）
        if let first = arr.first {
            AppLogger.shared.log("note 字段: \(first.keys.sorted().joined(separator: ","))")
        }
        // 建立 noteId → notePath
        var map: [String: String] = [:]
        for item in arr {
            guard let nid = item["noteId"] as? String, let path = item["notePath"] as? String else { continue }
            map[nid] = path
        }
        guard !map.isEmpty else {
            AppLogger.shared.log("notePath 回退：响应不含 notePath 字段")
            throw APIError.invalidResponse
        }
        Self.pathCache = map
        Self.pathCacheTime = now

        // 解码成 Note（复用同一份 data，避免二次请求）
        let notes = try decodeNotes(data, context: "notePath 回退")
        // 存下来供 childrenFromPathCache 用
        Self.noteCacheFromPathFallback = notes
        return Self.childrenFromPathCache(of: parentId)
    }

    private static var noteCacheFromPathFallback: [Note] = []

    /// 从 notePath 缓存算直接子级：父路径 == 目标 noteId 所在路径
    private static func childrenFromPathCache(of parentId: String) -> [Note] {
        let parentPath = pathCache[parentId] ?? "root"
        let byId = Dictionary(uniqueKeysWithValues: noteCacheFromPathFallback.map { ($0.noteId, $0) })
        // 收集直接子级：path 以 "<parentPath>/" 开头且剩余部分不含 "/"
        var out: [Note] = []
        for (nid, path) in pathCache {
            let prefix = parentPath + "/"
            guard path.hasPrefix(prefix) else { continue }
            let rest = String(path.dropFirst(prefix.count))
            if rest.isEmpty || rest.contains("/") { continue } // 孙子或自身
            if let n = byId[nid] { out.append(n) }
        }
        return out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - 收件箱

    /// 确保收件箱存在：root 下找标题匹配的，没有就创建
    func ensureInbox() async throws -> String {
        let s = AppSettings.shared
        if !s.inboxNoteId.isEmpty {
            do {
                _ = try await getNote(s.inboxNoteId)
                return s.inboxNoteId
            } catch {
                // 记下的收件箱 id 失效（被删/换库）→ 清掉重新找，别一直 404
                AppLogger.shared.log("收件箱：缓存 id \(s.inboxNoteId) 不可用（\(error.localizedDescription)），重新查找")
                s.inboxNoteId = ""
            }
        }
        // 用参数化 childNotes 一次拉 root 直接子笔记，找标题匹配的收件箱
        let children = try await childNotes(of: "root")
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
