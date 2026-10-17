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

// MARK: - 更新包落地位置

/// IPA 存放位置：Caches/TriliumUpdate/Trilium-<version>.ipa（跨启动保留）
enum UpdateFileStore {
    static func destinationURL(version: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("TriliumUpdate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }
}

// MARK: - 更新状态与后台下载

/// 更新状态机（全 App 共用一份，页面销毁不影响）
enum UpdatePhase: Equatable {
    case idle
    case checking
    case downloading(received: Int64, total: Int64)
    case ready(version: String, fileURL: URL)
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// 更新中心（全 App 唯一实例）。
///
/// 为什么不是一个页面的下载任务（用户实测踩过的坑）：
///   1. 页面一销毁任务就跟着没了 → 进度归零、白下
///   2. 普通（非后台）会话在 App 被挂起后会被系统掐掉，回来只能从 0 重下
/// 所以这里：
///   - 下载挂在 **background URLSession** 上，App 切后台/被挂起照样传，
///     传完系统还会唤醒 App 收结果（需 AppDelegate 转交 completionHandler）
///   - 状态写 UserDefaults，重开 App 先恢复「下载中 62%」，再和后台上活着的任务对账
final class UpdateCenter: NSObject, ObservableObject {
    static let shared = UpdateCenter()

    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var latestVersion: String?
    @Published private(set) var lastCheckedAt: Date?

    /// AppDelegate 转交的系统后台会话回调
    var backgroundCompletionHandler: (() -> Void)?

    private let sessionIdentifier = "com.hhxxc.trilium.ipa-download"
    private let stateKey = "trilium.updater.state"
    private let lastCheckKey = "trilium.updater.lastCheck"

    private var session: URLSession!
    private var currentTask: URLSessionDownloadTask?
    private var versionByTask: [Int: String] = [:]
    private var lastDownloadURL: String?
    private var checking = false
    private var lastPersist = Date.distantPast
    private var uiBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    /// 落盘的状态（跨启动、跨页面）
    private struct Persisted: Codable {
        var version: String
        var received: Int64
        var total: Int64
        var filePath: String?
        var isReady: Bool
        var urlString: String?
    }

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // App 被系统回收后，下载完成仍然把 App 拉起来交付事件
        cfg.sessionSendsLaunchEvents = true
        // 用户主动要更新 → 立刻下，不要等 Wi-Fi/充电（discretionary 会无限期拖延）
        cfg.isDiscretionary = false
        cfg.allowsCellularAccess = true
        cfg.timeoutIntervalForRequest = 30
        cfg.httpMaximumConnectionsPerHost = 1

        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)

        lastCheckedAt = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        restore()
        attachToLiveTasks()
        AppLogger.shared.log("更新中心就绪，恢复状态：\(describe(phase))")
    }

    // MARK: 状态落盘

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        latestVersion = p.version.isEmpty ? nil : p.version
        lastDownloadURL = p.urlString

        if p.isReady, let path = p.filePath, FileManager.default.fileExists(atPath: path) {
            phase = .ready(version: p.version, fileURL: URL(fileURLWithPath: path))
            return
        }
        if p.received > 0 && p.total > 0 {
            phase = .downloading(received: p.received, total: p.total)
        }
    }

