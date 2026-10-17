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
    }

    func loadContent(_ noteId: String) -> String? {
        try? String(contentsOf: contentURL(noteId), encoding: .utf8)
    }

    // MARK: - 二进制（图片/附件）

    private func blobURL(_ noteId: String) -> URL {
        blobDir.appendingPathComponent(noteId)
    }

    func saveBlob(_ noteId: String, data: Data) {
        try? data.write(to: blobURL(noteId))
    }

    func loadBlob(_ noteId: String) -> Data? {
        try? Data(contentsOf: blobURL(noteId))
    }

    // MARK: - 清理

    func clearAll() {
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: contentDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: blobDir, withIntermediateDirectories: true)
    }
}
