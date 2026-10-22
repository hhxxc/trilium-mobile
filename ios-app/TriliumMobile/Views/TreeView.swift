import SwiftUI

/// 笔记树：真正的递归折叠树（像文件管理器）。
/// 顶层显示 root 直接子级，点箭头按需展开下一层，缩进表示层级。
/// 叶子笔记点标题直接进阅读页。
struct TreeView: View {
    var embedded: Bool = false
    @Environment(\.dismiss) private var dismiss

    @State private var rootChildren: [Note] = []
    @State private var loading = true
    @State private var errorMsg = ""

    var body: some View {
        Group {
            if embedded {
                treeBody
            } else {
                NavigationView {
                    treeBody
                        .navigationTitle("目录")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("完成") { dismiss() }
                            }
                        }
                }
                .navigationViewStyle(.stack)
            }
        }
        // ⚠️ 必须在最外层挂 task：v1.2.3 重写时漏了这行 → loading 永远 true，
        //   界面永久「加载目录…」（连超时都不触发，因为请求根本没发起）。实测踩坑。
        .task {
            if rootChildren.isEmpty { await loadRoot() }
        }
        // 主备地址互换后目录也重拉（首屏可能已对着旧地址失败过）
        .onReceive(NotificationCenter.default.publisher(for: .serverSwitched)) { _ in
            TreeChildCache.clear()
            Task { await loadRoot() }
        }
        // 离线新建/删除补交成功（别的页面触发）→ 目录结构已经变了
        .onReceive(NotificationCenter.default.publisher(for: NoteCache.treeStructureChanged)) { _ in
            TreeChildCache.clear()
            Task { await loadRoot() }
        }
    }

    @ViewBuilder
    private var treeBody: some View {
        if loading {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(Color(UIColor.secondarySystemFill))
                        .frame(height: 15)
                        .padding(.leading, CGFloat(10 + (i % 3) * 18))
                        .padding(.trailing, 16)
                }
                Spacer()
            }
            .padding(.top, 8)
            .redacted(reason: .placeholder)
        } else if !errorMsg.isEmpty {
            VStack(spacing: 12) {
                Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                Button("重试") { Task { await loadRoot() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rootChildren) { note in
                        TreeNodeView(note: note, depth: 0)
                    }
                }
                .padding(.vertical, 8)
            }
            .hideScrollIndicators()
        }
    }

    private enum LoadOutcome {
        case ok([Note])
        case failed(String)
        case timeout
    }

    private func loadRoot() async {
        // 命中缓存直接秒开（抽屉/目录页来回切不再转圈）
        if let cached = TreeChildCache.get("root") {
            rootChildren = cached
            loading = false
            errorMsg = ""
            return
        }
        loading = true
        errorMsg = ""
        // 请求与 12 秒超时竞速：无论服务端多慢，界面都不会无限转圈
        let outcome = await withTaskGroup(of: LoadOutcome?.self) { group -> LoadOutcome in
            group.addTask {
                do { return .ok(try await ETAPIClient.shared.childNotes(of: "root")) }
                catch { return .failed(error.localizedDescription) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                return Task.isCancelled ? nil : .timeout
            }
            for await r in group {
                if let r {
                    group.cancelAll()
                    return r
                }
            }
            return .timeout
        }
        switch outcome {
        case .ok(let list):
            rootChildren = list
            TreeChildCache.set("root", list)
            AppLogger.shared.log("目录加载完成：\(list.count) 项")
        case .failed(let msg):
            errorMsg = "加载失败：\(msg)"
            AppLogger.shared.log("目录加载失败: \(msg)")
        case .timeout:
            errorMsg = "加载超时，点重试"
            AppLogger.shared.log("目录加载超时(12s)")
        }
        loading = false
    }
}

/// 树节点展开状态持久化：记住展开过的目录，下次进来直接还原
/// （深目录用户最需要——每次进 App 重新点开三层文件夹很烦）
///
/// ⚠️ 性能（2026-10-22 深度优化）：旧版每次 `load()` 都读 UserDefaults + 建 Set，
///    而每个 TreeNodeView 初始化都会调一次 —— 一屏 30 个节点就是 30 次 plist 解析。
///    现在首次读一次进内存，之后只在展开/收起时合并写盘（0.4s 防抖）。
enum TreeExpandedStore {
    private static let key = "trilium.treeExpandedIds"
    private static var cache: Set<String>?
    private static var saveWork: DispatchWorkItem?

    static func load() -> Set<String> {
        if let c = cache { return c }
        let s = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        cache = s
        return s
    }

