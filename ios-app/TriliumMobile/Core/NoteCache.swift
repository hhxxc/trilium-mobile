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
        pruneIfNeeded()
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
        try? data.write(to: blobURL(noteId))
        pruneIfNeeded()
    }

    /// 超出容量上限时，把 content 和 blob 里最旧的文件删掉，直到回到阈值以下。
    /// 只在写入后调用；文件量小（几十条笔记 + 少量附件），枚举开销可忽略。
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
            do {
                try fm.removeItem(at: f.url)
                remaining -= f.size
                removed += f.size
            } catch {
                AppLogger.shared.log("缓存淘汰删除失败 \(f.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if removed > 0 {
            AppLogger.shared.log("缓存淘汰：清理 \(removed / 1024 / 1024)MB（总量 \(total / 1024 / 1024)MB > \(max / 1024 / 1024)MB）")
        }
    }

    func loadBlob(_ noteId: String) -> Data? {
        try? Data(contentsOf: blobURL(noteId))
    }

    // MARK: - 单笔记清理

    /// 删除笔记后清掉它的本地缓存（内容 + 二进制）
    func remove(_ noteId: String) {
        try? fm.removeItem(at: contentURL(noteId))
        try? fm.removeItem(at: blobURL(noteId))
        summaryCache.removeObject(forKey: noteId as NSString)
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
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
        summaryCache.removeAllObjects()
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
}

extension NoteCache {
    private static let pendingKey = "trilium.pendingOps"

    /// 队列变更通知（列表/设置页刷新待同步角标）
    static let pendingOpsChanged = Notification.Name("trilium.pendingOpsChanged")

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
        while !list.isEmpty {
            let op = list[0]
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
                list.removeFirst()
                pendingOps = list
                AppLogger.shared.log("离线补交成功: \(op.kind) \(op.noteId)，剩 \(list.count) 条")
            } catch {
                AppLogger.shared.log("离线补交失败（保留队列，下次重试）: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }
}
