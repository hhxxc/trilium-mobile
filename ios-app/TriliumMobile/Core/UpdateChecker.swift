import Foundation
import Combine
import UIKit

/// 更新检测结果
enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, releaseURL: URL?, ipaURL: URL?)
    case failed(message: String)
}

/// 版本更新检测器（抄巢记 UpdateChecker 成熟实现，纯原生 URLSession）。
///
/// 关键点（踩过的坑）：
///   - 并行查两个来源（NAS 清单 + GitHub Releases），取版本号较大者
///   - NAS 清单 ipaUrl 指向自有域名，国内秒下；GitHub 直链仅兜底
///   - 版本号必须是三段语义版本（x.y.z），避免四段/前导零污染比较
enum UpdateChecker {
    static let repo = AppConfig.repo
    static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases")!

    /// 本机 App 版本号（CFBundleShortVersionString，CI 构建时注入真实版本）
    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 清单地址（NAS 自有域名，与旧网页壳共用同一条无鉴权路由）
    /// ① manifest-trilium.ipa —— 内容是 JSON、后缀 .ipa → 服务端 text/plain 下发，
    ///    避开原生层对 application/json 的强制解析坑
    /// ② latest-trilium.json —— 老地址兜底
    static let manifestURLs: [String] = [
        "https://ezbookx.x.ddnsto.com/api/nestkeep/manifest-trilium.ipa",
        "https://ezbookx.x.ddnsto.com/api/nestkeep/latest-trilium.json",
    ]

    private struct Manifest: Decodable {
        let version: String?
        let ipaUrl: String?
        let releaseUrl: String?
    }

    private struct LatestInfo {
        let version: String
        let releaseURL: URL?
        let ipaURL: URL?
    }

    /// 查询最新版本并比对：并行查 NAS 清单 + GitHub，取较大版本
    static func checkAppUpdate() async -> UpdateCheckResult {
        let current = currentAppVersion

        async let backend = queryBackend()
        async let github = queryGitHub()
        let b = await backend
        let g = await github

        let candidates = [b, g].compactMap { $0 }
        guard let best = candidates.max(by: { compareVersion($0.version, $1.version) < 0 }) else {
            return .failed(message: "无法获取版本信息，请稍后重试")
        }

        if compareVersion(best.version, current) > 0 {
            return .updateAvailable(current: current, latest: best.version,
                                    releaseURL: best.releaseURL, ipaURL: best.ipaURL)
        }
        return .upToDate(current: current)
    }

