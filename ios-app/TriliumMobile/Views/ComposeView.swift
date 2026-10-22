import SwiftUI
import UIKit

/// 新建笔记（版式仿用户参考截图：日期当标题 + 面包屑选目录 + 保存做底部主按钮）：
/// 头部：取消 + 面包屑（存入目录，点击换）—— 不用系统 toolbar
/// 编辑区：标题默认今天日期（可改），右上角收起键盘；正文撑满余下空间
/// 底部工具条：文本/代码类型切换 + 字数 + 「保存」主按钮（蓝底白字，仿截图右下角）
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    /// 标题默认 = 今天日期（截图样式「2026年10月20日」），用户可改
    @State private var title = ComposeView.defaultDateTitle()
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

    /// 是否有实际内容：标题被改过（≠ 默认日期）或正文非空。
    /// 标题默认带日期，不能拿「标题+正文非空」判断——否则一打开就「有内容」，取消也弹丢弃确认。
    private var hasContent: Bool {
        let bodyEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let titleChanged = title.trimmingCharacters(in: .whitespaces) != Self.defaultDateTitle()
        return !bodyEmpty || titleChanged
    }
    private let accent = Theme.accent

    /// 「2026年10月20日」格式的今天日期
    static func defaultDateTitle() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            // 输入区：标题（右上角收起键盘）+ 正文撑满余下空间。
            // TextEditor 自带滚动，外层不需要 ScrollView——撑满才有截图里「一大片书写区」的感觉。
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ZStack(alignment: .leading) {
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
                    Spacer(minLength: 8)
                    // 标题行右侧的收起键盘（对应截图右上角的展开钮位置）
                    Button {
                        inputFocused = false
                        titleFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 20))
                            .foregroundColor(accent)
                            // iOS 15 红线：热区 ≥44pt
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableIconStyle())
                    .accessibilityLabel("收起键盘")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

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
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
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
            // 光标直接落正文（截图如此）；标题已是日期，不需要先改标题
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { inputFocused = true }
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

    // MARK: - 头部：取消 + 面包屑（存入目录）
    private var headerBar: some View {
        HStack(spacing: 12) {
            Button("取消") {
                if hasContent {
                    // 有改动先确认，防误触丢稿
                    inputFocused = false
                    titleFocused = false
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
            .font(.body)
            .foregroundColor(accent)
            .buttonStyle(.plain)

            Spacer()

            // 面包屑：存入哪里（仿截图「📁 我的文件夹 >」），点击换目录
            Button {
                inputFocused = false
                titleFocused = false
                showPicker = true
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                    Text(targetName)
                        .font(.footnote)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择存入目录")

            Spacer()

            // 与「取消」等宽的透明占位，让面包屑视觉居中
            Text("取消").font(.body).foregroundColor(.clear)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - 底部：类型切换 + 字数 + 保存（主按钮）
    private var bottomBar: some View {
        HStack(spacing: 8) {
            typeChip("text", "文本", "doc.text")
            typeChip("code", "代码", "curlybraces")
            Spacer()
            Text("\(text.count) 字")
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(Color(UIColor.tertiaryLabel))
            // 保存：蓝底白字主按钮（仿截图工具条右下角），从头部挪到这里
            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().tint(.white)
                    }
                    Text("保存").font(.body.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(hasContent ? accent : Color(UIColor.systemGray3))
                )
            }
            .buttonStyle(.plain)
            .disabled(busy || !hasContent)
            .accessibilityLabel("保存笔记")
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
        // 标题默认是日期、恒非空，空不空看 hasContent（改过标题 或 正文非空）
        guard hasContent else { return }
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
                // 断网/失败：入离线队列（**正文和类型一起入队**，回来补交时建的是完整笔记，
                // 以前只带标题，离线速记的内容会整段丢失）
                NoteCache.shared.enqueue(PendingOp(kind: "create", id: UUID().uuidString,
                    noteId: "", title: t, content: content, noteType: noteType,
                    parentNoteId: targetId, createdAt: Date()))
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
