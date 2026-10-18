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
    }

    @ViewBuilder
    private var treeBody: some View {
        if loading {
            ProgressView("加载目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
    }

    private enum LoadOutcome {
        case ok([Note])
        case failed(String)
        case timeout
    }

    private func loadRoot() async {
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
enum TreeExpandedStore {
    private static let key = "trilium.treeExpandedIds"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func set(_ noteId: String, expanded: Bool) {
        var s = load()
        if expanded { s.insert(noteId) } else { s.remove(noteId) }
        // 上限 200 条，防无限增长
        let arr = Array(s.prefix(200))
        UserDefaults.standard.set(arr, forKey: key)
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
                .font(.subheadline)
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
        isLoadingChildren = true
        do {
            children = try await ETAPIClient.shared.childNotes(of: note.noteId)
        } catch {
            children = []
            AppLogger.shared.log("展开[\(note.title)]失败: \(error.localizedDescription)")
        }
        isLoadingChildren = false
    }
}