    static func set(_ noteId: String, expanded: Bool) {
        var s = load()
        if expanded { s.insert(noteId) } else { s.remove(noteId) }
        // 上限 200 条，防无限增长
        if s.count > 200 { s = Set(s.prefix(200)) }
        cache = s
        saveWork?.cancel()
        let snapshot = Array(s)
        let work = DispatchWorkItem { UserDefaults.standard.set(snapshot, forKey: key) }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

/// 目录子级内存缓存：树展开一次要打 1 + N 个请求（父笔记 + 逐个子笔记详情），
/// 抽屉/目录页来回切时如果每次重拉，用户看到的就是反复转圈。
/// 30s TTL + 移动/删除后显式 clear，兼顾「快」和「不显示旧结构」。
enum TreeChildCache {
    private static var store: [String: (notes: [Note], at: Date)] = [:]
    private static let lock = NSLock()
    private static let ttl: TimeInterval = 30

    static func get(_ parentId: String) -> [Note]? {
        lock.lock(); defer { lock.unlock() }
        guard let hit = store[parentId],
              Date().timeIntervalSince(hit.at) < ttl else { return nil }
        return hit.notes
    }

    static func set(_ parentId: String, _ notes: [Note]) {
        lock.lock(); defer { lock.unlock() }
        store[parentId] = (notes, Date())
    }

    /// 结构变了（移动/删除/新建）→ 整棵树的子级缓存作废
    static func clear() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
    }
}

/// 树行按钮样式：按下即高亮（SwiftUI 默认 plain 样式没有任何按压反馈，
/// 点了看不出有没有反应，也是「不跟手」的一部分）
struct TreeRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(UIColor.systemGray5) : Color.clear)
    }
}

/// 单个树节点：递归渲染。有子笔记 → 展开箭头 + 子节点；叶子 → 点击进阅读页。
struct TreeNodeView: View {
    let note: Note
    let depth: Int

    @State private var isExpanded: Bool
    @State private var children: [Note]? = nil
    @State private var isLoadingChildren = false

    init(note: Note, depth: Int) {
        self.note = note
        self.depth = depth
        // 还原上次的展开状态
        _isExpanded = State(initialValue: TreeExpandedStore.load().contains(note.noteId))
    }

    /// 是否有子笔记（getNote 补全的 childNoteIds 为准）
    private var hasChildren: Bool {
        visibleChildCount > 0
    }

    /// 可见子项数：排除系统笔记（_hidden 那些不显示，数量也不该算进去）
    private var visibleChildCount: Int {
        (note.childNoteIds ?? []).filter { !$0.hasPrefix("_") }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nodeRow
            if isExpanded {
                if let children {
                    ForEach(children) { child in
                        TreeNodeView(note: child, depth: depth + 1)
                    }
                } else if isLoadingChildren {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Spacer()
                    }
                    .padding(.leading, leadingPadding)
                    .padding(.vertical, 8)
                }
            }
        }
        .task {
            // 进入时若已展开（状态还原），补拉子级
            if isExpanded && children == nil { await loadChildren() }
        }
    }

    private var leadingPadding: CGFloat {
        10 + CGFloat(depth) * 18
    }

    /// 整行一个可点区域（⚠️ 旧版只有「箭头按钮 + 标题文字」能点，右侧空白点不动，
    /// 用户体感就是「点击不跟手」）。现在箭头/图标/标题/空白合并成同一行按钮，
    /// 容器行 = 展开收起，叶子行 = 进阅读页；配合按下高亮给出即时反馈。
    private var nodeRow: some View {
        Group {
            if hasChildren {
                HStack(spacing: 0) {
                    Button(action: toggleExpand) {
                        rowContent(showArrow: true)
                    }
                    .buttonStyle(TreeRowButtonStyle())
                    // 进「目录内浏览」：一屏看完这个目录下的内容。
                    // 整行点击仍然是展开/收起（不破坏原有手感），右侧这个小按钮才是进目录页。
                    NavigationLink(destination: FolderNotesView(folder: note)) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("进入目录 \(note.title)")
                }
            } else {
                NavigationLink(destination: NoteDetailView(note: note)) {
                    rowContent(showArrow: false)
                }
                .buttonStyle(TreeRowButtonStyle())
            }
        }
    }

    private func rowContent(showArrow: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(UIColor.tertiaryLabel))
                .frame(width: 16)
                .opacity(showArrow ? 1 : 0)

            NoteIconBadge(type: note.type, size: 26)

            Text(note.title.isEmpty ? "（无标题）" : note.title)
                .font(.callout)
                .foregroundColor(.primary)
                .lineLimit(1)

            // 收起状态下显示子项数量：一眼看出哪个目录里有东西，值不值得展开
            if hasChildren, !isExpanded {
                Text("\(visibleChildCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(UIColor.tertiarySystemFill)))
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func toggleExpand() {
        if isExpanded {
            isExpanded = false
            TreeExpandedStore.set(note.noteId, expanded: false)
            return
        }
        isExpanded = true
        TreeExpandedStore.set(note.noteId, expanded: true)
        if children == nil {
            Task { await loadChildren() }
        }
    }

    private func loadChildren() async {
        if let cached = TreeChildCache.get(note.noteId) {
            children = cached
            return
        }
        isLoadingChildren = true
        do {
            let list = try await ETAPIClient.shared.childNotes(of: note.noteId)
            children = list
            TreeChildCache.set(note.noteId, list)
        } catch {
            children = []
            AppLogger.shared.log("展开[\(note.title)]失败: \(error.localizedDescription)")
        }
        isLoadingChildren = false
    }
}
