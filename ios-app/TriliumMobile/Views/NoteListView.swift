import SwiftUI
import UIKit

/// 首页：笔记列表（有道云风格，列表优先）。
/// 大标题 + 搜索入口 + 笔记列表（标题/时间分组），右下角悬浮「+」速记。
/// 顶部「最近 | 目录」切换：目录模式内嵌树状浏览（面包屑导航）。
struct NoteListView: View {
    @State private var notes: [Note] = []
    @State private var loading = false
    @State private var errorMsg = ""
    @State private var showCompose = false
    @State private var searchQuery = ""
    @State private var noteToDelete: Note?
    @State private var deleting = false
    /// 加载代数：并发触发 load（防抖任务 + 下拉刷新）时丢弃过期响应，防旧结果覆盖新结果
    @State private var loadGeneration = 0
    /// 首页模式：0=最近列表，1=树状目录
    @State private var browseMode = 0
    /// 搜索历史（最近 8 条，UserDefaults 持久化）；搜索无结果时给出可点词条
    @State private var searchHistory: [String] = []
    /// 离线待同步操作数（顶部提示条）
    @State private var pendingCount = 0
    /// 左滑抽屉：目录树覆盖层（学有道云/Obsidian——树和列表共存，不用二选一）
    @State private var drawerOpen = false

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                if isSearching || browseMode == 0 {
                    content
                } else {
                    TreeView(embedded: true)
                }
            }
            // 左边缘拖拽热区（仅 22pt 宽，不影响列表上下滚动）
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 22)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { v in
                                if v.translation.width > 50 {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        drawerOpen = true
                                    }
                                }
                            }
                    )
                Spacer(minLength: 0)
            }
            // 抽屉遮罩 + 目录树
            if drawerOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
                    }
                treeDrawer
                    .transition(.move(edge: .leading))
            }
        }
        .navigationTitle(isSearching ? "搜索" : (browseMode == 0 ? "最近" : "目录"))
        .navigationBarTitleDisplayMode(isSearching ? .inline : .large)
        // 目录模式没有搜索框；最近/搜索才有
        .searchable(text: $searchQuery, prompt: "搜索笔记")
        // ⚠️ 视图切换器与新建按钮都放**底部**（拇指可达区）：
        //   - 放 toolbar 里 iOS 15 不渲染（实测）
        //   - 放顶部横条够不到（思源被骂的第一条就是高频操作在左上角）
        //   底部 safeAreaInset 是 iOS 15 稳定支持，且单手拇指正好够到。
        // ⚠️ 抽屉打开时必须收起底部工具条：safeAreaInset 的条带渲染在 ZStack 内容**之上**，
        //   不收起的话抽屉（已经 ignoresSafeArea 铺满）会在底部被工具条压一条，
        //   而且胶囊/＋按钮还能隔着抽屉点到。收起后抽屉才是真正的全屏覆盖。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !drawerOpen {
                bottomBar
            }
        }
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
        .onAppear {
            searchHistory = UserDefaults.standard.stringArray(forKey: "trilium.searchHistory") ?? []
            pendingCount = NoteCache.shared.pendingOps.count
        }
        .onReceive(NotificationCenter.default.publisher(for: NoteCache.pendingOpsChanged)) { _ in
            pendingCount = NoteCache.shared.pendingOps.count
        }
        // 编辑器改了标题：就地刷新列表，返回时看到的不是旧标题
        .onReceive(NotificationCenter.default.publisher(for: .noteMetaChanged)) { _ in
            Task { await load() }
        }
        // 从抽屉树点开笔记：导航已经把阅读页 push 上来了，抽屉必须同步收起，
        // 否则树会一直盖在阅读页上（抽屉是 ZStack 覆盖层，不受导航栈影响）
        .onReceive(NotificationCenter.default.publisher(for: .noteDetailAppeared)) { _ in
            if drawerOpen {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView(onSaved: { await load() })
        }
        .confirmationDialog(
            "删除「\(noteToDelete?.title ?? "")」？子笔记将一并删除，不可恢复。",
            isPresented: Binding(get: { noteToDelete != nil },
                                 set: { if !$0 { noteToDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { Task { await deleteNote() } }
            Button("取消", role: .cancel) { noteToDelete = nil }
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
                Image(systemName: isSearching ? "magnifyingglass" : "tray")
                    .font(.system(size: 40)).foregroundColor(.secondary)
                Text(isSearching ? "未找到相关笔记" : "没有笔记")
                    .font(.footnote).foregroundColor(.secondary)
                // 搜索无结果：给历史词条，点击直接换词重搜（比干巴巴的提示有用）
                if isSearching && !searchHistory.isEmpty {
                    VStack(spacing: 8) {
                        Text("试试最近搜过的：").font(.caption).foregroundColor(.secondary)
                        ForEach(searchHistory.prefix(4), id: \.self) { term in
                            Button {
                                searchQuery = term
                            } label: {
                                Text(term)
                                    .font(.footnote)
                                    .foregroundColor(Color(red: 0.17, green: 0.61, blue: 0.56))
                            }
                        }
                    }
                    .padding(.top, 6)
                } else if !isSearching {
                    Button("刷新试试") { Task { await load() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // 离线积压提示条：点击手动补交
                if pendingCount > 0 {
                    Button {
                        Task { await NoteCache.shared.flushPendingOps() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.orange)
                            Text("\(pendingCount) 条待同步（点击立即上传）")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                    .listRowSeparator(.hidden)
                }
                if !errorMsg.isEmpty {
                    Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                        .listRowSeparator(.hidden)
                }
                if isSearching {
                    // 搜索结果平铺（分组反而碍事）
                    ForEach(notes) { note in
                        listRow(note)
                    }
                } else {
                    // 浏览模式按时间分组（有道云风格）
                    ForEach(timeGroups.filter { !$0.notes.isEmpty }, id: \.title) { g in
                        Section {
                            ForEach(g.notes) { note in
                                listRow(note)
                            }
                        } header: {
                            // 分组标题：小号加粗灰字，比 plain 样式默认的全大写大灰条更克制
                            Text(g.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// 列表行（搜索/分组两处共用）：进详情 + 长按删除
    private func listRow(_ note: Note) -> some View {
        NavigationLink(destination: NoteDetailView(note: note)) {
            NoteRow(note: note)
        }
        // 系统分隔线贴着行左边缘、从图标左侧开始，和标题文字不对齐，看着很散；
        // 隐藏它，改由 NoteRow 自己画一条**与标题文字左对齐**的细线（苹果备忘录 / 微信的做法）
        .listRowSeparator(.hidden)
        .contextMenu {
            Button(role: .destructive) {
                noteToDelete = note
            } label: {
                Label("删除笔记", systemImage: "trash")
            }
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

    /// 抽屉里的目录树（覆盖 86% 宽，顶部带标题和关闭）
    private var treeDrawer: some View {
        let w = UIScreen.main.bounds.width * 0.86
        return VStack(spacing: 0) {
            HStack {
                Text("目录")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            TreeView(embedded: true)
        }
        .frame(width: w)
        .frame(maxHeight: .infinity)
        // 背景铺满全屏（含底部安全区），但**内容**仍留在安全区内——
        // 之前整个 VStack ignoresSafeArea，抽屉最后一两行会压到 Home 指示条下面
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .shadow(color: .black.opacity(0.15), radius: 12, x: 4, y: 0)
    }

    /// 底部工具条：左「最近 / 目录」胶囊切换 + 右「＋」新建。全部在拇指区。
    private var bottomBar: some View {
        HStack(spacing: 10) {
            if !isSearching {
                modeChip(icon: "clock", text: "最近", tag: 0)
                modeChip(icon: "folder", text: "目录", tag: 1)
            }
            Spacer(minLength: 8)
            composeButton
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func modeChip(icon: String, text: String, tag: Int) -> some View {
        let active = browseMode == tag
        return Button {
            if browseMode != tag {
                browseMode = tag
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(text).font(.subheadline.weight(active ? .semibold : .regular))
            }
            .foregroundColor(active ? .white : Color.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(active ? Color(red: 0.17, green: 0.61, blue: 0.56) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var composeButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showCompose = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.17, green: 0.61, blue: 0.56)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        // 44pt 热区（思源被骂「图标小易误触」，热区必须够）
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
            if !q.isEmpty && !result.isEmpty {
                recordSearch(q)
            }
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

    /// 记录搜索历史：去重置顶、最多 8 条、UserDefaults 持久化
    private func recordSearch(_ term: String) {
        var list = UserDefaults.standard.stringArray(forKey: "trilium.searchHistory") ?? []
        list.removeAll { $0 == term }
        list.insert(term, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        UserDefaults.standard.set(list, forKey: "trilium.searchHistory")
        searchHistory = list
    }

    /// 删除笔记：服务端 DELETE → 清本地缓存 → 从列表移除（无需整页重载）
    private func deleteNote() async {
        guard let note = noteToDelete else { return }
        deleting = true
        do {
            try await ETAPIClient.shared.deleteNote(note.noteId)
            AppLogger.shared.log("已删除笔记: \(note.title)")
        } catch {
            // 断网/失败：入离线队列，列表照样移除（队列保序，联网后补交删除）
            NoteCache.shared.enqueue(PendingOp(kind: "delete", id: UUID().uuidString,
                noteId: note.noteId, title: note.title, content: nil, parentNoteId: nil,
                createdAt: Date()))
            AppLogger.shared.log("删除已入离线队列: \(note.title)")
        }
        NoteCache.shared.remove(note.noteId)
        notes.removeAll { $0.noteId == note.noteId }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        deleting = false
        noteToDelete = nil
    }
}

/// 笔记列表行：类型图标 + 标题 + 正文摘要 + 修改时间。
/// ⚠️ 三行结构（标题/摘要/时间）照抄苹果备忘录 + 有道云：
///   用户库里全是「密码」「网线线序」这种短标题，光看标题分不清内容，
///   摘要那一行才是真正帮人快速定位的信息。
struct NoteRow: View {
    let note: Note
    @State private var summary: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.icon(for: note.type))
                .foregroundColor(Self.iconColor(for: note.type))
                .font(.system(size: 18))
                .frame(width: 26, height: 26)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(note.title.isEmpty ? "（无标题）" : note.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !note.friendlyModified.isEmpty {
                    Text(note.friendlyModified)
                        .font(.system(size: 11))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        // 分隔线自己画：系统分隔线从图标左边起，和标题文字不对齐；
        // 这里让它从**标题文字左边**开始（图标 26 + 间距 12 = 38），视觉上更整齐、层次更清楚
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
                .padding(.leading, 38)
        }
        .onAppear { loadSummaryIfNeeded() }
    }

    private func loadSummaryIfNeeded() {
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
        // 文字类：读本地缓存的内容（读过的笔记才有），剥标签取前 70 字
        guard let html = NoteCache.shared.loadContent(note.noteId), !html.isEmpty else { return }
        let text = Self.plainText(from: html)
        if !text.isEmpty { summary = String(text.prefix(70)) }
    }

    /// HTML → 纯文本（去标签、解常见实体、压空白）
    static func plainText(from html: String) -> String {
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

/// 速记弹窗：输入一句话存到收件箱。
/// 「打开即写」——弹出立刻聚焦键盘（学 flomo：从打开到落笔不超过两步）
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var errorMsg = ""
    @FocusState private var inputFocused: Bool
    var onSaved: () async -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                // ⚠️ iOS 15 兼容：不能用 TextField(axis:)/lineLimit(1...8)（iOS 16 API）
                TextField("记点什么…（存入收件箱）", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .focused($inputFocused)
                    .submitLabel(.done)
                    .onSubmit { if !text.trimmingCharacters(in: .whitespaces).isEmpty { save() } }
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
            .onAppear {
                // 立刻聚焦（等 sheet 动画起来一点再聚焦，否则键盘弹不出来）
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    inputFocused = true
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
            } catch {
                // 断网/失败：入离线队列（收件箱），联网后补交
                NoteCache.shared.enqueue(PendingOp(kind: "create", id: UUID().uuidString,
                    noteId: "", title: content, content: nil, parentNoteId: nil,
                    createdAt: Date()))
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            text = "" // 清输入，连续速记不用手动删
            await onSaved()
            if !NoteCache.shared.pendingOps.isEmpty {
                await NoteCache.shared.flushPendingOps()
            }
            dismiss()
            busy = false
        }
    }
}