    private func persist() {
        let p: Persisted
        switch phase {
        case .downloading(let r, let t):
            p = Persisted(version: latestVersion ?? "", received: r, total: t,
                          filePath: nil, isReady: false, urlString: lastDownloadURL)
        case .ready(let v, let u):
            let size = UpdateFileStore.size(of: u)
            p = Persisted(version: v, received: size, total: size,
                          filePath: u.path, isReady: true, urlString: lastDownloadURL)
        case .idle, .checking, .failed:
            p = Persisted(version: latestVersion ?? "", received: 0, total: 0,
                          filePath: nil, isReady: false, urlString: lastDownloadURL)
        }
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: stateKey)
        }
    }

    /// 统一在主线改状态（@Published 必须在主线程）
    private func setPhase(_ p: UpdatePhase) {
        DispatchQueue.main.async {
            self.phase = p
            self.persist()
        }
    }

    // MARK: 与后台会话里还活着的任务对账

    private func attachToLiveTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let live = tasks.compactMap { $0 as? URLSessionDownloadTask }.first
            DispatchQueue.main.async {
                guard let task = live else {
                    // 记录说「下载中」但任务已经死了（例如上次被强制退出）→ 重启下载
                    if case .downloading = self.phase,
                       let v = self.latestVersion,
                       let s = self.lastDownloadURL,
                       let url = URL(string: s) {
                        AppLogger.shared.log("发现残留进度但任务已不存在，重新下载 v\(v)")
                        self.startDownload(version: v, url: url)
                    }
                    return
                }
                self.currentTask = task
                let v = self.latestVersion ?? ""
                self.versionByTask[task.taskIdentifier] = v
                self.phase = .downloading(received: task.countOfBytesReceived,
                                          total: task.countOfBytesExpectedToReceive)
                self.persist()
                AppLogger.shared.log("接管后台下载任务 v\(v)（\(task.countOfBytesReceived) 字节）")
            }
        }
    }

    // MARK: 对外动作

    /// 启动时静默检查：有新版就直接后台下载，全程不打扰用户
    func silentCheck(minInterval: TimeInterval = 300) async {
        if checking { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < minInterval { return }
        // 正在下载就别插一脚
        if phase.isDownloading, currentTask != nil { return }

        checking = true
        await MainActor.run {
            if self.phase == .idle {
                self.phase = .checking
                self.persist()
            }
        }

        let r = await UpdateChecker.checkAppUpdate()
        checking = false

        // await 之后不保证还在主线程 → 回主线改 @Published
        await MainActor.run {
            self.lastCheckedAt = Date()
            UserDefaults.standard.set(self.lastCheckedAt, forKey: self.lastCheckKey)
            self.apply(r)
        }
    }

    /// 落实检查结果（主线程）
    private func apply(_ r: UpdateCheckResult) {
        switch r {
        case .updateAvailable(_, let latest, _, let ipaURL):
            latestVersion = latest
            // 包里已经有了 → 直接待安装，不重复下
            if let existing = UpdateFileStore.existingDownload(version: latest) {
                phase = .ready(version: latest, fileURL: existing)
                persist()
                AppLogger.shared.log("本地已有 v\(latest) 安装包，待安装")
                return
            }
            guard let url = ipaURL else { phase = .idle; persist(); return }
            if phase.isDownloading, currentTask != nil { return }
            startDownload(version: latest, url: url)

        case .upToDate:
            if phase.isReady { return }   // 已下好的包留着，用户可能还没装
            phase = .idle
            latestVersion = nil
            persist()

        case .failed(let msg):
            AppLogger.shared.log("静默检查更新失败: \(msg)")
            if phase.isReady || phase.isDownloading { return }
            phase = .failed(msg)
            persist()
        }
    }

    /// 用户点「检查更新」：忽略节流，立即查
    func checkNow() async {
        await MainActor.run { self.lastCheckedAt = nil }
        await silentCheck(minInterval: 0)
    }

    /// 开始后台下载（重复调用会替换旧任务）
    func startDownload(version: String, url: URL) {
        currentTask?.cancel()
        latestVersion = version
        lastDownloadURL = url.absoluteString
        phase = .downloading(received: 0, total: 0)
        persist()
        AppLogger.shared.log("后台下载开始: v\(version) ← \(url.host ?? "?")")

        var req = URLRequest(url: url)
        req.setValue("TriliumMobile", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        versionByTask[task.taskIdentifier] = version
        currentTask = task
        task.resume()
        beginUIBackgroundTask()
    }

    func cancelDownload() {
        currentTask?.cancel()
        currentTask = nil
        phase = .idle
        persist()
        AppLogger.shared.log("用户取消更新下载")
    }

    /// 已下载的安装包（若有）
    var readyFileURL: URL? {
        if case .ready(_, let url) = phase { return url }
        return nil
    }

    func describe(_ p: UpdatePhase) -> String {
        switch p {
        case .idle: return "idle"
        case .checking: return "checking"
        case .downloading(let r, let t): return "downloading \(r)/\(t)"
        case .ready(let v, _): return "ready v\(v)"
        case .failed(let m): return "failed \(m)"
        }
    }

    // 让 App 在后台多活一会儿把收尾工作做完（真正的传输由后台会话负责）
    private func beginUIBackgroundTask() {
        endUIBackgroundTask()
        uiBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ipa-download") { [weak self] in
            self?.endUIBackgroundTask()
        }
    }

    private func endUIBackgroundTask() {
        guard uiBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(uiBackgroundTask)
        uiBackgroundTask = .invalid
    }
}

// MARK: - URLSession 代理（后台会话）

extension UpdateCenter: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let now = Date()
        let shouldPersist = now.timeIntervalSince(lastPersist) > 1.0
        if shouldPersist {
            lastPersist = now
            DispatchQueue.main.async {
                self.phase = .downloading(received: totalBytesWritten, total: total)
                self.persist()
            }
        } else {
            DispatchQueue.main.async {
                self.phase = .downloading(received: totalBytesWritten, total: total)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let version = versionByTask[downloadTask.taskIdentifier] ?? (latestVersion ?? "")
        guard !version.isEmpty else {
            setPhase(.failed("内部错误：丢失版本号"))
            return
        }
        let dest = UpdateFileStore.destinationURL(version: version)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
        } catch {
            setPhase(.failed("保存安装包失败：\(error.localizedDescription)"))
            return
        }
        // 防反代返回 HTML 错误页：校验 zip 魔数 PK
        var ok = false
        if let fh = try? FileHandle(forReadingFrom: dest) {
            defer { try? fh.close() }
            ok = ((try? fh.read(upToCount: 2)) ?? Data()) == Data([0x50, 0x4B])
        }
        if !ok {
            try? fm.removeItem(at: dest)
            setPhase(.failed("下载内容不是有效的 IPA"))
            return
        }
        AppLogger.shared.log("后台下载完成: v\(version) \(UpdateFileStore.size(of: dest)) 字节")
        setPhase(.ready(version: version, fileURL: dest))
        endUIBackgroundTask()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        // 任务失败但本地已有完整包 → 当作完成
        if let v = latestVersion, let existing = UpdateFileStore.existingDownload(version: v) {
            setPhase(.ready(version: v, fileURL: existing))
            return
        }
        AppLogger.shared.log("后台下载失败: \(error.localizedDescription)")
        setPhase(.failed(error.localizedDescription))
    }

    /// 后台会话事件全部交付完毕：把系统的 completionHandler 还回去
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let h = self.backgroundCompletionHandler {
                self.backgroundCompletionHandler = nil
                h()
            }
            self.endUIBackgroundTask()
        }
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
