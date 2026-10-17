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

/// 单个树节点：递归渲染。有子笔记 → 展开箭头 + 子节点；叶子 → 点击进阅读页。
struct TreeNodeView: View {
    let note: Note
    let depth: Int

    @State private var isExpanded = false
    @State private var children: [Note]? = nil
    @State private var isLoadingChildren = false

    /// 是否有子笔记（getNote 补全的 childNoteIds 为准）
    private var hasChildren: Bool {
        !(note.childNoteIds ?? []).isEmpty
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
    }

    private var leadingPadding: CGFloat {
        16 + CGFloat(depth) * 20
    }

    private var nodeRow: some View {
        HStack(spacing: 8) {
            // 展开箭头 / 占位（叶子无箭头，但保留对齐）
            if hasChildren {
                Button {
                    toggleExpand()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 20)
            }

            // 图标
            Image(systemName: NoteRow.icon(for: note.type))
                .foregroundColor(NoteRow.iconColor(for: note.type))
                .frame(width: 22)

            // 标题：容器点击切换展开；叶子点击进阅读页
            if hasChildren {
                Button {
                    toggleExpand()
                } label: {
                    Text(note.title.isEmpty ? "（无标题）" : note.title)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(destination: NoteDetailView(note: note)) {
                    Text(note.title.isEmpty ? "（无标题）" : note.title)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private func toggleExpand() {
        if isExpanded {
            isExpanded = false
            return
        }
        isExpanded = true
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
