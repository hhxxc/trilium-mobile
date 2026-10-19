import SwiftUI
import UIKit

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
    private let accent = Theme.accent

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部信息条：存到哪 + 字数
                HStack(spacing: 6) {
                    Image(systemName: "tray.full").font(.system(size: 11))
                    Text("存入 收件箱").font(.footnote)
                    Spacer()
                    Text("\(text.count) 字").font(.footnote).monospacedDigit()
                }
                .foregroundColor(Color(UIColor.secondaryLabel))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()

                // 输入区：无边框多行输入 + 占位提示
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("记点什么…\n第一行会作为标题")
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
                        HStack(spacing: 6) {
                            if busy { ProgressView().scaleEffect(0.7).tint(.white) }
                            Text(busy ? "保存中…" : "保存")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 40)
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
                    Button("取消") {
                        // 先收键盘再收面板：键盘和 sheet 同时收会互相抢动画，显得卡
                        inputFocused = false
                        dismiss()
                    }
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
