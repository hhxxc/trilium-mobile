import Foundation

/// 本地缓存：看过的笔记内容 + 元数据存本地，断网可看。
/// 内容（HTML/文本）与二进制（图片/附件）分开存储；元数据 JSON 序列化。
final class NoteCache {
    static let shared = NoteCache()

    private let fm = FileManager.default
    private var root: URL {
        let c = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return c.appendingPathComponent("TriliumCache", isDirectory: true)
    }
    private var contentDir: URL {
        root.appendingPathComponent("content", isDirectory: true)
    }
    private var blobDir: URL {
        root.appendingPathComponent("blob", isDirectory: true)
    }

    private init() {
        try? fm.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
    }

    /// 缓存总容量上限。一条 25MB 的 PDF 附件不淘汰会无限堆满 Caches，
    /// 超出后按最后修改时间从最旧的文件开始删。
    private static let maxCacheBytes: Int64 = 200 * 1024 * 1024

    /// 磁盘 IO 专用串行队列：大附件写盘、容量淘汰都在这里做，别占主线程。
    /// ⚠️ 淘汰会删文件，必须和写盘串行，否则可能删到刚写一半的文件。
    private let ioQueue = DispatchQueue(label: "trilium.note-cache.io", qos: .utility)

    /// 上次容量巡检时间 + 锁（写盘很频繁，不能每次都全目录枚举）
    private var lastPruneAt = Date.distantPast
    private let pruneLock = NSLock()

    /// 二进制内存缓存：刚存过的附件（尤其图片）再从磁盘读一遍纯属浪费；
    /// 也覆盖了「写盘改异步后，立刻 loadBlob 读不到」的窗口。
    private let blobCache: NSCache<NSString, NSData> = {
        let c = NSCache<NSString, NSData>()
        c.totalCostLimit = 64 * 1024 * 1024
        return c
    }()

    // MARK: - 元数据

    private var metaURL: URL { root.appendingPathComponent("notes.json") }

    /// 缓存最近笔记元数据（列表用）
    func saveRecentNotes(_ notes: [Note]) {
        if let data = try? JSONEncoder().encode(notes) {
            try? data.write(to: metaURL)
        }
    }

