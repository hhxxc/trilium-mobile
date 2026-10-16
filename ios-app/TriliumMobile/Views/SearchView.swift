import SwiftUI

/// 全文搜索
struct SearchView: View {
    @State private var query = ""
    @State private var results: [Note] = []
    @State private var searching = false
    @State private var errorMsg = ""

    var body: some View {
        NavigationView {
            Group {
                if results.isEmpty && !searching {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40)).foregroundColor(.secondary)
                        Text("输入关键词搜索笔记").foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !errorMsg.isEmpty && results.isEmpty {
                    Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results) { note in
                        NavigationLink(destination: EditorView(note: note)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.title.isEmpty ? "（无标题）" : note.title)
                                if !note.modifiedDisplay.isEmpty {
                                    Text(note.modifiedDisplay).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "搜索笔记")
            .onSubmit(of: .search) { Task { await doSearch() } }
        }
        .navigationViewStyle(.stack)
    }

    private func doSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        do {
            results = try await ETAPIClient.shared.searchNotes(q)
            errorMsg = ""
        } catch {
            errorMsg = "搜索失败：\(error.localizedDescription)"
        }
        searching = false
    }
}
