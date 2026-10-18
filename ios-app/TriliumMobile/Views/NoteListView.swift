import SwiftUI
import UIKit

/// 首页浏览模式：最近 / 收藏 / 目录
enum BrowseMode: Int, CaseIterable {
    case recent = 0
    case favorites = 1
    case tree = 2

    var title: String {
        switch self {
        case .recent: return "最近"
        case .favorites: return "收藏"
        case .tree: return "目录"
        }
    }

    var icon: String {
        switch self {
        case .recent: return "clock"
        case .favorites: return "star"
        case .tree: return "folder"
        }
    }
}

/// 整理动作（移动 / 克隆），选中目标目录后执行
enum OrganizeAction {
    case move
    case clone

    var verb: String { self == .move ? "移动" : "克隆" }
}

/// 待整理的目标（sheet(item:) 需要 Identifiable，tuple 不行）
struct OrganizeTarget: Identifiable {
    let id = UUID()
    let note: Note
    let action: OrganizeAction
}

/// 首页：笔记列表（列表优先 + 抽屉目录）。
/// 大标题 + 搜索；底部胶囊「最近｜收藏｜目录」+ 新建按钮（全在拇指区）。
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
    @State private var browseMode: BrowseMode = .recent
    /// 搜索历史（最近 8 条，UserDefaults 持久化）；搜索无结果时给出可点词条
    @State private var searchHistory: [String] = []
    /// 离线待同步操作数（顶部提示条）
    @State private var pendingCount = 0
    /// 左滑抽屉：目录树覆盖层（学有道云/Obsidian——树和列表共存，不用二选一）。
    /// ⚠️ 由 MainView 持有：抽屉是 ZStack 里的覆盖层，但导航栏（toolbar 按钮）由
    ///    NavigationView 单独渲染，层级永远高于内容区 → 不把状态提上去，
    ///    抽屉打开时右上角的「目录/设置」按钮会浮在遮罩上（穿模）并且还能点到。
    @Binding var drawerOpen: Bool
    /// 整理（移动/克隆）目标选择
    @State private var organizeTarget: OrganizeTarget?
    /// 顶部轻提示（收藏/移动结果）
    @State private var toast: String?
    /// 更新下载状态（真正跑在 UpdateCenter 的后台会话里，本视图销毁不影响）
    @ObservedObject private var updater = UpdateCenter.shared
    @State private var showUpdatePage = false

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 换模式 / 改搜索词都要重新取数
    private var loadKey: String { "\(browseMode.rawValue)|\(searchQuery)" }

    var body: some View {
        ZStack(alignment: .leading) {
            Group {
                if isSearching || browseMode != .tree {
                    content
                } else {
                    TreeView(embedded: true)
                }
            }
            // ⚠️ 左滑出抽屉的手势挂在**内容上**（simultaneousGesture），不再用边缘 22pt 透明条带：
            //   那条透明视图盖在列表/树之上，把左边缘 22pt 的点击全吞了 —— 用户反馈
            //   「目录点击不跟手」的第一个原因就是这个（第二个是树行只有文字能点）。
            //   现在整屏都能拖，但只在「左侧 44pt 内起手 + 横向位移为主」时才开抽屉。
            .simultaneousGesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .onEnded { v in
                        guard !drawerOpen, v.startLocation.x < 44 else { return }
                        guard v.translation.width > 70, abs(v.translation.height) < 80 else { return }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            drawerOpen = true
                        }
                    }
            )

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
        .navigationTitle(isSearching ? "搜索"
                         : (browseMode == .recent ? "笔记" : browseMode.title))
        .navigationBarTitleDisplayMode(isSearching ? .inline : .large)
        .searchable(text: $searchQuery, prompt: "搜索笔记")
        .toolbar {
            // 抽屉除了边缘手势，也给一个明确入口（不是所有人都会去摸左边缘）
            ToolbarItem(placement: .navigationBarLeading) {
                // 抽屉打开时收起：导航栏压在抽屉之上，留着按钮就是穿模 + 可点穿
                if !drawerOpen && !isSearching && browseMode != .tree {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { drawerOpen = true }
                    } label: {
                        Image(systemName: "list.bullet.indent")
                    }
                    .accessibilityLabel("打开目录")
                }
            }
        }
        // ⚠️ 抽屉打开时必须收起底部工具条：safeAreaInset 的条带渲染在 ZStack 内容**之上**，
        //   不收起的话抽屉会在底部被工具条压一条，胶囊/＋按钮还能隔着抽屉点到。
        // ⚠️ 更新进度条**不能**放 top：大标题导航栏是浮在内容之上的，滚动到顶部时
        //   「笔记」会直接压在 it 上面（用户截图实测穿模）。放到工具条上方，同一块安全区里。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !drawerOpen {
                VStack(spacing: 0) {
                    if updater.phase.isDownloading || updater.phase.isReady {
                        updateBanner
                    }
                    bottomBar
                }
            }
        }
        // 防抖实时搜索：停 400ms 才发请求；换模式也走同一个 task
        .task(id: loadKey) {
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
        // 搜索框在导航栏里（层级高于遮罩，压不住）：抽屉开着时一旦开始输入就顺手收回，
        // 否则会出现「抽屉还开着、导航栏已切成搜索态」的错位画面
        .onChange(of: searchQuery) { q in
            if drawerOpen && !q.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NoteCache.pendingOpsChanged)) { _ in
            pendingCount = NoteCache.shared.pendingOps.count
        }
        // 编辑器改了标题：就地刷新列表，返回时看到的不是旧标题
        .onReceive(NotificationCenter.default.publisher(for: .noteMetaChanged)) { _ in
            Task { await load() }
        }
        // 从抽屉树点开笔记：导航已经把阅读页 push 上来了，抽屉必须同步收起
        .onReceive(NotificationCenter.default.publisher(for: .noteDetailAppeared)) { _ in
            if drawerOpen {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView(onSaved: { await load() })
        }
        .sheet(isPresented: $showUpdatePage) {
            NavigationView { UpdateView() }
                .navigationViewStyle(.stack)
        }
        .sheet(item: $organizeTarget) { target in
            MoveTargetPicker(noteTitle: target.note.title) { parentId, parentTitle in
                organizeTarget = nil
                Task { await performOrganize(target, to: parentId, title: parentTitle) }
            }
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
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
                    .overlay(Capsule().stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - 列表

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
            emptyState
        } else {
            List {
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
                if isSearching || browseMode == .favorites {
                    // 搜索结果 / 收藏：平铺（分组反而碍事）
                    ForEach(notes) { note in
                        listRow(note)
                    }
                } else {
                    // 浏览模式按时间分组
                    ForEach(timeGroups.filter { !$0.notes.isEmpty }, id: \.title) { g in
                        Section {
                            ForEach(g.notes) { note in
                                listRow(note)
                            }
                        } header: {
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

    /// 空态：搜索无结果 → 给历史词；收藏为空 → 教怎么收藏
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isSearching ? "magnifyingglass"
                              : (browseMode == .favorites ? "star" : "tray"))
                .font(.system(size: 40)).foregroundColor(.secondary)
            Text(isSearching ? "未找到相关笔记"
                 : (browseMode == .favorites ? "还没有收藏的笔记" : "没有笔记"))
                .font(.footnote).foregroundColor(.secondary)
            if isSearching && !searchHistory.isEmpty {
                VStack(spacing: 8) {
                    Text("试试最近搜过的：").font(.caption).foregroundColor(.secondary)
                    ForEach(searchHistory.prefix(4), id: \.self) { term in
                        Button { searchQuery = term } label: {
                            Text(term)
                                .font(.footnote)
                                .foregroundColor(Color(red: 0.17, green: 0.61, blue: 0.56))
                        }
                    }
                }
                .padding(.top, 6)
            } else if browseMode == .favorites {
                Text("在列表上右滑，或长按笔记 → 收藏")
                    .font(.caption).foregroundColor(Color(UIColor.tertiaryLabel))
            } else if !isSearching {
                Button("刷新试试") { Task { await load() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 列表行：进详情 + 左滑收藏/移动 + 右滑删除 + 长按整理菜单
    private func listRow(_ note: Note) -> some View {
        NavigationLink(destination: NoteDetailView(note: note)) {
            NoteRow(note: note)
        }
        // 系统分隔线贴着行左边缘、和标题文字不对齐 → 隐藏，改由 NoteRow 自己画
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                Task { await toggleBookmark(note) }
            } label: {
                Label(note.isBookmarked ? "取消收藏" : "收藏",
                      systemImage: note.isBookmarked ? "star.slash" : "star")
            }
            .tint(.orange)

            Button {
                organizeTarget = OrganizeTarget(note: note, action: .move)
            } label: {
                Label("移动", systemImage: "folder")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                noteToDelete = note
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                Task { await toggleBookmark(note) }
            } label: {
                Label(note.isBookmarked ? "取消收藏" : "收藏",
                      systemImage: note.isBookmarked ? "star.slash" : "star")
            }
            Button {
                organizeTarget = OrganizeTarget(note: note, action: .move)
            } label: {
                Label("移动到…", systemImage: "folder")
            }
            Button {
                organizeTarget = OrganizeTarget(note: note, action: .clone)
            } label: {
                Label("克隆到…", systemImage: "square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                noteToDelete = note
            } label: {
                Label("删除笔记", systemImage: "trash")
            }
        }
    }

    /// 按修改时间分组：今天 / 昨天 / 本周 / 更早（依赖服务端 dateModified desc 排序）
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

    // MARK: - 抽屉

    private var treeDrawer: some View {
        let w = UIScreen.main.bounds.width * 0.86
        return VStack(spacing: 0) {
            HStack {
                Text("目录").font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
                .accessibilityLabel("关闭目录")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            TreeView(embedded: true)
        }
        .frame(width: w)
        .frame(maxHeight: .infinity)
        // 背景铺满全屏（含底部安全区），但内容留在安全区内
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .shadow(color: .black.opacity(0.15), radius: 12, x: 4, y: 0)
    }

    // MARK: - 常驻更新条

    /// 下载中 / 已就绪时挂在底部工具条上方（不随滚动消失），点开进入常驻下载页。
    private var updateBanner: some View {
        Button {
            showUpdatePage = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: updater.phase.isReady ? "checkmark.seal.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(updater.phase.isReady ? .green : Color(red: 0.17, green: 0.61, blue: 0.56))
                VStack(alignment: .leading, spacing: 4) {
                    Text(updateBannerTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let p = updateBannerProgress {
                        ProgressView(value: p)
                            .tint(Color(red: 0.17, green: 0.61, blue: 0.56))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
            // 分隔线在**上沿**：下面是工具条，两条 bar 无缝拼在一起
            .overlay(alignment: .top) {
                Rectangle().fill(Color(UIColor.separator).opacity(0.6)).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var updateBannerTitle: String {
        switch updater.phase {
        case .downloading(let received, let total):
            let v = updater.latestVersion.map { " v\($0)" } ?? ""
            guard total > 0 else { return "正在后台下载\(v)…" }
            return "正在后台下载\(v) · \(Int(Double(received) / Double(total) * 100))%"
        case .ready(let version, _):
            return "v\(version) 已下载好 · 点此安装"
        default:
            return ""
        }
    }

    private var updateBannerProgress: Double? {
        if case .downloading(let received, let total) = updater.phase, total > 0 {
            return min(1, Double(received) / Double(total))
        }
        return nil
    }

    // MARK: - 底部工具条

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if !isSearching {
                ForEach(BrowseMode.allCases, id: \.rawValue) { mode in
                    modeChip(mode)
                }
            }
            Spacer(minLength: 6)
            composeButton
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }

    private func modeChip(_ mode: BrowseMode) -> some View {
        let active = browseMode == mode
        return Button {
            if browseMode != mode {
                browseMode = mode
                UISelectionFeedbackGenerator().selectionChanged()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.icon).font(.system(size: 12, weight: .semibold))
                Text(mode.title).font(.subheadline.weight(active ? .semibold : .regular))
            }
            .foregroundColor(active ? .white : Color.secondary)
            .padding(.horizontal, 12)
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
            Image(systemName: "square.and.pencil")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(red: 0.17, green: 0.61, blue: 0.56)))
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建笔记")
    }

    // MARK: - 数据

    private func load() async {
        loading = true
        loadGeneration += 1
        let gen = loadGeneration
        let q = searchQuery.trimmingCharacters(in: .whitespaces) // 提到 do 外：catch 里也要用它记日志
        do {
            let result: [Note]
            if q.isEmpty {
                switch browseMode {
                case .favorites:
                    result = try await ETAPIClient.shared.bookmarkedNotes()
                default:
                    result = try await ETAPIClient.shared.recentNotes()
                    NoteCache.shared.saveRecentNotes(result) // 缓存，离线可看
                }
            } else {
                result = try await ETAPIClient.shared.searchNotes(q)
            }
            guard gen == loadGeneration else { return }
            notes = result
            if !q.isEmpty && !result.isEmpty {
                recordSearch(q)
            }
            AppLogger.shared.log("列表加载完成：\(result.count) 条（\(browseMode.title)）")
            errorMsg = ""
        } catch {
            guard gen == loadGeneration else { return }
            // 切走/切 tab 导致的取消不是错误，别弹「加载失败」，也别污染日志
            let ns = error as NSError
            if error is CancellationError
                || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) {
                loading = false
                return
            }
            AppLogger.shared.log("列表加载失败（\(browseMode.title)/\(q.isEmpty ? "无关键词" : q)）: \(error.localizedDescription)")
            if browseMode == .recent,
               let cached = NoteCache.shared.loadRecentNotes(), !cached.isEmpty {
                notes = cached
                // 别只写「离线模式」：解析失败/证书问题也被归到这里，把原因带上才好排查
                errorMsg = "显示缓存（\(error.localizedDescription)）"
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

    /// 删除笔记：服务端 DELETE → 清本地缓存 → 从列表移除
    private func deleteNote() async {
        guard let note = noteToDelete else { return }
        deleting = true
        do {
            try await ETAPIClient.shared.deleteNote(note.noteId)
            AppLogger.shared.log("已删除笔记: \(note.title)")
        } catch {
            // 断网/失败：入离线队列，列表照样移除（联网后补交删除）
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

    /// 收藏 / 取消收藏（写/删一个 bookmarked 标签）
    private func toggleBookmark(_ note: Note) async {
        do {
            if let aid = note.bookmarkAttributeId {
                try await ETAPIClient.shared.deleteAttribute(aid)
                showToast("已取消收藏")
            } else {
                try await ETAPIClient.shared.createAttribute(noteId: note.noteId, name: "bookmarked")
                showToast("已收藏")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await load()
        } catch {
            showToast("操作失败：\(error.localizedDescription)")
        }
    }

    /// 移动 / 克隆到选定目录
    private func performOrganize(_ target: OrganizeTarget, to parentId: String, title: String) async {
        do {
            switch target.action {
            case .move:
                let from = target.note.parentNoteIds?.first ?? "root"
                try await ETAPIClient.shared.moveNote(target.note.noteId, from: from, to: parentId)
            case .clone:
                try await ETAPIClient.shared.addBranch(noteId: target.note.noteId, parentNoteId: parentId)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已\(target.action.verb)到「\(title)」")
            AppLogger.shared.log("\(target.action.verb)笔记[\(target.note.title)] → \(title)")
            await load()
        } catch {
            showToast("\(target.action.verb)失败：\(error.localizedDescription)")
            AppLogger.shared.log("\(target.action.verb)失败: \(error.localizedDescription)")
        }
    }

    private func showToast(_ msg: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.18)) { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toast == msg {
                withAnimation(.easeIn(duration: 0.2)) { toast = nil }
            }
        }
    }
}

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
    @State private var summary: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NoteIconBadge(type: note.type, size: 30)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(note.title.isEmpty ? "（无标题）" : note.title)
                        .font(.system(size: 16, weight: .medium))
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
        .padding(.vertical, 7)
        // 分隔线从标题文字左边起（图标 30 + 间距 12 = 42），比系统分隔线整齐
        .overlay(alignment: .bottomLeading) {
            Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5)
                .padding(.leading, 42)
        }
        .onAppear { Task { await loadSummaryIfNeeded() } }
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

    static func iconColor(for type: String) -> Color {
        switch type {
        case "code": return Color(red: 0.90, green: 0.49, blue: 0.13)      // 橙
        case "image": return Color(red: 0.85, green: 0.35, blue: 0.55)     // 桃红
        case "file": return Color(red: 0.20, green: 0.48, blue: 0.90)      // 蓝
        case "book": return Color(red: 0.93, green: 0.63, blue: 0.14)      // 琥珀
        case "render": return Color(red: 0.53, green: 0.40, blue: 0.85)    // 紫
        case "mermaid": return Color(red: 0.33, green: 0.45, blue: 0.85)   // 靛
        default: return Color(red: 0.17, green: 0.61, blue: 0.56)          // 主题青
        }
    }
}

/// 速记 / 新建笔记：整块输入区，第一行自动作为标题（学苹果备忘录与 flomo 的零摩擦输入）。
/// 旧版是「圆角输入框 + 两个导航按钮」，所以看着「粗」。
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var noteType = "text"
    @State private var busy = false
    @State private var errorMsg = ""
    @FocusState private var inputFocused: Bool
    var onSaved: () async -> Void

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private let accent = Color(red: 0.17, green: 0.61, blue: 0.56)

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部信息条：存到哪 + 字数
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").font(.system(size: 11))
                    Text("存入 收件箱").font(.system(size: 12))
                    Spacer()
                    Text("\(text.count) 字").font(.system(size: 11))
                }
                .foregroundColor(Color(UIColor.tertiaryLabel))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 10)

                // 输入区：无边框多行输入 + 占位提示
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("记点什么…\n第一行会作为标题")
                            .font(.system(size: 17))
                            .lineSpacing(4)
                            .foregroundColor(Color(UIColor.placeholderText))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 17))
                        .lineSpacing(4)
                        .focused($inputFocused)
                        // 抵消 TextEditor 自带的 5pt 内边距，让文字和顶部提示条对齐
                        .padding(.horizontal, -5)
                        .padding(.vertical, -6)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if !errorMsg.isEmpty {
                    Text(errorMsg)
                        .font(.footnote).foregroundColor(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)
                }

                Divider()
                // 底部：类型选择（文本/代码）+ 保存
                HStack(spacing: 8) {
                    typeChip("text", "文本", "doc.text")
                    typeChip("code", "代码", "curlybraces")
                    Spacer()
                    Button {
                        save()
                    } label: {
                        Text(busy ? "保存中…" : "保存")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(
                                Capsule().fill(trimmed.isEmpty ? Color(UIColor.systemGray3) : accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || trimmed.isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("新建笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { inputFocused = true }
            }
        }
    }

    private func typeChip(_ type: String, _ label: String, _ icon: String) -> some View {
        let active = noteType == type
        return Button {
            noteType = type
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 13, weight: active ? .semibold : .regular))
            }
            .foregroundColor(active ? accent : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? accent.opacity(0.12) : Color(UIColor.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    /// 首行 = 标题，其余 = 正文（正文按空行切段落包 <p>）
    private func save() {
        let raw = text
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let lines = raw.components(separatedBy: "\n")
        var title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty { title = "无标题" }
        if title.count > 120 { title = String(title.prefix(120)) }
        let body = lines.dropFirst().joined(separator: "\n")
        let content = noteType == "code"
            ? body.trimmingCharacters(in: .newlines)
            : Self.html(fromPlain: body)

        busy = true
        Task {
            do {
                let inboxId = try await ETAPIClient.shared.ensureInbox()
                _ = try await ETAPIClient.shared.createNote(
                    parentNoteId: inboxId, title: title, content: content, type: noteType)
            } catch {
                // 断网/失败：入离线队列（队列模型只带标题，正文不入队）
                NoteCache.shared.enqueue(PendingOp(kind: "create", id: UUID().uuidString,
                    noteId: "", title: title, content: nil, parentNoteId: nil,
                    createdAt: Date()))
                AppLogger.shared.log("新建已入离线队列: \(title)")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            text = ""
            await onSaved()
            if !NoteCache.shared.pendingOps.isEmpty {
                await NoteCache.shared.flushPendingOps()
            }
            busy = false
            dismiss()
        }
    }

    /// 纯文本 → Trilium 文本笔记的 HTML（空行分段，段内换行用 <br>）
    static func html(fromPlain plain: String) -> String {
        let paras = plain.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if paras.isEmpty { return "" }
        return paras.map { p in
            let esc = p
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
            return "<p>\(esc)</p>"
        }.joined()
    }
}
