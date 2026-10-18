import Foundation

/// Trilium 笔记（对齐 ETAPI /etapi/notes/{id} 返回）
struct Note: Codable, Identifiable, Equatable {
    let noteId: String
    let title: String
    let type: String
    let mime: String?
    let isProtected: Bool?
    let isArchived: Bool?
    let blobId: String?
    let childNoteIds: [String]?
    let parentNoteIds: [String]?
    let parentBranchIds: [String]?
    let childBranchIds: [String]?
    let attributes: [Attribute]?
    let dateCreated: String?
    let dateModified: String?
    let utcDateCreated: String?
    let utcDateModified: String?

    var id: String { noteId }

    /// 是否文件夹（text/code/render/image/file 等是内容笔记；book 等是容器）
    var isContainer: Bool {
        type == "book" || type == "noteMap" || type == "search" || type == "relationMap"
    }

    /// Trilium 的**系统内部笔记**，用户不该在 App 里看到。
    /// 两类：
    ///   1. id 以 `_` 开头 —— 根下那个「隐藏的笔记」(`_hidden`)、`_share`、`_options`、
    ///      搜索历史、SQL 控制台、AI 对话…全是引擎自己的数据，不是用户内容；
    ///   2. 带 `#hideInNoteTree` 标签 —— Trilium 官方的「树里不显示」约定。
    var isSystemNote: Bool {
        if noteId.hasPrefix("_") { return true }
        if let attrs = attributes,
           attrs.contains(where: { $0.type == "label" && $0.name == "hideInNoteTree" }) {
            return true
        }
        return false
    }

    /// 展示用的修改时间（原样字符串，避免时区换算出错）
    var modifiedDisplay: String {
        guard let raw = dateModified, !raw.isEmpty else { return "" }
        let s = raw.replacingOccurrences(of: "T", with: " ").replacingOccurrences(of: "Z", with: "")
        if s.count >= 16 { return String(s.prefix(16)) }
        return s
    }

    // 缓存 formatter / 解析器（创建开销大，不能每次求值新建）
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// dateModified 解析成本地 Date（分组/相对时间共用；解析失败返回 nil）
    var modifiedDate: Date? {
        guard let raw = dateModified, !raw.isEmpty else { return nil }
        return Self.isoParser.date(from: raw) ?? Self.isoParserNoFrac.date(from: raw)
    }

    /// 列表展示的友好时间：今天 HH:mm，昨天「昨天」，更早日期（本地时区，修正 UTC+8 差 8 小时）
    var friendlyModified: String {
        guard let d = modifiedDate else { return modifiedDisplay }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return Self.timeFormatter.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天" }
        return Self.dateFormatter.string(from: d)
    }
}

/// 笔记属性（label/relation）
struct Attribute: Codable, Equatable {
    let attributeId: String?
    let noteId: String?
    let type: String?
    let name: String?
    let value: String?
    let isInheritable: Bool?
}

extension Note {
    /// 收藏标记的 attributeId（收藏 = 一条 name 为 bookmarked 的 label）
    var bookmarkAttributeId: String? {
        attributes?.first { $0.type == "label" && $0.name == "bookmarked" }?.attributeId
    }

    var isBookmarked: Bool { bookmarkAttributeId != nil }
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
