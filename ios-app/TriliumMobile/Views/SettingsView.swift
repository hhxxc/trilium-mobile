import SwiftUI
import UIKit

/// 设置页：连接信息 / 退出登录 / 应用内更新（检查更新 → 下载 IPA → 系统分享面板选 TrollStore）
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var updater = UpdateCenter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion = ""
    @State private var cacheSize: Int64 = -1 // -1 = 未测量

    var body: some View {
        NavigationView {
            Form {
                Section("连接") {
                    HStack {
                        Text("服务器")
                        Spacer()
                        Text(settings.server).font(.footnote).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    if !serverVersion.isEmpty {
                        HStack {
                            Text("服务端版本")
                            Spacer()
                            Text(serverVersion).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }

                Section {
                    Button("退出登录", role: .destructive) {
                        AppLogger.shared.log("点击退出登录：token 长度 \(settings.token.count)")
                        // 不在这里 logout/dismiss：实测 sheet 内 dismiss() 与根视图条件切换
                        // 竞争会导致面板残留。发信号让 MainView（sheet 的持有者）显式关闭
                        NotificationCenter.default.post(name: .performLogout, object: nil)
                    }
                }

                Section("安全") {
                    if AppSettings.canAuthenticate {
                        Toggle("Face ID / 密码锁", isOn: $settings.lockEnabled)
                        // 开着时：切到后台即锁定，回前台需认证
                        if settings.lockEnabled {
                            Text("切换到后台后需 Face ID（或设备密码）解锁")
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    } else {
                        Text("此设备未设置 Face ID / 触控 ID / 密码，无法启用应用锁")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                }

                Section("离线缓存") {
                    HStack {
                        Text("缓存大小")
                        Spacer()
                        Text(cacheSize < 0 ? "…" : fmtKB(cacheSize))
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    Button("清除缓存", role: .destructive) {
                        NoteCache.shared.clearAll()
                        cacheSize = 0
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        AppLogger.shared.log("已清除离线缓存")
                    }
                }

                Section("更新") {
                    HStack {
                        Text("当前版本")
                        Spacer()
                        Text("v\(UpdateChecker.currentAppVersion)")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    // 更新是独立常驻页：下载在后台会话里跑，这个页面关掉也不影响
                    NavigationLink(destination: UpdateView()) {
                        HStack {
                            Text("软件更新")
                            Spacer()
                            Text(updateSummary)
                                .font(.footnote)
                                .foregroundColor(updateSummaryColor)
                        }
                    }
                }

                Section("诊断日志") {
                    Button("复制操作日志") { copyLog() }
                    if !AppLogger.shared.entries.isEmpty {
                        ForEach(AppLogger.shared.entries.suffix(20), id: \.self) { line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task {
                if let info = try? await ETAPIClient.shared.appInfo() {
                    serverVersion = info.appVersion ?? ""
                }
                cacheSize = NoteCache.shared.totalSize()
            }
        }
        .navigationViewStyle(.stack)
    }

    /// 更新区的右侧摘要（下载中显示百分比，就绪显示待安装）
    private var updateSummary: String {
        switch updater.phase {
        case .idle: return "已是最新"
        case .checking: return "检查中…"
        case .downloading(let received, let total):
            guard total > 0 else { return "下载中…" }
            return "下载中 \(Int(Double(received) / Double(total) * 100))%"
        case .ready(let version, _): return "v\(version) 待安装"
        case .failed: return "失败"
        }
    }

    private var updateSummaryColor: Color {
        switch updater.phase {
        case .downloading, .ready: return Color(red: 0.17, green: 0.61, blue: 0.56)
        case .failed: return .orange
        default: return .secondary
        }
    }

    private func fmtKB(_ n: Int64) -> String {
        if n >= 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
        return "\(n / 1024) KB"
    }

    private func copyLog() {
        let text = AppLogger.shared.entries.joined(separator: "\n")
        UIPasteboard.general.string = text
        AppLogger.shared.log("已复制操作日志（\(AppLogger.shared.entries.count) 条）")
    }
}
