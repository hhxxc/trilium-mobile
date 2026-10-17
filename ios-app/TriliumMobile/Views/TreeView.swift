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

    /// 文件夹可点击展开下一层；text 笔记打开编辑器（用 sheet 里的导航）
    @ViewBuilder
    private func row(for note: Note) -> some View {
        let isFolder = note.type != "text"
        if isFolder {
            Button {
                stack.append((note.noteId, note.title))
                Task { await loadCurrent() }
            } label: {
                Label(note.title.isEmpty ? "（无标题）" : note.title, systemImage: "folder")
                    .foregroundColor(.primary)
            }
        } else {
            NavigationLink(destination: NoteDetailView(note: note)) {
                Label(note.title.isEmpty ? "（无标题）" : note.title, systemImage: "doc.text")
            }
        }
    }

    private func loadCurrent() async {
        loading = true
        do {
            let note = try await ETAPIClient.shared.getNote(stack.last!.id)
            var list: [Note] = []
            for childId in note.childNoteIds ?? [] {
                if let child = try? await ETAPIClient.shared.getNote(childId) {
                    list.append(child)
                }
            }
            children = list
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