    func loadRecentNotes() -> [Note]? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode([Note].self, from: data)
    }

    // MARK: - 文本内容

    private func contentURL(_ noteId: String) -> URL {
        contentDir.appendingPathComponent("\(noteId).txt")
    }

    func saveContent(_ noteId: String, text: String) {
        try? text.write(to: contentURL(noteId), atomically: true, encoding: .utf8)
        // 内容变了，列表摘要缓存要失效（否则编辑器改完回列表还是旧摘要）
        summaryCache.removeObject(forKey: noteId as NSString)
        schedulePrune()
    }

    func loadContent(_ noteId: String) -> String? {
        try? String(contentsOf: contentURL(noteId), encoding: .utf8)
    }

    // MARK: - 列表摘要缓存（内存）

    /// 列表每行的正文摘要。以前每行 onAppear 都同步读一次磁盘，
    /// 几百条笔记滚动时就是几百次主线程 IO —— 换成 NSCache 后滚动只算一次。
    private let summaryCache = NSCache<NSString, NSString>()

    func cachedSummary(_ noteId: String) -> String? {
        summaryCache.object(forKey: noteId as NSString) as String?
    }

    func storeSummary(_ noteId: String, _ text: String) {
        summaryCache.setObject(text as NSString, forKey: noteId as NSString)
    }

    // MARK: - 二进制（图片/附件）

    private func blobURL(_ noteId: String) -> URL {
        blobDir.appendingPathComponent(noteId)
    }

    func saveBlob(_ noteId: String, data: Data) {
        // 先放内存：调用方紧接着可能 loadBlob（图片笔记首屏），不落一次磁盘
        blobCache.setObject(data as NSData, forKey: noteId as NSString, cost: data.count)
        // 大附件写盘（几十 MB）别占主线程 —— 以前同步写，下载完那一下会明显卡顿
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? data.write(to: self.blobURL(noteId))
            self.pruneIfNeeded()
        }
    }

    /// 容量巡检节流：最多 60s 一次，且整体挪到 IO 队列。
    /// ⚠️ 旧版每次写盘都同步枚举整个缓存目录，笔记一多就是主线程上的几十毫秒 IO。
    private func schedulePrune() {
        pruneLock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastPruneAt) > 60 else {
            pruneLock.unlock()
            return
        }
        lastPruneAt = now
        pruneLock.unlock()
        ioQueue.async { [weak self] in self?.pruneIfNeeded() }
    }

    /// 超出容量上限时，把 content 和 blob 里最旧的文件删掉，直到回到阈值以下。
    /// 只在 IO 队列上调用（写盘后），枚举开销不占主线程。
    private func pruneIfNeeded() {
        let max = Self.maxCacheBytes
        guard max > 0 else { return }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for dir in [contentDir, blobDir] {
            guard let e = fm.enumerator(at: dir,
                                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            for case let url as URL in e {
                let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = Int64(vals?.fileSize ?? 0)
                let date = vals?.contentModificationDate ?? .distantPast
                total += size
                files.append((url, size, date))
            }
        }
        guard total > max else { return }
        files.sort { $0.date < $1.date } // 最旧在前
        var remaining = total
        var removed: Int64 = 0
        for f in files {
            guard remaining > max else { break }
            // 别把「当前正在用的元数据」删了：notes.json 是离线列表的命根子
            if f.url.lastPathComponent == "notes.json" { continue }
            do {
                try fm.removeItem(at: f.url)
                remaining -= f.size
                removed += f.size
                // 磁盘删了，内存里那份也要清（否则点开又「有缓存」，其实已经没了）
                blobCache.removeObject(forKey: f.url.lastPathComponent as NSString)
            } catch {
                AppLogger.shared.log("缓存淘汰删除失败 \(f.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            AppLogger.shared.log("缓存淘汰：清理 \(removed / 1024 / 1024)MB（总量 \(total / 1024 / 1024)MB > \(max / 1024 / 1024)MB）")
        }
    }

    func loadBlob(_ noteId: String) -> Data? {
        if let hit = blobCache.object(forKey: noteId as NSString) { return hit as Data }
        guard let data = try? Data(contentsOf: blobURL(noteId)) else { return nil }
        // 回填内存缓存（读过的附件不再反复读盘）
        blobCache.setObject(data as NSData, forKey: noteId as NSString, cost: data.count)
        return data
    }

    // MARK: - 单笔记清理

    /// 删除笔记后清掉它的本地缓存（内容 + 二进制）
    func remove(_ noteId: String) {
        blobCache.removeObject(forKey: noteId as NSString)
        summaryCache.removeObject(forKey: noteId as NSString)
        // 走 IO 队列：和 saveBlob 的异步写串行，避免「刚删完又被写回来」
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? self.fm.removeItem(at: self.contentURL(noteId))
            try? self.fm.removeItem(at: self.blobURL(noteId))
        }
    }

    /// 缓存目录总字节数（设置页展示用）
    func totalSize() -> Int64 {
        var size: Int64 = 0
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in e {
                size += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return size
    }

    // MARK: - 清理

    func clearAll() {
        // 与 IO 队列串行：等正在写的大附件落完再清，否则清完又被写回来
        ioQueue.sync {
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: contentDir, withIntermediateDirectories: true)
            try? fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        }
        summaryCache.removeAllObjects()
        blobCache.removeAllObjects()
        // 缓存清了，待同步操作必须保留（是真实数据不是缓存）
        if !pendingOps.isEmpty {
            UserDefaults.standard.set(try? JSONEncoder().encode(pendingOps), forKey: Self.pendingKey)
        }
    }
}

// MARK: - 离线写入队列

/// 待同步操作：断网时的写操作先入队，联网后按序补交（保序，失败即停不跳过）
struct PendingOp: Codable, Identifiable {
    /// putContent（改正文）/ patchTitle（改标题）/ create（新建）/ delete（删除）
    let kind: String
    let id: String
    let noteId: String
    var title: String?
    var content: String?
    var parentNoteId: String?
    let createdAt: Date
    /// 入队时本地已知的服务端版本戳（utcDateModified）——补交前拿它比对，
    /// 对不上说明别的端改过这篇笔记，不能直接覆盖（2026-10-20 加的冲突保护）
    var baseStamp: String?
    /// 已判定冲突、等用户裁决：补交时跳过它，不再无限重试
    var conflicted: Bool = false

    /// ⚠️ 显式 init（带默认值）：新增字段时旧调用点不用逐个改
    init(kind: String, id: String, noteId: String, title: String? = nil,
         content: String? = nil, parentNoteId: String? = nil, createdAt: Date = Date(),
         baseStamp: String? = nil, conflicted: Bool = false) {
        self.kind = kind
        self.id = id
        self.noteId = noteId
        self.title = title
        self.content = content
        self.parentNoteId = parentNoteId
        self.createdAt = createdAt
        self.baseStamp = baseStamp
        self.conflicted = conflicted
    }

    /// ⚠️ 老版本持久化的队列里没有 baseStamp/conflicted —— 解码必须容错。
    ///    合成版 init(from:) 对非 Optional 字段用 decode（缺键直接抛），
    ///    一旦抛错，pendingOps 会 `?? []` 静默清空 → 用户离线改的内容整队丢失。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        noteId = try c.decode(String.self, forKey: .noteId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        parentNoteId = try c.decodeIfPresent(String.self, forKey: .parentNoteId)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        baseStamp = try c.decodeIfPresent(String.self, forKey: .baseStamp)
        conflicted = try c.decodeIfPresent(Bool.self, forKey: .conflicted) ?? false
    }
}

extension NoteCache {
    private static let pendingKey = "trilium.pendingOps"

