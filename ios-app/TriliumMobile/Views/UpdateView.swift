import SwiftUI
import UIKit

/// 「软件更新」常驻页。
///
/// 下载不在这个页面里跑，而在 `UpdateCenter` 的后台会话里：
/// 关掉这个页面、切到别的 App、锁屏、甚至把 App 划掉，传输都不会中断，
/// 回来（或重开 App）自动接上进度 —— 这正是用户要的「静默下载 + 常驻」。
struct UpdateView: View {
    @ObservedObject private var updater = UpdateCenter.shared
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.17, green: 0.61, blue: 0.56)

    private var currentVersion: String { UpdateChecker.currentAppVersion }

    private var progress: Double? {
        if case .downloading(let received, let total) = updater.phase, total > 0 {
            return min(1, Double(received) / Double(total))
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                statusCard
                actionArea
                Text("下载使用系统后台传输：切到别的 App、锁屏、关掉这个页面都会继续；重开 App 会自动接上进度，不用从头再来。")
                    .font(.caption)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("软件更新")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear {
            // 进页面时如果还没查过，就主动查一次（已经在下载则不打扰）
            if case .idle = updater.phase {
                Task { await updater.silentCheck(minInterval: 0) }
            }
        }
    }

    // MARK: - 卡片

    private var headerCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(0.14))
                .frame(width: 54, height: 54)
                .overlay(
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(accent)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Trilium Mobile").font(.system(size: 16, weight: .semibold))
                Text("当前版本 v\(currentVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if let latest = updater.latestVersion, latest != currentVersion {
                    Text("最新版本 v\(latest)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.phase {
            case .idle:
                statusLine(icon: "checkmark.circle.fill", color: .green,
                           title: "没有可用更新", detail: "已是最新版本")

            case .checking:
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.9)
                    Text("正在检查更新…").font(.system(size: 14)).foregroundColor(.secondary)
                }

            case .downloading(let received, let total):
                HStack(alignment: .firstTextBaseline) {
                    Text(percentText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(accent)
                        .monospacedDigit()
                    Spacer()
                    Text(sizeText(received: received, total: total))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                if let p = progress {
                    ProgressView(value: p)
                        .tint(accent)
                } else {
                    ProgressView().tint(accent)
                }
                statusLine(icon: "arrow.down.circle", color: accent,
                           title: "后台下载中", detail: "可以离开这个页面，进度不会丢")

            case .ready(let version, let url):
                statusLine(icon: "checkmark.seal.fill", color: .green,
                           title: "v\(version) 安装包已就绪",
                           detail: "\(sizeText(received: UpdateFileStore.size(of: url), total: 0)) · 点下方按钮安装")
                Button {
                    install(version: version, fileURL: url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.up")
                        Text("安装 v\(version)")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent))
                }
                .buttonStyle(.plain)

            case .failed(let msg):
                statusLine(icon: "exclamationmark.triangle.fill", color: .orange,
                           title: "下载/检查失败", detail: msg)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var actionArea: some View {
        VStack(spacing: 10) {
            if updater.phase.isDownloading {
                Button {
                    updater.cancelDownload()
                } label: {
                    Text("取消下载")
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await updater.checkNow() }
            } label: {
                HStack(spacing: 6) {
                    if case .checking = updater.phase {
                        ProgressView().scaleEffect(0.7)
                    }
                    Text("立即检查更新")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(accent)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 小组件

    private func statusLine(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
    }

    private var percentText: String {
        guard let p = progress else { return "下载中" }
        return "\(Int(p * 100))%"
    }

    private func sizeText(received: Int64, total: Int64) -> String {
        let r = fmtBytes(received)
        return total > 0 ? "\(r) / \(fmtBytes(total))" : r
    }

    private func fmtBytes(_ n: Int64) -> String {
        if n >= 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1024 / 1024) }
        if n >= 1024 { return "\(n / 1024) KB" }
        return "\(n) B"
    }

    private func install(version: String, fileURL: URL) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first?.rootViewController else { return }
        var top = root
        while let p = top.presentedViewController { top = p }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        IPAShare.share(fileURL: fileURL, title: "Trilium v\(version)", from: top)
    }
}
