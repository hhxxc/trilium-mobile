import SwiftUI

/// 选择目标目录（移动 / 克隆共用）。
/// 只做一件事：让用户在目录树里点一下「选这里」，回车把 (parentId, title) 回调给首页。
struct MoveTargetPicker: View {
    let noteTitle: String
    var onPick: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rootChildren: [Note] = []
    @State private var loading = true
    @State private var errorMsg = ""

    private let accent = Theme.accent

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        pick("root", "我的笔记")
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tray.full.fill")
                                .foregroundColor(accent)
                            Text("我的笔记（根目录）")
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                }

                Section {
                    if loading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.8)
                            Text("加载目录…").font(.footnote).foregroundColor(.secondary)
                        }
                    } else if !errorMsg.isEmpty {
                        Text(errorMsg).font(.footnote).foregroundColor(.secondary)
                    } else if rootChildren.isEmpty {
                        Text("没有可选目录").font(.footnote).foregroundColor(.secondary)
                    } else {
                        ForEach(rootChildren) { n in
                            MoveTargetRow(note: n, depth: 0, onPick: pick)
                        }
                    }
                } header: {
                    Text("把「\(noteTitle)」放到：")
                        .font(.caption)
                        .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("选择目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task {
                if rootChildren.isEmpty { await loadRoot() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func pick(_ id: String, _ title: String) {
        onPick(id, title)
        dismiss()
    }

    private func loadRoot() async {
        loading = true
        do {
            rootChildren = try await ETAPIClient.shared.childNotes(of: "root")
            errorMsg = ""
        } catch {
            errorMsg = "加载失败：\(error.localizedDescription)"
        }
        loading = false
    }
}

/// 目录选择里的一行：点行展开/收起子级，「选这里」确定目标。
private struct MoveTargetRow: View {
    let note: Note
    let depth: Int
    var onPick: (String, String) -> Void

    @State private var expanded = false
    @State private var children: [Note]? = nil

    private var childIds: [String] { note.childNoteIds ?? [] }
    private let accent = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    guard !childIds.isEmpty else { return }
                    expanded.toggle()
                    if expanded && children == nil { Task { await loadChildren() } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: childIds.isEmpty ? "circle"
                                          : (expanded ? "chevron.down" : "chevron.right"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(UIColor.tertiaryLabel))
                            .frame(width: 14)
                        NoteIconBadge(type: note.type, size: 24)
                        Text(note.title.isEmpty ? "（无标题）" : note.title)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(TreeRowButtonStyle())

                Button {
                    onPick(note.noteId, note.title.isEmpty ? "（无标题）" : note.title)
                } label: {
                    Text("选这里")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, CGFloat(depth) * 16)

            if expanded, let children {
                ForEach(children) { c in
                    MoveTargetRow(note: c, depth: depth + 1, onPick: onPick)
                }
            }
        }
    }

    private func loadChildren() async {
        children = (try? await ETAPIClient.shared.childNotes(of: note.noteId)) ?? []
    }
}
