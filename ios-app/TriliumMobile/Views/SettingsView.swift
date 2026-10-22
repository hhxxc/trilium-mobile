import SwiftUI
import UIKit

/// 设置页：连接信息 / 退出登录 / 应用内更新（检查更新 → 下载 IPA → 系统分享面板选 TrollStore）
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var updater = UpdateCenter.shared
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion = ""
    @State private var cacheSize: Int64 = -1 // -1 = 未测量
    @State private var probeMsg = ""
    /// 服务器地址编辑草稿（10-20 起支持在设置页直接改，不用再退出登录）
    @State private var serverDraft = ""
    @State private var serverMsg = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("服务器")
                        TextField(AppConfig.defaultServer, text: $serverDraft)
                            .font(.footnote)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .textContentType(.URL)
                            .onSubmit { commitServer() }
                    }
                    // 全角脏字符肉眼看不见（粘贴带入），必须亮出来——这是 DNS 解析失败的元凶（10-20 事故）
                    if AppSettings.serverAddressHasJunk(serverDraft) {
                        Text("地址里混入了全角符号，保存时会自动清洗为半角")
                            .font(.caption).foregroundColor(.orange)
                    }
                    if serverDraft != settings.server {
                        Button("保存服务器地址") { commitServer() }
                            .disabled(!AppSettings.isValidServerAddress(serverDraft))
                    }
                    if !serverMsg.isEmpty {
                        Text(serverMsg).font(.caption).foregroundColor(.secondary)
                    }
                    // 主备地址：当前地址不通时（证书过期 / 换网）自动互换，token 不变
                    HStack {
                        Text("备用地址")
                        TextField(AppConfig.defaultBackupServer, text: Binding(
                            get: { settings.serverBackup },
                            set: { settings.serverBackup = $0 }))
                            .font(.footnote)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .onSubmit {
                                let cleaned = AppSettings.sanitizeServerAddress(settings.serverBackup)
                                if cleaned != settings.serverBackup { settings.serverBackup = cleaned }
                            }
                    }
                    if AppSettings.serverAddressHasJunk(settings.serverBackup) {
                        Text("备用地址里混入了全角符号，回车时会自动清洗")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Button {
                        Task {
                            probeMsg = "检测中…"
                            let ok = await ServerProbe.ensureReachable()
                            probeMsg = ok ? "当前地址可用：\(settings.server)"
                                          : "两个地址都连不上，检查网络后重试"
                        }
                    } label: {
                        Text("检测并自动切换")
                    }
                    if !probeMsg.isEmpty {
                        Text(probeMsg).font(.caption).foregroundColor(.secondary)
                    }
                    if !serverVersion.isEmpty {
                        HStack {
                            Text("服务端版本")
                            Spacer()
                            Text(serverVersion).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text("当前地址不通时会自动切到备用地址（例如内网穿透证书过期、出门回家换网）。token 跟地址无关，切换不需要重新登录。")
                }

                Section {
                    Button("退出登录", role: .destructive) {
                        AppLogger.shared.log("点击退出登录：token 长度 \(settings.token.count)")
                        // 不在这里 logout/dismiss：实测 sheet 内 dismiss() 与根视图条件切换
                        // 竞争会导致面板残留。发信号让 MainView（sheet 的持有者）显式关闭
                        NotificationCenter.default.post(name: .performLogout, object: nil)
                    }
                }

                Section("外观") {
                    // ⚠️ 分段控件放 Form 内容区，不放 toolbar：iOS 15 下 toolbar 内的
                    //    segmented Picker 不渲染（老坑，见 iOS 15 兼容红线）
                    Picker("主题", selection: Binding(
                        get: { settings.themeMode },
                        set: { settings.themeMode = $0 })) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("正文是网页渲染的，切换后阅读页配色会同步；「跟随系统」按系统深色设置走")
                        .font(.footnote).foregroundColor(.secondary)
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
                serverDraft = settings.server
                if let info = try? await ETAPIClient.shared.appInfo() {
                    serverVersion = info.appVersion ?? ""
                }
                // 目录枚举（几百个缓存文件）放后台：以前在主线程跑，进设置页会卡一下
                cacheSize = await Task.detached(priority: .utility) {
                    NoteCache.shared.totalSize()
                }.value
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
        case .downloading, .ready: return Theme.accent
        case .failed: return .orange
        default: return .secondary
        }
    }

    /// 保存服务器地址：清洗 → 校验 → 落库（updateServer 会处理清缓存/主备互换）
    private func commitServer() {
        let cleaned = AppSettings.sanitizeServerAddress(serverDraft)
        guard AppSettings.isValidServerAddress(cleaned) else {
            serverMsg = "地址无效：需要 http:// 或 https:// 开头的完整地址"
            return
        }
        serverDraft = cleaned
        let changed = cleaned != settings.server
        settings.updateServer(cleaned)
        serverMsg = changed ? "已保存并切换到 \(cleaned)（本地缓存已清）" : "已保存"
        AppLogger.shared.log("设置页修改服务器地址 → \(cleaned)")
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
