import SwiftUI

/// 笔记树：面包屑层级浏览（从 root 逐层展开）。
/// sheet 弹出（右上角入口）与内嵌（首页「目录」模式）共用本视图。
struct TreeView: View {
    /// true = 嵌在主界面里（无 NavigationView/完成按钮，用顶部面包屑导航）
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var stack: [(id: String, title: String)] = [("root", "根目录")]
    @State private var children: [Note] = []
    @State private var loading = false
    @State private var errorMsg = ""
    /// 层级缓存：parentId → 子笔记列表。返回上级/重复进入秒开，不再重新拉网络。
    /// sheet 关闭后 @State 重建自然清空，不会占内存。
    @State private var layerCache: [String: [Note]] = [:]

    var body: some View {
        if embedded {
            embeddedBody
        } else {
            NavigationView { sheetBody }
                .navigationViewStyle(.stack)
        }
    }

    /// 内嵌模式：顶部面包屑（点击任意层级跳回）+ 列表
    private var embeddedBody: some View {
        VStack(spacing: 0) {
            breadcrumb
            treeContent
        }
        .task { await loadCurrent() }
    }

    /// 面包屑条：根目录 / A / B
    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // ⚠️ id 用 \.offset：stack 是 tuple 数组，keypath 不支持 tuple 元素（编译炸）
                ForEach(Array(stack.enumerated()), id: \.offset) { i, item in
                    if i > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Button {
                        if i < stack.count - 1 {
                            stack.removeLast(stack.count - 1 - i)
                            Task { await loadCurrent() }
                        }
                    } label: {
                        Text(item.title.isEmpty ? "（无标题）" : item.title)
                            .font(.footnote.weight(i == stack.count - 1 ? .semibold : .regular))
                            .foregroundColor(i == stack.count - 1 ? .primary : Color(red: 0.17, green: 0.61, blue: 0.56))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }

    private var sheetBody: some View {
        Group {
            treeContent
        }
        .navigationTitle(stack.last?.title ?? "笔记")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if stack.count > 1 {
                    Button("返回") { goUp() }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task { await loadCurrent() }
    }

    @ViewBuilder
    private var treeContent: some View {
        if loading && children.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !errorMsg.isEmpty && children.isEmpty {
            VStack(spacing: 12) {
                Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                Button("重试") { Task { await loadCurrent() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(children) { note in
                    row(for: note)
                }
            }
            .listStyle(.plain)
        }
    }

    /// 可展开的「容器」：复用 Note.isContainer 的类型判断，另加「有子笔记」
    ///（text 也可以是容器——Trilium 任意笔记可有子笔记）。
    /// ⚠️ 旧判断 `type != "text"` 是错的：code/image/file 笔记会被当文件夹，点进去全是空列表。
    private func isContainer(_ note: Note) -> Bool {
        note.isContainer || !(note.childNoteIds ?? []).isEmpty
    }

    /// 容器可点击展开下一层；叶子笔记打开阅读页（图标/颜色与首页列表行统一）
    @ViewBuilder
    private func row(for note: Note) -> some View {
        if isContainer(note) {
            Button {
                stack.append((note.noteId, note.title))
                Task { await loadCurrent() }
            } label: {
                Label(note.title.isEmpty ? "（无标题）" : note.title, systemImage: NoteRow.icon(for: note.type))
                    .foregroundColor(.primary)
            }
        } else {
            NavigationLink(destination: NoteDetailView(note: note)) {
                Label(note.title.isEmpty ? "（无标题）" : note.title, systemImage: NoteRow.icon(for: note.type))
                    .foregroundColor(NoteRow.iconColor(for: note.type))
            }
        }
    }

    private func loadCurrent() async {
        let parentId = stack.last!.id
        // 命中缓存直接渲染，零等待
        if let cached = layerCache[parentId], !cached.isEmpty {
            children = cached
            errorMsg = ""
            return
        }
        loading = true
        do {
            // 用参数化 childNotes 一次拉直接子笔记（旧版逐个 getNote 是 N+1，慢且可能漏）
            let fetched = try await ETAPIClient.shared.childNotes(of: parentId)
            children = fetched
            layerCache[parentId] = fetched
            errorMsg = ""
        } catch {
            errorMsg = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func goUp() {
        if stack.count > 1 {
            stack.removeLast()
            Task { await loadCurrent() }
        }
    }
}
