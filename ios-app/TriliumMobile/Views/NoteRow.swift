import SwiftUI
import UIKit

/// 笔记类型图标徽标：圆角方块底色 + 同色系符号。
/// 旧版是裸 SF Symbol，花花绿绿又不成块，视觉上像「贴纸」；加个浅色底后图标成组、辨识度也高。
struct NoteIconBadge: View {
    let type: String
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(NoteRow.iconColor(for: type).opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: NoteRow.icon(for: type))
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundColor(NoteRow.iconColor(for: type))
            )
    }
}

/// 笔记列表行：图标徽标 + 标题 + 正文摘要 + 修改时间 + 收藏星标
struct NoteRow: View {
    let note: Note
    /// 搜索/收藏里传 true：多显示一行「所在目录」，用来区分同名笔记
    var showsLocation: Bool = false

    @State private var summary: String = ""
    @State private var location: String = ""

    init(note: Note, showsLocation: Bool = false) {
        self.note = note
        self.showsLocation = showsLocation
        _location = State(initialValue: NotePathResolver.cachedParentTitle(for: note) ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NoteIconBadge(type: note.type, size: 30)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.title.isEmpty ? "（无标题）" : note.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if note.isBookmarked {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }

                if !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if showsLocation, !location.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text(location)
                            .font(.footnote)
                            .lineLimit(1)
                    }
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                }

                if !note.friendlyModified.isEmpty {
                    Text(note.friendlyModified)
                        .font(.footnote)
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        // 分隔线从标题文字左边起（图标 30 + 间距 12 = 42），比系统分隔线整齐
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
                .padding(.leading, 42)
        }
        .onAppear {
            Task {
                await loadSummaryIfNeeded()
                if showsLocation, location.isEmpty {
                    location = await NotePathResolver.parentTitle(for: note) ?? ""
                }
            }
        }
    }

    private func loadSummaryIfNeeded() async {
        guard summary.isEmpty else { return }
        // 图片/附件类给类型说明（正文是二进制，没有文字摘要）
        switch note.type {
        case "image":
            summary = "图片"
            return
        case "file":
            summary = "附件" + (note.mime.map { " · \($0)" } ?? "")
            return
        default: break
        }
        // 内存缓存命中（滚动回来不用再读盘）
        if let cached = NoteCache.shared.cachedSummary(note.noteId) {
            summary = cached
            return
        }
        // 磁盘读取放后台：原来是 onAppear 里同步读，长列表滚动会掉帧
        let noteId = note.noteId
        let text: String? = await Task.detached(priority: .utility) {
            guard let html = NoteCache.shared.loadContent(noteId), !html.isEmpty else { return nil }
            let plain = NoteRow.plainText(from: html)
            return plain.isEmpty ? nil : String(plain.prefix(70))
        }.value
        guard let text, !text.isEmpty else { return }
        NoteCache.shared.storeSummary(noteId, text)
        summary = text
    }

    /// HTML → 纯文本（去标签、解常见实体、压空白）
    /// nonisolated：这个方法要在后台线程（Task.detached）里跑，不能挂 MainActor
    nonisolated static func plainText(from html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&ldquo;", "「"), ("&rdquo;", "」")
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func icon(for type: String) -> String {
        switch type {
        case "code": return "curlybraces"
        case "image": return "photo.fill"
        case "file": return "paperclip"
        case "render": return "doc.richtext"
        case "mermaid": return "chart.bar.doc.horizontal"
        case "webView": return "globe"
        case "book": return "book.closed.fill"
        case "search": return "magnifyingglass"
        case "noteMap", "relationMap": return "circle.grid.cross"
        case "canvas": return "scribble"
        default: return "doc.text.fill"
        }
    }

    /// 类型徽章配色：深色档统一提亮，否则在黑底上会发灰、分不清类型
    static func iconColor(for type: String) -> Color {
        func c(_ lr: CGFloat, _ lg: CGFloat, _ lb: CGFloat,
               _ dr: CGFloat, _ dg: CGFloat, _ db: CGFloat) -> Color {
            Theme.adaptive(light: UIColor(red: lr, green: lg, blue: lb, alpha: 1),
                           dark: UIColor(red: dr, green: dg, blue: db, alpha: 1))
        }
        switch type {
        case "code": return c(0.90, 0.49, 0.13, 0.98, 0.60, 0.28)     // 橙
        case "image": return c(0.85, 0.35, 0.55, 0.97, 0.56, 0.72)    // 桃红
        case "file": return c(0.20, 0.48, 0.90, 0.42, 0.68, 0.99)     // 蓝
        case "book": return c(0.93, 0.63, 0.14, 1.00, 0.78, 0.33)     // 琥珀
        case "render": return c(0.53, 0.40, 0.85, 0.72, 0.60, 0.97)   // 紫
        case "mermaid": return c(0.33, 0.45, 0.85, 0.58, 0.68, 0.99)  // 靛
        default: return Theme.accent                                   // 主题青
        }
    }
}
