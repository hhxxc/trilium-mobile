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

    // 批量整理
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var showMove = false

    private let accent = Color(red: 0.17, green: 0.61, blue: 0.56)

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
                        .listRowSeparator(.hidden, edges: .all)
                }
            }
        }
        .listStyle(.plain)
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
        } else if n.isContainer {
            NavigationLink(destination: FolderNotesView(folder: n)) {
                NoteRow(note: n)
            }
        } else {
            NavigationLink(destination: NoteDetailView(note: n)) {
                NoteRow(note: n)
            }
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
        .font(.system(size: 14))
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

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }
}