    /// 队列变更通知（列表/设置页刷新待同步角标）
    static let pendingOpsChanged = Notification.Name("trilium.pendingOpsChanged")
    /// 补交时发现冲突（需要用户裁决）——列表顶部的冲突提示据此刷新
    static let conflictDetected = Notification.Name("trilium.conflictDetected")

    var pendingOps: [PendingOp] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.pendingKey) else { return [] }
            return (try? JSONDecoder().decode([PendingOp].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.pendingKey)
            NotificationCenter.default.post(name: Self.pendingOpsChanged, object: nil)
        }
    }

    func enqueue(_ op: PendingOp) {
        var list = pendingOps
        list.append(op)
        pendingOps = list
        AppLogger.shared.log("离线入队: \(op.kind) \(op.noteId)（共 \(list.count) 条待同步）")
    }

    /// 按序补交队列：成功一项删一项；某项失败即停（后面的依赖前面的顺序，不能跳）。
    /// 返回是否全部清空。
    @discardableResult
    func flushPendingOps() async -> Bool {
        var list = pendingOps
        guard !list.isEmpty else { return true }
        var idx = 0
        var allSettled = true
        while idx < list.count {
            let op = list[idx]
            // 已判冲突：跳过，等用户在「冲突处理」里裁决（不再无限重试）
            if op.conflicted {
                allSettled = false
                idx += 1
                continue
            }
            // ⚠️ 补交前比对版本戳：离线期间别处（桌面端/网页）改过这篇 → 不能直接覆盖
            if let base = op.baseStamp, !base.isEmpty,
               (op.kind == "putContent" || op.kind == "patchTitle") {
                // ⚠️ 别写 `try? await getNote(...).versionStamp`：versionStamp 本身是 String?，
                //    try? 叠加一层可选后会变成 String??（Swift 的 try? 嵌套可选老坑），
                //    后面 isEmpty / != 直接编译不过。拆成两步最稳。
                let fresh: Note? = try? await ETAPIClient.shared.getNote(op.noteId)
                if let cur = fresh?.versionStamp, !cur.isEmpty, cur != base {
                    list[idx].conflicted = true
                    pendingOps = list
                    AppLogger.shared.log("补交发现冲突[\(op.kind)] \(op.noteId)：服务端 \(cur) ≠ 我的基准 \(base)，等待裁决")
                    NotificationCenter.default.post(name: Self.conflictDetected, object: nil)
                    allSettled = false
                    idx += 1
                    continue
                }
            }
            do {
                switch op.kind {
                case "putContent":
                    try await ETAPIClient.shared.putContent(op.noteId, content: op.content ?? "")
                case "patchTitle":
                    _ = try await ETAPIClient.shared.patchNote(op.noteId, fields: ["title": op.title ?? ""])
                case "create":
                    // ⚠️ 不能写 `op.parentNoteId ?? (try await ...)`：?? 右侧是 autoclosure，
                    // 不支持 async/throws（编译错误 operator can throw / async in autoclosure）
                    let parent: String
                    if let p = op.parentNoteId {
                        parent = p
                    } else {
                        parent = try await ETAPIClient.shared.ensureInbox()
                    }
                    _ = try await ETAPIClient.shared.createNote(
                        parentNoteId: parent,
                        title: op.title ?? "")
                case "delete":
                    try await ETAPIClient.shared.deleteNote(op.noteId)
                default:
                    break  // 未知类型（旧版本残留）：丢弃
                }
                list.remove(at: idx)
                pendingOps = list
                AppLogger.shared.log("离线补交成功: \(op.kind) \(op.noteId)，剩 \(list.count) 条")
            } catch {
                AppLogger.shared.log("离线补交失败（保留队列，下次重试）: \(error.localizedDescription)")
                return false   // 保序：前面的没成，后面的不能跳
            }
        }
        return allSettled
    }

    // MARK: - 冲突裁决（补交时发现别处改过同一篇，交给用户定）

    /// 等裁决的冲突项
    func conflictedOps() -> [PendingOp] { pendingOps.filter { $0.conflicted } }

    /// 保留我的：清掉冲突标记 + 作废基准（下次补交直接覆盖提交）
    func resolveKeepMine(_ opId: String) {
        var list = pendingOps
        guard let i = list.firstIndex(where: { $0.id == opId }) else { return }
        list[i].conflicted = false
        list[i].baseStamp = nil      // 已裁决，不再比对
        pendingOps = list
        AppLogger.shared.log("冲突裁决[保留我的]：\(list[i].kind) \(list[i].noteId)")
    }

    /// 丢弃我的：整条从队列移除（服务端版本为准）
    func resolveDropMine(_ opId: String) {
        var list = pendingOps
        guard let i = list.firstIndex(where: { $0.id == opId }) else { return }
        let op = list.remove(at: i)
        pendingOps = list
        AppLogger.shared.log("冲突裁决[丢弃我的]：\(op.kind) \(op.noteId)")
    }
}
