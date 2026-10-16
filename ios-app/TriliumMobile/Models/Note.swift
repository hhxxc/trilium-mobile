import Foundation

/// Trilium 笔记（对齐 ETAPI /etapi/notes/{id} 返回）
struct Note: Codable, Identifiable, Equatable {
    let noteId: String
    let title: String
    let type: String
    let mime: String?
    let isProtected: Bool?
    let childNoteIds: [String]?
    let parentBranchIds: [String]?
    let dateModified: String?
    let dateCreated: String?

    var id: String { noteId }

    /// 展示用的修改时间（原样字符串，避免时区换算出错）
    var modifiedDisplay: String {
        guard let raw = dateModified, !raw.isEmpty else { return "" }
        // ISO8601 形如 "2026-10-17T07:00:00.000Z"，截到分钟级显示
        let s = raw.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        if s.count >= 16 { return String(s.prefix(16)) }
        return s
    }
}

/// ETAPI 搜索响应（TriliumNext v0.106 起合并进 GET /etapi/notes?search=…）
struct SearchResponse: Codable {
    let results: [Note]?
}

/// ETAPI 创建笔记响应 { note, branch }
struct CreateNoteResponse: Codable {
    let note: Note
    let branch: Branch?
}

struct Branch: Codable {
    let branchId: String?
    let noteId: String?
    let parentNoteId: String?
}

/// ETAPI app-info 响应
struct AppInfo: Codable {
    let appVersion: String?
    let dbVersion: Int?
    let syncVersion: Int?
    let buildDate: String?
    let buildRevision: String?
}
