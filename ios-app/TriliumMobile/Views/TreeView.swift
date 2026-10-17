import SwiftUI

/// 笔记树：面包屑层级浏览（从 root 逐层展开），作为 sheet 弹出。
struct TreeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stack: [(id: String, title: String)] = [("root", "根目录")]
    @State private var children: [Note] = []
    @State private var loading = false
    @State private var errorMsg = ""

    var body: some View {
        NavigationView {
            Group {
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
        .navigationViewStyle(.stack)
    }

    /// 可展开的「容器」：有子笔记，或 search 类型。
    /// ⚠️ 旧判断 `type != "text"` 是错的：code/image/file 笔记会被当文件夹，
    /// 点进去拉不到子笔记显示空列表；而 text 笔记也可能是容器（Trilium 任意笔记可有子笔记）。
    private func isContainer(_ note: Note) -> Bool {
        if note.type == "search" { return true }
        return !(note.childNoteIds ?? []).isEmpty
    }

    /// 叶子笔记图标按类型区分
    private func icon(for note: Note) -> String {
        switch note.type {
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "image": return "photo"
        case "file": return "paperclip"
        default: return "doc.text"
        }
    }

    /// 容器可点击展开下一层；叶子笔记打开阅读页
    @ViewBuilder
    private func row(for note: Note) -> some View {
        if isContainer(note) {
            Button {
                stack.append((note.noteId, note.title))
                Task { await loadCurrent() }
            } label: {
                Label(note.title.isEmpty ? "（无标题）" : note.title, systemImage: "folder")
                    .foregroundColor(.primary)
            }
        } else {
            NavigationLink(destination: NoteDetailView(note: note)) {
                Label(note.title.isEmpty ? "（无标题）" : note.title, systemImage: icon(for: note))
            }
        }
    }

    private func loadCurrent() async {
        loading = true
        do {
            // 用参数化 childNotes 一次拉直接子笔记（旧版逐个 getNote 是 N+1，慢且可能漏）
            children = try await ETAPIClient.shared.childNotes(of: stack.last!.id)
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
