import SwiftUI

/// 首页：最近笔记卡片流 + 底部速记条（速记落「收件箱」）
struct RecentView: View {
    @State private var notes: [Note] = []
    @State private var loading = false
    @State private var errorMsg = ""
    @State private var quickText = ""

    var body: some View {
        NavigationView {
            Group {
                if loading && notes.isEmpty {
                    ProgressView("加载中…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !errorMsg.isEmpty && notes.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 40)).foregroundColor(.secondary)
                        Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                        Button("重试") { Task { await load() } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    noteList
                }
            }
            .navigationTitle("最近")
            .safeAreaInset(edge: .bottom) { quickBar }
            .task { await load() }
            .refreshable { await load() }
        }
        .navigationViewStyle(.stack)
    }

    private var noteList: some View {
        List {
            if !errorMsg.isEmpty {
                Text(errorMsg).font(.footnote).foregroundColor(.secondary)
            }
            ForEach(notes) { note in
                NavigationLink(destination: EditorView(note: note)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title.isEmpty ? "（无标题）" : note.title)
                            .font(.body)
                        if !note.modifiedDisplay.isEmpty {
                            Text(note.modifiedDisplay)
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private var quickBar: some View {
        HStack(spacing: 8) {
            TextField("记点什么…（存入收件箱）", text: $quickText)
                .textFieldStyle(.roundedBorder)
            Button("速记") { Task { await quickAdd() } }
                .buttonStyle(.borderedProminent)
                .disabled(quickText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func load() async {
        loading = true
        do {
            notes = try await ETAPIClient.shared.recentNotes()
            errorMsg = ""
        } catch {
            errorMsg = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func quickAdd() async {
        let text = quickText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        quickText = ""
        do {
            let inboxId = try await ETAPIClient.shared.ensureInbox()
            _ = try await ETAPIClient.shared.createNote(parentNoteId: inboxId, title: text)
            await load()
        } catch {
            errorMsg = "速记失败：\(error.localizedDescription)"
        }
    }
}
