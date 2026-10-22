import SwiftUI
import UIKit

/// 目录内浏览：把这个目录下的笔记平铺出来（子目录在前，笔记按修改时间倒序）。
///
/// 为什么需要它：目录树只能一层层展开，笔记一多就变成「点开、再点开、找不到」。
/// 这里一屏看完一个目录，顺带支持**批量收藏 / 批量移动**（整理时最常用的两个动作）。
struct FolderNotesView: View {
    let folder: Note

    @State private var notes: [Note] = []
    @State private var loading = true
    @State private var errorMsg: String?
    @State private var toast: String?

    /// 底部条（选择条）让位高度，和首页 NoteListView 的常量保持一致。
    /// iOS 15 的 safeAreaInset 不 inset List，只能在列表末尾自己补。
    private static let bottomBarClearance: CGFloat = 64

    // 批量整理
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var showMove = false
    /// 单条删除确认（confirmationDialog 绑定）
    @State private var noteToDelete: Note?
    /// 单条移动 / 克隆的目标选择
    @State private var organizeTarget: OrganizeTarget?

    private let accent = Theme.accent

    var body: some View {
        List {
            if loading && notes.isEmpty {
                HStack { Spacer(); ProgressView("加载中…"); Spacer() }
                    .listRowSeparator(.hidden)
            } else if notes.isEmpty {
                Text(errorMsg ?? "这个目录还没有笔记")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(notes) { n in
                    row(for: n)
                }
            }
            // ⚠️ iOS 15 的 safeAreaInset 对 **List** 不生效（对 ScrollView 才生效）：
            //   底部选择条一出现就会压住最后一行，补一段等高空白行兜底
            //   （和首页 NoteListView 是同一处坑，高度也对齐它的工具条）。
            if selecting && !selected.isEmpty {
                Color.clear
                    .frame(height: Self.bottomBarClearance)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .hideScrollIndicators()
        .navigationTitle(folder.title.isEmpty ? "目录" : folder.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !notes.isEmpty {
                    Button(selecting ? "完成" : "选择") {
                        selecting.toggle()
                        if !selecting { selected.removeAll() }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting && !selected.isEmpty { selectionBar }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
                    .overlay(Capsule().stroke(Color(UIColor.separator).opacity(0.5), lineWidth: 0.5))
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showMove) {
            MoveTargetPicker(noteTitle: "\(selected.count) 条笔记") { parentId, title in
                showMove = false
                Task { await moveSelected(to: parentId, title: title) }
            }
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
        .task { await load() }
        .onAppear {
            // 从抽屉树里点进来时，抽屉不会自己消失（它挂在 NoteListView 的覆盖层上）
            NotificationCenter.default.post(name: .noteDetailAppeared, object: nil)
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(for n: Note) -> some View {
        if selecting {
            Button {
                if selected.contains(n.noteId) { selected.remove(n.noteId) }
                else { selected.insert(n.noteId) }
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected.contains(n.noteId) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 19))
                        .foregroundColor(selected.contains(n.noteId) ? accent : Color(UIColor.tertiaryLabel))
                    NoteRow(note: n)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden, edges: .all)
        } else {
            browseLink(for: n)
                // 系统分隔线贴行左边缘、和标题不对齐 → 隐藏，改由 NoteRow 自己画
                .listRowSeparator(.hidden, edges: .all)
                // 与首页列表保持一致的手势：左滑=收藏/删除，右滑=移动。
                // ⚠️ edge 指动作出现在行的哪一侧 —— `.trailing` = 左滑露出，
                //    `.leading` = 右滑露出（2026-10-20 首页踩过这个坑，别写反）
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { Task { await toggleBookmark(n) } } label: {
                        Label(n.isBookmarked ? "取消收藏" : "收藏",
                              systemImage: n.isBookmarked ? "star.slash" : "star")
                    }
                    .tint(.orange)

                    Button(role: .destructive) { noteToDelete = n } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { organizeTarget = OrganizeTarget(note: n, action: .move) } label: {
                        Label("移动", systemImage: "folder")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button { Task { await toggleBookmark(n) } } label: {
                        Label(n.isBookmarked ? "取消收藏" : "收藏",
                          systemImage: n.isBookmarked ? "star.slash" : "star")
                    }
                    Button { organizeTarget = OrganizeTarget(note: n, action: .move) } label: {
                        Label("移动到…", systemImage: "folder")
                    }
                    Button { organizeTarget = OrganizeTarget(note: n, action: .clone) } label: {
                        Label("克隆到…", systemImage: "square.on.square")
                    }
                    Divider()
                    Button(role: .destructive) { noteToDelete = n } label: {
                        Label("删除笔记", systemImage: "trash")
                    }
                }
        }
    }

    /// 非选择态的行：子目录继续下钻，笔记进阅读页
    @ViewBuilder
    private func browseLink(for n: Note) -> some View {
        if n.isContainer {
            NavigationLink(destination: FolderNotesView(folder: n)) { NoteRow(note: n) }
        } else {
            // 带上当前目录：笔记若被克隆到多处，上一篇/下一篇要按**这条分支**算
            NavigationLink(destination: NoteDetailView(note: n, parentContextId: folder.noteId)) { NoteRow(note: n) }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button { Task { await bookmarkSelected() } } label: {
                Label("收藏", systemImage: "star").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { showMove = true } label: {
                Label("移动", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button { selected.removeAll() } label: {
                Text("清空").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 数据

    private func load() async {
        loading = true
        errorMsg = nil
        do {
            let kids = try await ETAPIClient.shared.childNotes(of: folder.noteId)
            notes = kids.sorted { a, b in
                if a.isContainer != b.isContainer { return a.isContainer }
                return (a.modifiedDate ?? .distantPast) > (b.modifiedDate ?? .distantPast)
            }
        } catch {
            errorMsg = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }

    private func bookmarkSelected() async {
        var done = 0
        for n in notes where selected.contains(n.noteId) {
            guard n.bookmarkAttributeId == nil else { done += 1; continue }
            do {
                try await ETAPIClient.shared.createAttribute(noteId: n.noteId, name: "bookmarked")
                done += 1
            } catch {
                AppLogger.shared.log("批量收藏失败[\(n.title)]：\(error.localizedDescription)")
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast("已收藏 \(done) 条")
        selected.removeAll()
        selecting = false
        await load()
    }

    private func moveSelected(to parentId: String, title: String) async {
        var done = 0
        for n in notes where selected.contains(n.noteId) {
            // 移到原目录 = 没有变化，跳过
            guard folder.noteId != parentId else { continue }
            do {
                // ⚠️ `from` 必须用**当前目录**，不能用 `n.parentNoteIds?.first`：
                //   一条笔记可能同时挂在多个目录（克隆），first 未必是当前这个，
                //   拿错就会把另一个目录里的分支删掉 —— 表现为「笔记在别处凭空消失」。
                try await ETAPIClient.shared.moveNote(n.noteId, from: folder.noteId, to: parentId)
                done += 1
            } catch {
                AppLogger.shared.log("批量移动失败[\(n.title)]：\(error.localizedDescription)")
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast("已移动 \(done) 条到「\(title)」")
        selected.removeAll()
        selecting = false
        await load()
    }

    // MARK: - 单条操作（收藏 / 移动 / 删除）

    /// 收藏 / 取消收藏（写/删一个 bookmarked 标签），写完拉一次列表刷新状态
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
                // ⚠️ `from` 必须用**当前目录**（见 moveSelected 里的注释）：
                //   笔记可能被克隆到多处，first 未必是当前这条分支。
                try await ETAPIClient.shared.moveNote(target.note.noteId, from: folder.noteId, to: parentId)
            case .clone:
                try await ETAPIClient.shared.addBranch(noteId: target.note.noteId, parentNoteId: parentId)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("已\(target.action.verb)到「\(title)」")
            TreeChildCache.clear()   // 树结构变了，目录子级缓存作废
            await load()
        } catch {
            showToast("操作失败：\(error.localizedDescription)")
        }
    }

    private func deleteNote() async {
        guard let note = noteToDelete else { return }
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
        TreeChildCache.clear()
        noteToDelete = nil
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }
}