    private static func queryBackend() async -> LatestInfo? {
        for urlStr in manifestURLs {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.timeoutInterval = 15

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                AppLogger.shared.log("更新源失败: \(urlStr.prefix(60))")
                continue
            }
            // 直接按 JSON 解码；若被劫持成 HTML 会解码失败 → 换下一个源
            guard let m = try? JSONDecoder().decode(Manifest.self, from: data),
                  let v = m.version, isSemanticVersion(normalizeVersion(v)) else {
                AppLogger.shared.log("更新源响应无效: \(urlStr.prefix(60)) \(data.count)字节")
                continue
            }
            AppLogger.shared.log("更新源命中: \(urlStr.prefix(60)) → v\(v)")
            return LatestInfo(
                version: normalizeVersion(v),
                releaseURL: m.releaseUrl.flatMap { URL(string: $0) },
                ipaURL: m.ipaUrl.flatMap { URL(string: $0) }
            )
        }
        return nil
    }

    private static func queryGitHub() async -> LatestInfo? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=100") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("TriliumMobile", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var best: LatestInfo?
        for r in releases {
            if (r["draft"] as? Bool) == true { continue }
            if (r["prerelease"] as? Bool) == true { continue }
            guard let tag = r["tag_name"] as? String, !tag.isEmpty else { continue }
            let v = normalizeVersion(tag)
            guard isSemanticVersion(v) else { continue }
            let releaseURL = (r["html_url"] as? String).flatMap { URL(string: $0) }
            let ipaURL = ipaAssetURL(from: r)
            let info = LatestInfo(version: v, releaseURL: releaseURL, ipaURL: ipaURL)
            if let cur = best {
                if compareVersion(info.version, cur.version) > 0 { best = info }
            } else {
                best = info
            }
        }
        return best
    }

    private static func ipaAssetURL(from release: [String: Any]) -> URL? {
        guard let assets = release["assets"] as? [[String: Any]] else { return nil }
        for a in assets {
            if let name = a["name"] as? String, name.lowercased().hasSuffix(".ipa"),
               let urlStr = a["browser_download_url"] as? String, let u = URL(string: urlStr) {
                return u
            }
        }
        return nil
    }

    // MARK: - IPA 下载候选（自有域名优先，GitHub 兜底）

    /// 构造按优先级排序的下载候选：自有域名直链最前，GitHub 原链最后
    static func downloadCandidates(ipaURL: URL) -> [URL] {
        var candidates: [URL] = []
        func push(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }
        push(ipaURL)
        return candidates
    }

    // MARK: - 版本号工具

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// 是否形如 x.y.z 的三段语义版本（无前导零）
    static func isSemanticVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        for p in parts {
            if p.isEmpty || !p.allSatisfy({ $0.isNumber }) { return false }
            if p.count > 1 && p.first == "0" { return false }
        }
        return true
    }

    static func compareVersion(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}

/// IPA 下载状态
enum IPADownloadState: Equatable {
    case idle
    case downloading(received: Int64, total: Int64?)
    case downloaded(fileURL: URL)
    case failed(message: String)
}

/// IPA 文件下载器：URLSession downloadTask 委托，支持进度回调
final class IPAFileDownloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    init(onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onProgress = onProgress
    }

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 下载目标：Caches/TriliumUpdate/Trilium-<version>.ipa（跨启动保留）
    static func destinationURL(version: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("TriliumUpdate", isDirectory: true)
        return dir.appendingPathComponent("Trilium-\(version).ipa")
    }

    /// 已有完整包（文件存在且为 PK 头）
    static func existingDownload(version: String) -> URL? {
        let url = destinationURL(version: version)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64, size > 1024,
              let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 2)) ?? Data()
        return head == Data([0x50, 0x4B]) ? url : nil
    }

    func download(from url: URL, to destination: URL) async throws -> URL {
        self.destination = destination

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        // IPA 仅 ~320KB，正常几秒完成；90s 总超时足够，避免坏源挂太久卡「下载中 0 KB」
        cfg.timeoutIntervalForResource = 90
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.downloadTask(with: url)
        _ = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                self.continuation = cont
                task.resume()
            }
        }, onCancel: { task.cancel() })

        // 校验 HTTP 状态 + PK 头（防反代返回 HTML 错误页）
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: destination)
            throw DownloadError(message: "HTTP \(http.statusCode)")
        }
        if let fh = try? FileHandle(forReadingFrom: destination) {
            defer { try? fh.close() }
            let head = (try? fh.read(upToCount: 2)) ?? Data()
            if head != Data([0x50, 0x4B]) {
                try? FileManager.default.removeItem(at: destination)
                throw DownloadError(message: "下载内容不是有效的 IPA")
            }
        }
        return destination
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        onProgress(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination else {
            resume(with: .failure(DownloadError(message: "内部错误")))
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            resume(with: .success(destination))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resume(with: .failure(error))
    }

    private func resume(with result: Result<URL, Error>) {
        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        }
    }
}

/// 更新检查的可观察状态（供 SwiftUI 绑定）
@MainActor
final class UpdateStore: ObservableObject {
    static let shared = UpdateStore()

    @Published var isChecking = false
    @Published var result: UpdateCheckResult?
    @Published var downloadState: IPADownloadState = .idle
    @Published var serverVersion: String?

