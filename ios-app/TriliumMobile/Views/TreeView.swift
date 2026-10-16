import SwiftUI

/// 笔记树：面包屑层级浏览（从 root 逐层展开）
struct TreeView: View {
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
                            NavigationLink(destination: EditorView(note: note)) {
                                Label(note.title.isEmpty ? "（无标题）" : note.title,
                                      systemImage: note.type == "text" ? "doc.text" : "folder")
                            }
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
            }
            .task { await loadCurrent() }
        }
        .navigationViewStyle(.stack)
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
