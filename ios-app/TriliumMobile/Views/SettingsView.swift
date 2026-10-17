import SwiftUI
import UIKit

/// 设置页：连接信息 / 退出登录 / 应用内更新（检查更新 → 下载 IPA → 系统分享面板选 TrollStore）
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var update = UpdateStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var serverVersion = ""
    @State private var pendingShareVersion: String? = nil

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
                        settings.logout()
                        AppLogger.shared.log("退出登录后：isLoggedIn=\(settings.isLoggedIn), token 长度 \(settings.token.count)")
                        dismiss()
                        AppLogger.shared.log("已调用 dismiss() 关闭设置面板")
                    }
                }

                Section("更新") {
                    HStack {
                        Text("当前版本")
                        Spacer()
                        Text("v\(UpdateChecker.currentAppVersion)")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    if case .updateAvailable(_, let latest, _, _) = update.result {
                        HStack {
                            Text("新版本")
                            Spacer()
                            Text("v\(latest)").font(.footnote).foregroundColor(.blue)
                        }
                    }

                    Button(action: { Task { await update.checkNow() } }) {
                        HStack {
                            Text("检查更新")
                            Spacer()
                            if update.isChecking { ProgressView() }
                        }
                    }
                    .disabled(update.isChecking)

                    if let result = update.result {
                        updateSection(for: result)
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
            .onChange(of: update.downloadState) { state in
                // 用户点了安装、下载完成 → 自动弹分享面板
                if let ver = pendingShareVersion, case .downloaded(let f) = state {
                    pendingShareVersion = nil
                    presentShare(fileURL: f, version: ver)
                }
            }
            .task {
                await update.autoCheckIfNeeded()
                if let info = try? await ETAPIClient.shared.appInfo() {
                    serverVersion = info.appVersion ?? ""
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func updateSection(for result: UpdateCheckResult) -> some View {
        switch result {
        case .upToDate:
            Text("已是最新版本").font(.footnote).foregroundColor(.secondary)

        case .updateAvailable(_, let latest, let releaseURL, _):
            Section {
                Button(action: install) {
                    installButtonLabel(latest: latest)
                }
                .disabled(isDownloading)

                if case .downloading(let received, let total) = update.downloadState {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: total.map { Double(received) / Double($0) } ?? 0)
                        Text("下载中 \(fmtKB(received))\(total.map { " / \(fmtKB($0))" } ?? "")")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                } else if case .downloaded = update.downloadState {
                    Text("安装包已就绪，点「安装」弹出系统面板选 TrollStore")
                        .font(.footnote).foregroundColor(.secondary)
                }

                if let url = releaseURL {
                    Link("打开发布页", destination: url).font(.footnote)
                }
            }

        case .failed(let message):
            Text("检查失败：\(message)").font(.footnote).foregroundColor(.red)
        }
    }

    @ViewBuilder
    private func installButtonLabel(latest: String) -> some View {
        if case .downloading = update.downloadState {
            Text("下载中…").frame(maxWidth: .infinity)
        } else if case .downloaded = update.downloadState {
            Text("安装 v\(latest)（已下载）").frame(maxWidth: .infinity)
        } else {
            Text("下载并安装 v\(latest)").frame(maxWidth: .infinity)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = update.downloadState { return true }
        return false
    }

    /// 安装：若已下载直接分享；否则先下载再分享（原生 UIActivityViewController）
    private func install() {
        guard case .updateAvailable(_, let latest, _, let ipaURL) = update.result,
              let url = ipaURL else { return }

        if case .downloaded(let fileURL) = update.downloadState {
            presentShare(fileURL: fileURL, version: latest)
            return
        }
        // 标记「用户点了安装」，下载完成后由 onChange 自动弹分享面板
        pendingShareVersion = latest
        update.startDownload(latest: latest, ipaURL: url)
    }

    private func presentShare(fileURL: URL, version: String) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let vc = scene.windows.first?.rootViewController else { return }
        // 找最顶层的 controller 来 present
        var top = vc
        while let p = top.presentedViewController { top = p }
        IPAShare.share(fileURL: fileURL, title: "Trilium v\(version)", from: top)
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