    private var downloader: IPAFileDownloader?
    private var downloadTaskRef: Task<Void, Never>?
    private var currentDownloadVersion: String?

    func checkNow() async {
        isChecking = true
        let r = await UpdateChecker.checkAppUpdate()
        result = r
        isChecking = false

        // 发现新版就自动后台下载，用户点「安装」时包已就绪
        if case .updateAvailable(_, let latest, _, let ipaURL) = r, let url = ipaURL {
            scheduleAutoDownload(latest: latest, ipaURL: url)
        }
    }

    func autoCheckIfNeeded() async {
        let key = "trilium.lastAutoUpdateCheck"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        if now - last < 5 * 60 { return }
        UserDefaults.standard.set(now, forKey: key)
        let r = await UpdateChecker.checkAppUpdate()
        if case .updateAvailable(_, let latest, _, let ipaURL) = r, let url = ipaURL {
            result = r
            scheduleAutoDownload(latest: latest, ipaURL: url)
        }
    }

    func scheduleAutoDownload(latest: String, ipaURL: URL) {
        if let existing = IPAFileDownloader.existingDownload(version: latest) {
            currentDownloadVersion = latest
            downloadState = .downloaded(fileURL: existing)
            return
        }
        if case .downloading = downloadState { return }
        if case .downloaded = downloadState { return }
        startDownload(latest: latest, ipaURL: ipaURL)
    }

    func startDownload(latest: String, ipaURL: URL) {
        downloadTaskRef?.cancel()
        currentDownloadVersion = latest
        downloadState = .downloading(received: 0, total: nil)
        AppLogger.shared.log("更新下载开始: v\(latest)")

        let candidates = UpdateChecker.downloadCandidates(ipaURL: ipaURL)
        AppLogger.shared.log("下载源(\(candidates.count)个): \(candidates.map { $0.host }.joined(separator: ", "))")
        let destination = IPAFileDownloader.destinationURL(version: latest)
        let downloader = IPAFileDownloader { [weak self] received, total in
            Task { @MainActor in
                guard let self, !Task.isCancelled else { return }
                if case .downloading = self.downloadState {
                    self.downloadState = .downloading(received: received, total: total)
                }
            }
        }
        self.downloader = downloader

        downloadTaskRef = Task { [weak self] in
            var lastError: Error = IPAFileDownloader.DownloadError(message: "未知错误")
            for candidate in candidates {
                if Task.isCancelled { return }
                AppLogger.shared.log("尝试下载源: \(candidate.absoluteString.prefix(80))")
                do {
                    let fileURL = try await downloader.download(from: candidate, to: destination)
                    guard !Task.isCancelled else { return }
                    AppLogger.shared.log("更新下载完成: v\(latest)")
                    self?.downloadState = .downloaded(fileURL: fileURL)
                    return
                } catch {
                    if Task.isCancelled { return }
                    AppLogger.shared.log("下载源失败: \(candidate.host) \(error.localizedDescription)")
                    lastError = error
                }
            }
            guard !Task.isCancelled else { return }
            AppLogger.shared.log("更新下载最终失败: \(lastError.localizedDescription)")
            self?.downloadState = .failed(message: "\(lastError.localizedDescription)（已尝试全部 \(candidates.count) 个下载源）")
        }
    }

    func cancelDownload() {
        downloadTaskRef?.cancel()
        downloadTaskRef = nil
        downloader = nil
        if case .downloading = downloadState { downloadState = .idle }
    }
}

/// 系统分享面板（原生 UIActivityViewController，交给 TrollStore 安装）
@MainActor
enum IPAShare {
    /// 弹出系统分享面板，用户选 TrollStore 安装
    static func share(fileURL: URL, title: String, from vc: UIViewController) {
        let items: [Any] = [fileURL]
        let avc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        avc.completionWithItemsHandler = { _, _, _, _ in }
        vc.present(avc, animated: true)
    }
}
