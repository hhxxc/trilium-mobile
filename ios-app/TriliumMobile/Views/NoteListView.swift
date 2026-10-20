import SwiftUI
import UIKit

/// UserDefaults 键：搜索历史（集中管理，别散落硬编码字符串）
private let searchHistoryKey = "trilium.searchHistory"

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
    /// 冲突待裁决数：补交时发现别处改过同一篇，需要用户选「保留我的 / 丢弃我的」
    @State private var conflictCount = 0
    @State private var showConflicts = false
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

    // 搜索范围 / 排序（只影响客户端：标题过滤、按修改时间重排）
    @State private var searchTitleOnly = false
    @State private var searchByModified = false

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
                Theme.scrim
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
            searchHistory = UserDefaults.standard.stringArray(forKey: searchHistoryKey) ?? []
            refreshPendingBadge()
        }
        // 搜索框在导航栏里（层级高于遮罩，压不住）：抽屉开着时一旦开始输入就顺手收回，
        // 否则会出现「抽屉还开着、导航栏已切成搜索态」的错位画面
        .onChange(of: searchQuery) { q in
            if drawerOpen && !q.isEmpty {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drawerOpen = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NoteCache.pendingOpsChanged)) { _ in
            refreshPendingBadge()
        }
        .onReceive(NotificationCenter.default.publisher(for: NoteCache.conflictDetected)) { _ in
            refreshPendingBadge()
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
        .sheet(isPresented: $showConflicts) {
            NavigationView { ConflictResolveView(onResolved: { refreshPendingBadge() }) }
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

    /// 加载骨架：几条灰条占位，比「加载中…」转圈更直观（列表数据未回来时展示）
    private var skeletonList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<7, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 7) {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(Color(UIColor.secondarySystemFill))
                        .frame(width: 170, height: 16)
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(Color(UIColor.secondarySystemFill))
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private var content: some View {
        if loading && notes.isEmpty {
            skeletonList
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
                if isSearching {
                    searchControlsRow
                }
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
                // 冲突必须让用户看见：静默覆盖别人（桌面端/网页）的改动是最难受的一种丢数据
                if conflictCount > 0 {
                    Button { showConflicts = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("\(conflictCount) 条改动与服务端冲突（点击处理）")
                                .font(.footnote)
                                .foregroundColor(.red)
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
                    // 这两种场景笔记来自不同目录，行里补一行「所在目录」——
                    // 同名笔记（一条 text 一条 file）靠它才能分清
                    ForEach(notes) { note in
                        listRow(note, showsLocation: true)
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
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.secondary)
                                .textCase(nil)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - 搜索范围 / 排序

    /// 搜索页顶部的一排胶囊：范围（全部 / 仅标题）+ 排序（相关度 / 最近修改）
    private var searchControlsRow: some View {
        HStack(spacing: 8) {
            chip("全部", active: !searchTitleOnly) {
                guard searchTitleOnly else { return }
                searchTitleOnly = false
                Task { await load() }
            }
            chip("仅标题", active: searchTitleOnly) {
                guard !searchTitleOnly else { return }
                searchTitleOnly = true
                Task { await load() }
            }
            Spacer(minLength: 8)
            chip(searchByModified ? "最近修改" : "相关度", active: searchByModified) {
                searchByModified.toggle()
                Task { await load() }
            }
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 14, bottom: 6, trailing: 14))
    }

    private func chip(_ text: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundColor(active ? .white : Color(UIColor.secondaryLabel))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(active
                    ? Theme.accent
                    : Color(UIColor.secondarySystemFill)))
        }
        .buttonStyle(.plain)
    }

    /// 空态：搜索无结果 → 给历史词；收藏为空 → 教怎么收藏
    private var emptyState: some View {        VStack(spacing: 12) {
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
                                .foregroundColor(Theme.accent)
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
    private func listRow(_ note: Note, showsLocation: Bool = false) -> some View {
        NavigationLink(destination: NoteDetailView(note: note)) {
            NoteRow(note: note, showsLocation: showsLocation)
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
                    .foregroundColor(updater.phase.isReady ? .green : Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(updateBannerTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let p = updateBannerProgress {
                        ProgressView(value: p)
                            .tint(Theme.accent)
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
                Capsule().fill(active ? Theme.accent : Color.clear)
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
                .background(Circle().fill(Theme.accent))
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
                // 拉多一点再做本地筛选：标题过滤 / 按修改时间重排都在客户端完成，
                // 不需要服务端支持额外的搜索语法（也更不容易因为服务端版本差异翻车）
                var hits = try await ETAPIClient.shared.searchNotes(q, limit: 100)
                if searchTitleOnly {
                    hits = hits.filter { $0.title.localizedCaseInsensitiveContains(q) }
                }
                if searchByModified {
                    hits.sort { ($0.modifiedDate ?? .distantPast) > ($1.modifiedDate ?? .distantPast) }
                }
                result = hits
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
        var list = UserDefaults.standard.stringArray(forKey: searchHistoryKey) ?? []
        list.removeAll { $0 == term }
        list.insert(term, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        UserDefaults.standard.set(list, forKey: searchHistoryKey)
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

    /// 待同步 / 冲突角标刷新（入队、补交、冲突裁决后都要刷）
    private func refreshPendingBadge() {
        pendingCount = NoteCache.shared.pendingOps.count
        conflictCount = NoteCache.shared.conflictedOps().count
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

/// 冲突裁决页：离线期间的改动，在补交时发现服务端（桌面端/网页）已经改过同一篇。
/// 两条路：保留我的（覆盖对方）/ 丢弃我的（以服务端为准）。
/// ⚠️ 不做自动合并 —— 正文是 HTML/代码，自动合并只会合成一坨谁都看不懂的东西，
///    把选择权交给人，比"聪明"地弄坏内容强。
struct ConflictResolveView: View {
    var onResolved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ops: [PendingOp] = NoteCache.shared.conflictedOps()
    @State private var busy = false

    var body: some View {
        Group {
            if ops.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40)).foregroundColor(.secondary)
                    Text("没有待处理的冲突").font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(ops) { op in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(op.title?.isEmpty == false ? op.title! : "（无标题）")
                                .font(.subheadline)
                            Text(Self.kindText(op.kind))
                                .font(.caption).foregroundColor(.secondary)
                            HStack(spacing: 12) {
                                Button {
                                    keepMine(op)
                                } label: {
                                    Text("保留我的").font(.footnote)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy)
                                Button(role: .destructive) {
                                    dropMine(op)
                                } label: {
                                    Text("丢弃我的").font(.footnote)
                                }
                                .buttonStyle(.bordered)
                                .disabled(busy)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("冲突处理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
    }

    private static func kindText(_ kind: String) -> String {
        switch kind {
        case "putContent": return "改动的是正文"
        case "patchTitle": return "改动的是标题"
        default: return "改动类型：\(kind)"
        }
    }

    private func keepMine(_ op: PendingOp) {
        NoteCache.shared.resolveKeepMine(op.id)
        ops.removeAll { $0.id == op.id }
        onResolved()
        // 裁决完立刻补交：保留我的 → 直接覆盖写上去
        Task {
            busy = true
            await NoteCache.shared.flushPendingOps()
            busy = false
            onResolved()
        }
    }

    private func dropMine(_ op: PendingOp) {
        NoteCache.shared.resolveDropMine(op.id)
        ops.removeAll { $0.id == op.id }
        onResolved()
    }
}
