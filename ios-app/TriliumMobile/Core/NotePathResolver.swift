import Foundation

/// 解析笔记「所在目录」，用于列表/搜索里区分同名笔记。
///
/// 背景：用户有两条同名笔记（一条 text 一条 file），列表里只显示标题和摘要，
/// 根本分不出谁是谁。显示上一级目录名是最省事也最有效的区分方式。
///
/// 只取**上一级**：一次请求就够说明问题；缓存按**父目录 id** 建 ——
/// 同一目录下的多条结果只请求一次，滚动几十行也不会打爆隧道。
enum NotePathResolver {
    private static var titleCache: [String: String] = [:]

    /// 已有缓存就直接给（用于 body 里同步渲染，避免闪一下）
    static func cachedParentTitle(for note: Note) -> String? {
        guard let pid = note.parentNoteIds?.first else { return nil }
        return titleCache[pid]
    }

    /// 没有缓存就取一次（1 个请求，按父 id 复用）
    static func parentTitle(for note: Note) async -> String? {
        guard let pid = note.parentNoteIds?.first, pid != "root" else { return nil }
        if let t = titleCache[pid] { return t }
        guard let parent = try? await ETAPIClient.shared.getNote(pid) else { return nil }
        // 系统笔记不作位置展示（正常情况下早就被过滤掉了，这里再兜一层）
        guard !parent.title.hasPrefix("_"), !parent.title.isEmpty else { return nil }
        titleCache[pid] = parent.title
        return parent.title
    }
}
