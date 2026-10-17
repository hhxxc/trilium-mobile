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

    // 缓存 formatter / 解析器（创建开销大，不能每次求值新建）
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] // "…T07:00:00.000Z"
        return f
    }()
    private static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime] // 兜底：无毫秒变体 "…T07:00:00Z"
        return f
    }()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 列表展示的友好时间：今天显示 HH:mm，昨天显示「昨天」，更早显示日期。
    /// ⚠️ modifiedDisplay 是截取 UTC 原串直接显示，国内 UTC+8 会差 8 小时——列表一律用本方法。
    var friendlyModified: String {
        guard let raw = dateModified, !raw.isEmpty,
              let d = Self.isoParser.date(from: raw) ?? Self.isoParserNoFrac.date(from: raw) else {
            return modifiedDisplay // 解析失败退回原样串
        }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return Self.timeFormatter.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天" }
        return Self.dateFormatter.string(from: d)
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
