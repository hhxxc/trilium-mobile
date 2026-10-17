import SwiftUI

/// 首页：笔记列表（有道云风格，列表优先）。
/// 大标题 + 搜索入口 + 笔记列表（标题/时间分组），右下角悬浮「+」速记。
struct NoteListView: View {
    @State private var notes: [Note] = []
    @State private var loading = false
    @State private var errorMsg = ""
    @State private var showCompose = false
    @State private var searchQuery = ""
    /// 加载代数：并发触发 load（防抖任务 + 下拉刷新）时丢弃过期响应，防旧结果覆盖新结果
    @State private var loadGeneration = 0

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            composeButton
        }
        .navigationTitle("笔记")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchQuery, prompt: "搜索笔记")
        // 防抖实时搜索：query 变化后停 400ms 才发请求，连续输入不轰服务端；
        // 旧任务会被自动取消（结构化并发），旧请求不会抢跑
        .task(id: searchQuery) {
            if !searchQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            guard !Task.isCancelled else { return }
            await load()
        }
        .refreshable { await load() }
        .sheet(isPresented: $showCompose) {
            ComposeView(onSaved: { await load() })
        }
    }

    @ViewBuilder
    private var content: some View {
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
        } else if notes.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 40)).foregroundColor(.secondary)
                Text("没有笔记").font(.footnote).foregroundColor(.secondary)
                Button("刷新试试") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !errorMsg.isEmpty {
                    Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                }
                if isSearching {
                    // 搜索结果平铺（分组反而碍事）
                    ForEach(notes) { note in
                        NavigationLink(destination: NoteDetailView(note: note)) {
                            NoteRow(note: note)
                        }
                    }
                } else {
                    // 浏览模式按时间分组（有道云风格）
                    ForEach(timeGroups.filter { !$0.notes.isEmpty }, id: \.title) { g in
                        Section(g.title) {
                            ForEach(g.notes) { note in
                                NavigationLink(destination: NoteDetailView(note: note)) {
                                    NoteRow(note: note)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// 按修改时间分组：今天 / 昨天 / 本周 / 更早（依赖服务端已按 dateModified desc 排序）
    private var timeGroups: [(title: String, notes: [Note])] {
        let cal = Calendar.current
        var today: [Note] = [], yesterday: [Note] = [], week: [Note] = [], earlier: [Note] = []
        for n in notes {
            guard let d = n.modifiedDate else { earlier.append(n); continue }
            if cal.isDateInToday(d) { today.append(n) }
            else if cal.isDateInYesterday(d) { yesterday.append(n) }
            else if cal.isDate(d, equalTo: Date(), toGranularity: .weekOfYear) { week.append(n) }
            else { earlier.append(n) }
        }
        return [("今天", today), ("昨天", yesterday), ("本周", week), ("更早", earlier)]
    }

    private var composeButton: some View {
        Button { showCompose = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color(red: 0.17, green: 0.61, blue: 0.56)))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private func load() async {
        loading = true
        loadGeneration += 1
        let gen = loadGeneration
        do {
            let q = searchQuery.trimmingCharacters(in: .whitespaces)
            let result: [Note]
            if q.isEmpty {
                result = try await ETAPIClient.shared.recentNotes()
                NoteCache.shared.saveRecentNotes(result) // 缓存，离线可看
            } else {
                result = try await ETAPIClient.shared.searchNotes(q)
            }
            // 已有更新的加载在进行中：丢弃本批结果（loading/notes 由最新调用收尾）
            guard gen == loadGeneration else { return }
            notes = result
            AppLogger.shared.log("列表加载完成：\(result.count) 条")
            errorMsg = ""
        } catch {
            guard gen == loadGeneration else { return }
            AppLogger.shared.log("列表加载失败: \(error.localizedDescription)")
            // 网络失败时回退缓存（离线可看）
            if let cached = NoteCache.shared.loadRecentNotes(), !cached.isEmpty {
                notes = cached
                errorMsg = "离线模式（显示缓存）"
            } else {
                errorMsg = "加载失败：\(error.localizedDescription)"
            }
        }
        loading = false
    }
}

/// 笔记列表行：类型图标 + 标题 + 修改时间
struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.icon(for: note.type))
                .foregroundColor(Self.iconColor(for: note.type))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title.isEmpty ? "（无标题）" : note.title)
                    .font(.body)
                    .lineLimit(2)
                if !note.friendlyModified.isEmpty {
                    Text(note.friendlyModified)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func icon(for type: String) -> String {
        switch type {
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "image": return "photo"
        case "file": return "paperclip"
        case "render": return "doc.richtext"
        case "mermaid": return "chart.bar.doc.horizontal"
        case "webView": return "globe"
        case "book": return "folder"
        case "search": return "magnifyingglass"
        case "noteMap", "relationMap": return "point.3.connected.trianglepath.dotted"
        case "canvas": return "scribble"
        default: return "doc.text"
        }
    }

    static func iconColor(for type: String) -> Color {
        switch type {
        case "code": return .orange
        case "image": return .purple
        case "file": return .blue
        case "book": return .yellow
        default: return Color(red: 0.17, green: 0.61, blue: 0.56)
        }
    }
}

/// 速记弹窗：输入一句话存到收件箱
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var errorMsg = ""
    var onSaved: () async -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("记点什么…（存入收件箱）", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                if !errorMsg.isEmpty {
                    Text(errorMsg).font(.footnote).foregroundColor(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("新建笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        busy = true
        Task {
            do {
                let inboxId = try await ETAPIClient.shared.ensureInbox()
                _ = try await ETAPIClient.shared.createNote(parentNoteId: inboxId, title: content)
                await onSaved()
                dismiss()
            } catch {
                errorMsg = "保存失败：\(error.localizedDescription)"
            }
            busy = false
        }
    }
}
