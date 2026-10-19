import SwiftUI
import UIKit

/// 新建笔记（仿印象笔记版式）：
/// 自定义头部（取消 / 收起键盘 / 保存）—— 不用系统 toolbar，根除「收起键盘 + 收面板」动画互顶
/// 目录选择行 —— 点开 MoveTargetPicker 选存入位置（默认收件箱）
/// 独立大标题 —— 标题、正文分开输入，不再靠「第一行当标题」
/// 底部工具条 —— 文本/代码类型切换 + 字数
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var noteType = "text"
    @State private var busy = false
    @State private var errorMsg = ""
    @State private var showPicker = false
    @State private var showDiscardConfirm = false
    // 默认目标：收件箱（ensureInbox 解析），选定后记 (id, name)
    @State private var targetId: String? = nil
    @State private var targetName = "收件箱"
    @FocusState private var titleFocused: Bool
    @FocusState private var inputFocused: Bool
    var onSaved: () async -> Void

    private var trimmed: String {
        (title + text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private let accent = Theme.accent

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            // 目录选择行：存入哪里 + 类型提示
            Button {
                inputFocused = false
                titleFocused = false
                showPicker = true
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 13))
                    Text("存入 \(targetName)")
                        .font(.footnote)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider()

            // 输入区：大标题 + 正文
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        if title.isEmpty {
                            Text("标题")
                                .font(.title3.weight(.semibold))
                                .foregroundColor(Color(UIColor.placeholderText))
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $title)
                            .font(.title3.weight(.semibold))
                            .focused($titleFocused)
                            .submitLabel(.next)
                            .onSubmit { inputFocused = true }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("开始写点什么…")
                                .font(.body)
                                .lineSpacing(4)
                                .foregroundColor(Color(UIColor.placeholderText))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $text)
                            .font(.body)
                            .lineSpacing(4)
                            .focused($inputFocused)
                            // 抵消 TextEditor 自带内边距，让占位文字对齐
                            .padding(.horizontal, -5)
                            .padding(.vertical, -6)
                            .frame(minHeight: 160)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !errorMsg.isEmpty {
                Text(errorMsg)
                    .font(.footnote).foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }

            Divider()
            bottomBar
        }
        .background(Color(UIColor.systemBackground))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { titleFocused = true }
        }
        .sheet(isPresented: $showPicker) {
            MoveTargetPicker(noteTitle: "新笔记") { id, name in
                targetId = id
                targetName = name
            }
            .navigationViewStyle(.stack)
        }
        .confirmationDialog("丢弃这篇笔记？", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("丢弃", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    // MARK: - 头部：取消 / 收起键盘 / 保存
    private var headerBar: some View {
        HStack(spacing: 18) {
            Button("取消") {
                if trimmed.isEmpty {
                    dismiss()
                } else {
                    // 有内容先确认，防误触丢稿
                    inputFocused = false
                    titleFocused = false
                    showDiscardConfirm = true
                }
            }
            .font(.body)
            .foregroundColor(accent)
            .buttonStyle(.plain)

            Spacer()

            // 收起键盘（仿印象笔记头部图标）
            Button {
                inputFocused = false
                titleFocused = false
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 20))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("收起键盘")

            Button {
                save()
            } label: {
                if busy {
                    ProgressView().tint(accent)
                } else {
                    Text("保存").font(.body.weight(.semibold))
                }
            }
            .foregroundColor(trimmed.isEmpty ? Color(UIColor.systemGray3) : accent)
            .buttonStyle(.plain)
            .disabled(busy || trimmed.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - 底部：类型切换 + 字数
    private var bottomBar: some View {
        HStack(spacing: 8) {
            typeChip("text", "文本", "doc.text")
            typeChip("code", "代码", "curlybraces")
            Spacer()
            Text("\(text.count) 字")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(Color(UIColor.tertiaryLabel))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func typeChip(_ type: String, _ label: String, _ icon: String) -> some View {
        let active = noteType == type
        return Button {
            noteType = type
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.footnote.weight(active ? .semibold : .regular))
            }
            .foregroundColor(active ? accent : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(active ? accent.opacity(0.12) : Color(UIColor.secondarySystemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    /// 标题、正文独立输入；正文按空行切段落包 <p>
    private func save() {
        var t = title.trimmingCharacters(in: .whitespaces)
        let body = text
        guard !t.isEmpty || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if t.isEmpty { t = "无标题" }
        if t.count > 120 { t = String(t.prefix(120)) }
        let content = noteType == "code"
            ? body.trimmingCharacters(in: .newlines)
            : Self.html(fromPlain: body)

        busy = true
        Task {
            do {
                let parentId: String
                if let targetId {
                    parentId = targetId
                } else {
                    parentId = try await ETAPIClient.shared.ensureInbox()
                }
                _ = try await ETAPIClient.shared.createNote(
                    parentNoteId: parentId, title: t, content: content, type: noteType)
                errorMsg = ""
            } catch {
                // 断网/失败：入离线队列（队列模型只带标题，正文不入队）
                NoteCache.shared.enqueue(PendingOp(kind: "create", id: UUID().uuidString,
                    noteId: "", title: t, content: nil, parentNoteId: nil,
                    createdAt: Date()))
                AppLogger.shared.log("新建已入离线队列: \(t)")
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
