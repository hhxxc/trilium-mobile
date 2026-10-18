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

    /// 下载候选源，按「国内能不能秒通」排序（照抄巢记的结论：手机直连 github 大概率被墙，
    /// 表现不是快速失败而是**挂死到超时**，所以 GitHub 永远只能排最后兜底）：
    ///
    /// 1. 清单给的地址（NAS 域名直链，正常情况秒下）
    /// 2. **内网镜像**：清单域名整条链路挂了（证书过期 / 穿透故障）时，家里 Wi-Fi 直接打 NAS 内网端口
    /// 3. GitHub Releases 原链（有代理或能直连的设备才走通，保底）
    static func downloadCandidates(ipaURL: URL, version: String?) -> [URL] {
        var candidates: [URL] = []
        func push(_ url: URL?) {
            guard let url, !candidates.contains(url) else { return }
            candidates.append(url)
        }

        // ⚠️ 候选源**不能只信清单给的 ipaURL**：
        //   版本信息可能来自 GitHub API（NAS 清单挂了的时候），此时 ipaURL 就是 github.com ——
        //   而手机直连 GitHub 是「挂死不报错」，表现就是永远「下载中 0 B」。
        //   所以永远先试我们自己的两条已知直链（NAS 公网 + 内网镜像），再把清单给的地址、
        //   GitHub 依次兜底。
        let fileName = ipaURL.lastPathComponent.isEmpty ? "trilium-mobile.ipa" : ipaURL.lastPathComponent
        push(URL(string: "https://ezbookx.x.ddnsto.com/api/nestkeep/\(fileName)"))
        push(lanMirrorURL(fileName: fileName))
        push(ipaURL)
        if let v = version, !v.isEmpty,
           let gh = URL(string: "https://github.com/\(repo)/releases/download/v\(v)/trilium-mobile.ipa") {
            push(gh)
        }
        return candidates
    }

    /// 内网镜像地址：只用**内网 IP** 拼（端口沿用 ezbookkeeping 的 9180）。
    /// ⚠️ 主备地址会自动互换，「备用地址」里可能是公网域名 —— 拿它拼 :9180 一定是错的，
    ///   所以这里做一次私网校验，再退回 AppConfig 里的默认内网地址。
    static func lanMirrorURL(fileName: String) -> URL? {
        guard !fileName.isEmpty else { return nil }
        for raw in [AppSettings.shared.serverBackup, AppConfig.defaultBackupServer] {
            guard let host = URL(string: raw)?.host, !host.isEmpty else { continue }
            let isPrivate = host.hasPrefix("192.168.") || host.hasPrefix("10.")
                || host.hasPrefix("172.") || host == "localhost"
            if isPrivate {
                return URL(string: "http://\(host):9180/api/nestkeep/\(fileName)")
            }
        }
        return nil
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

    /// 当前正在试的下载源（显示在更新页上：卡住时一眼看出卡在哪个域名）
    @Published private(set) var currentHost: String = ""
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
    /// 还没试过的下载源（第一个失败就换下一个）
    private var candidateQueue: [URL] = []
    private var lastDownloadURL: String?
    private var checking = false
    private var lastPersist = Date.distantPast
    private var uiBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - 后台会话不可用时的降级链（2026-10-18 实测补）
    //
    // 现象（用户日志铁证）：点更新后 **同一秒** 就报「下载源失败（unknown error）」，
    // 两个源都是。这不是网络问题，是任务根本没被创建——`NSURLErrorDomain -1`
    // （"unknown error"）几乎只出现在两种情况：
    //   - 后台会话的 nsurlsessiond 状态坏了（任务一创建就失败，重启设备能好）
    //   - 后台会话被别的进程/上次进程占用（-996）、被系统断开（-997）
    // 老办法（v1.2.x）用前台会话下载一直是好的，所以这里的策略是：
    //   后台 → 重建后台会话再试一次 → 还不行就降到前台会话下
    // 前台通道能正常下载（只是 App 被挂起会中断），至少不会彻底没法更新。

    private enum Channel: String {
        case background = "后台"
        case backgroundRebuilt = "后台(重建)"
        case foreground = "前台"
    }

    private var channel: Channel = .background
    /// 一旦确认后台通道在本机不可用，本次下载后续源直接用前台，不再重复撞墙
    private var preferForeground = false
    private var currentURL: URL?
    /// 懒创建的前台会话（只在后台通道确实不可用时才建）

    // MARK: 停滞看门狗 + 同源断点续传（照搬巢记的两条经验）
    /// 最后一个字节到达的时间。连不上/被墙的源不会报错，只会「安静地挂着」，
    /// 所以必须自己盯着——否则用户看到的是「0% 卡死」，而不是快速换源
    private var lastProgressAt = Date()
    private var stallWork: DispatchWorkItem?
    private var stallLimit: TimeInterval = 40
    /// 同一源内已经续传了几次（超过 2 次就换源，别在死源上磨）
    private var sourceResumeCount = 0
    /// 我们自己主动取消（换源/停表），用来和真正的失败区分
    private var intentionalCancel = false
    /// 20 秒一次的状态-任务对账巡检（防止「下载中」楔死）
    private var guardTimer: DispatchSourceTimer?
    /// 本次下载是否已经重建过会话（只重建一次，之后换源）
    private var sessionRebuilt = false

    /// 这些错误码属于「会话级故障」：换源没用，得换通道
    private static let sessionLevelCodes: Set<Int> = [
        NSURLErrorUnknown,                                  // -1  unknown error
        NSURLErrorBackgroundSessionInUseByAnotherProcess,    // -996
        NSURLErrorBackgroundSessionWasDisconnected,          // -997
    ]

    /// 失败冷却：同一版本刚失败过就不再被「静默检查」反复重下
    private var failedVersion: String?
    private var failedAt: Date?
    private let failureCooldown: TimeInterval = 10 * 60

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
        session = makeSession()

        lastCheckedAt = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        restore()
        attachToLiveTasks()
        startGuardTimer()
        AppLogger.shared.log("更新中心就绪，恢复状态：\(describe(phase))")
    }

    // MARK: - 巡检（与 UI 无关的兜底，防止状态机卡死）

    /// 每 20 秒把「界面上的状态」和「真实的下载任务」对一次账。
    /// ⚠️ 为什么要有它：之前几版都出现过「状态=下载中，但任务早没了」的楔死情况，
    ///   而所有恢复路径都挂在 UI 上（打开更新页 / 点检查更新），用户不点就永远卡着。
    ///   巡检不看 UI，只认事实 —— 状态说在下载却没有任务，就自己纠正。
    private func startGuardTimer() {
        guardTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler { [weak self] in self?.guardTick() }
        t.resume()
        guardTimer = t
    }

    private func guardTick() {
        // ① 说在下载，但没有活任务 → 重置并重新安排
        if phase.isDownloading, currentTask == nil {
            AppLogger.shared.log("巡检：状态为下载中但无任务 → 重置为空闲")
            phase = .idle
            persist()
            Task { await silentCheck(minInterval: 0, ignoreCooldown: true) }
            return
        }
        // ② 有任务但两分钟没有任何字节 → 兜底换源（正常情况看门狗 8~20s 就该动手了）
        if phase.isDownloading, currentTask != nil,
           Date().timeIntervalSince(lastProgressAt) > 120 {
            AppLogger.shared.log("巡检：120 秒无字节，放弃当前下载源")
            abandonCurrentSource()
        }
    }

    /// 下载会话：**普通会话**（不用 background）。
    ///
    /// ⚠️ 为什么彻底放弃 background 会话（两条都是实测/已知硬伤）：
    ///   ① TrollStore / ad-hoc 签名下 background 会话经常「建了但永远不回调」——
    ///      界面表现就是「下载中 0 B」，连错误都没有
    ///   ② 重装 App 后同名 identifier 可能还有残留，此时
    ///      `URLSessionConfiguration.background(withIdentifier:)` 会抛 NSException ——
    ///      Swift 接不住 → **直接闪退**
    /// 安装包只有 2 MB，普通会话几秒就下完；配合 beginBackgroundTask 足够撑过短暂切后台。
    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.allowsCellularAccess = true
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
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
                    guard case .downloading = self.phase else { return }
                    // 记录说「下载中」但任务已经死了（例如上次被强制退出）→ 重启下载
                    if let v = self.latestVersion,
                       let s = self.lastDownloadURL,
                       let url = URL(string: s) {
                        AppLogger.shared.log("发现残留进度但任务已不存在，重新下载 v\(v)")
                        self.startDownload(version: v, url: url)
                    } else {
                        // ⚠️ 历史状态残缺（没有可用 URL）：以前这里直接 return，
                        //   结果「下载中 0 B」永久卡死，点「立即检查更新」也救不回来（用户实测）。
                        //   现在重置成空闲，下一次静默检查会重新拉一遍。
                        AppLogger.shared.log("残留下载状态无法续上（缺 URL），重置为空闲")
                        self.phase = .idle
                        self.persist()
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
    func silentCheck(minInterval: TimeInterval = 300, ignoreCooldown: Bool = false) async {
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

        // await 之后不保证还在主线程 → 回主线改 @Published
        // ⚠️ 顺序要紧：先写 lastCheckedAt、再放开 checking。
        //   反过来会在两者之间留一个窗口，同一个界面连点几次就会连着查 5 次（用户日志实测过）。
        await MainActor.run {
            self.lastCheckedAt = Date()
            UserDefaults.standard.set(self.lastCheckedAt, forKey: self.lastCheckKey)
            self.apply(r, ignoreCooldown: ignoreCooldown)
            self.checking = false
        }
    }

    /// 落实检查结果（主线程）。`ignoreCooldown=true` 时（用户手动点检查）不看失败冷却。
    private func apply(_ r: UpdateCheckResult, ignoreCooldown: Bool = false) {
        switch r {
        case .updateAvailable(_, let latest, _, let ipaURL):
            latestVersion = latest
            // 包里已经有了 → 直接待安装，不重复下
            if let existing = UpdateFileStore.existingDownload(version: latest) {
                phase = .ready(version: latest, fileURL: existing)
                failedVersion = nil
                persist()
                AppLogger.shared.log("本地已有 v\(latest) 安装包，待安装")
                return
            }
            guard let url = ipaURL else { phase = .idle; persist(); return }
            if phase.isDownloading, currentTask != nil { return }
            // 同一版本刚失败过：冷却期内不再自动重下（否则每次静默检查都重来一遍，日志刷屏）
            if !ignoreCooldown, failedVersion == latest, let at = failedAt,
               Date().timeIntervalSince(at) < failureCooldown {
                AppLogger.shared.log("v\(latest) 上次下载失败，冷却中（剩余 \(Int(failureCooldown - Date().timeIntervalSince(at)))s），跳过自动重试")
                return
            }
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
        await silentCheck(minInterval: 0, ignoreCooldown: true)
    }

    /// 开始后台下载（重复调用会替换旧任务）。候选源按顺序试，失败自动换下一个。
    func startDownload(version: String, url: URL) {
        startDownload(version: version,
                      candidates: UpdateChecker.downloadCandidates(ipaURL: url, version: version))
    }

    func startDownload(version: String, candidates: [URL]) {
        stallWork?.cancel()
        currentTask?.cancel()
        latestVersion = version
        candidateQueue = candidates
        // ⚠️ 默认走**前台**会话：本 App 是 TrollStore / ad-hoc 签名，
        //   后台下载会话在这类签名下不可靠 —— 实测会出现「任务建了但永远 0 字节、
        //   连错误回调都没有」。前台会话就是读笔记用的同一套机制，已验证可用。
        //   包只有 2 MB 左右，几秒就完，配合 beginBackgroundTask 足以撑过短暂切后台。
        preferForeground = true
        channel = .foreground
        sourceResumeCount = 0
        phase = .downloading(received: 0, total: 0)
        persist()
        AppLogger.shared.log("开始下载 v\(version)，候选源 \(candidates.count) 个：\(candidates.map { $0.host ?? "?" }.joined(separator: " → "))")
        beginNextCandidate()
    }

    /// 试下一个候选源（换源时通道也回到默认）
    private func beginNextCandidate() {
        guard let url = candidateQueue.first else {
            finishAllCandidatesFailed()
            return
        }
        candidateQueue.removeFirst()
        channel = preferForeground ? .foreground : .background
        sourceResumeCount = 0     // 换了源，续传计数重来
        attempt(url)
    }

    /// 用当前通道发起一次下载
    private func attempt(_ url: URL) {
        currentURL = url
        currentHost = url.host ?? ""
        lastDownloadURL = url.absoluteString
        lastProgressAt = Date()
        AppLogger.shared.log("\(channel.rawValue)下载开始: v\(latestVersion ?? "?") ← \(url.host ?? "?")")

        var req = URLRequest(url: url)
        req.setValue("TriliumMobile", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        versionByTask[task.taskIdentifier] = latestVersion ?? ""
        currentTask = task
        task.resume()
        armStallWatchdog(for: url)
        beginUIBackgroundTask()
    }

    // MARK: - 停滞看门狗

    /// 盯住「多久没进来一个字节」。内网源给 8 秒（本地不通就是不通），
    /// 公网源给 20 秒（首字节一般 1-2 秒就到）。到点没数据就换下一个候选。
    private func armStallWatchdog(for url: URL) {
        stallWork?.cancel()
        let host = url.host ?? ""
        let isPrivate = host.hasPrefix("192.168.") || host.hasPrefix("10.") || host.hasPrefix("172.")
        // 内网 8 秒（本地不通就是不通），公网 20 秒（首字节一般 1-2 秒就到，等太久纯浪费）
        stallLimit = isPrivate ? 8 : 20
        scheduleStallCheck(url)
    }

    private func scheduleStallCheck(_ url: URL) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.currentURL == url, self.currentTask != nil else { return }
            let idle = Date().timeIntervalSince(self.lastProgressAt)
            if idle >= self.stallLimit {
                AppLogger.shared.log("下载源 \(Int(self.stallLimit)) 秒没数据（\(url.host ?? "?")），换下一个候选源")
                self.abandonCurrentSource()
            } else {
                self.scheduleStallCheck(url)
            }
        }
        stallWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// 放弃当前源：先标记「是我们主动砍的」，再取消任务，避免被当成真失败
    private func abandonCurrentSource() {
        intentionalCancel = true
        currentTask?.cancel()
        currentTask = nil
        if !candidateQueue.isEmpty {
            beginNextCandidate()
        } else {
            finishAllCandidatesFailed("下载超时：所有下载源都没有响应，请检查网络（家里可直连内网地址手动安装）")
        }
    }

    /// 同一源内用系统的 resumeData 续传（不换源）
    private func resumeDownload(from resumeData: Data, url: URL) {
        let task = session.downloadTask(withResumeData: resumeData)
        versionByTask[task.taskIdentifier] = latestVersion ?? ""
        currentTask = task
        lastProgressAt = Date()
        task.resume()
        armStallWatchdog(for: url)
    }

    /// 所有源都试完了：记失败 + 开冷却，别让静默检查每 30 秒再刷一遍
    private func finishAllCandidatesFailed(_ reason: String = "所有下载源都失败，请稍后重试") {
        stallWork?.cancel()
        failedVersion = latestVersion
        failedAt = Date()
        currentURL = nil
        currentHost = ""
        setPhase(.failed(reason))
    }

    /// 会话级故障：重建一次会话再试同一源；重建过还不行就交给上层换源
    private func escalateIfSessionLevelFailure(_ ns: NSError) -> Bool {
        guard ns.domain == NSURLErrorDomain,
              Self.sessionLevelCodes.contains(ns.code),
              let url = currentURL else { return false }
        guard !sessionRebuilt else { return false }
        sessionRebuilt = true
        AppLogger.shared.log("下载会话异常（错误码 \(ns.code)），重建会话后重试同一源")
        session.invalidateAndCancel()
        session = makeSession()
        attempt(url)
        return true
    }

    func cancelDownload() {
        stallWork?.cancel()
        currentTask?.cancel()
        currentTask = nil
        candidateQueue.removeAll()
        currentURL = nil
        currentHost = ""
        sourceResumeCount = 0
        failedVersion = nil
        failedAt = nil
        phase = .idle
        persist()
        AppLogger.shared.log("用户取消更新下载")
    }

    /// 用户点「重新开始下载」：清掉失败冷却与残留状态，立刻重来一遍
    func restartDownload() {
        failedVersion = nil
        failedAt = nil
        cancelDownload()
        Task { await silentCheck(minInterval: 0, ignoreCooldown: true) }
    }

    /// 自我修复：状态是「下载中」但根本没有活任务（进程重启 / 任务丢失）→ 重置后重查
    func recoverIfStuck() {
        guard phase.isDownloading, currentTask == nil else { return }
        AppLogger.shared.log("「下载中」但没有活任务，重置并重新检查")
        phase = .idle
        persist()
        Task { await silentCheck(minInterval: 0, ignoreCooldown: true) }
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
        lastProgressAt = now          // 看门狗靠这个判断「还有没有在动」
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
        stallWork?.cancel()           // 已经下完，停表
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
        AppLogger.shared.log("下载完成（\(channel.rawValue)）: v\(version) \(UpdateFileStore.size(of: dest)) 字节")
        DispatchQueue.main.async {
            self.candidateQueue.removeAll()
            self.currentURL = nil
            self.failedVersion = nil
            self.failedAt = nil
            self.preferForeground = false
        }
        setPhase(.ready(version: version, fileURL: dest))
        endUIBackgroundTask()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            // 我们自己砍的（看门狗换源 / 用户取消 / 重建会话）→ 上层已经接管，别再当失败处理
            DispatchQueue.main.async { self.intentionalCancel = false }
            return
        }
        DispatchQueue.main.async {
            // 任务失败但本地已有完整包 → 当作完成
            if let v = self.latestVersion, let existing = UpdateFileStore.existingDownload(version: v) {
                self.phase = .ready(version: v, fileURL: existing)
                self.failedVersion = nil
                self.persist()
                return
            }
            // 同一源内先断点续传（学巢记）：网络抖动导致的失败，续传比重下整包划算
            if let resume = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               self.sourceResumeCount < 2, let url = self.currentURL {
                self.sourceResumeCount += 1
                AppLogger.shared.log("同源断点续传（第 \(self.sourceResumeCount) 次）")
                self.resumeDownload(from: resume, url: url)
                return
            }
            // 会话级故障（-1 / -996 / -997）：换源没用，先换通道
            if self.escalateIfSessionLevelFailure(ns) { return }
            // 还有候选源（例如清单域名证书挂了、改走 GitHub）→ 自动换下一个
            if !self.candidateQueue.isEmpty {
                AppLogger.shared.log("下载源失败（\(ns.domain) \(ns.code)：\(error.localizedDescription)），切换下一个候选源")
                self.beginNextCandidate()
                return
            }
            AppLogger.shared.log("下载最终失败（\(ns.domain) \(ns.code)：\(error.localizedDescription)），\(Int(self.failureCooldown / 60)) 分钟内不再自动重试")
            // 给用户能照着做的提示，别把「unknown error」原样丢到界面上
            let userMsg: String
            if ns.domain == NSURLErrorDomain && Self.sessionLevelCodes.contains(ns.code) {
                userMsg = "系统下载服务异常（错误码 \(ns.code)），已自动换成前台方式重试仍失败。请重启手机后再试，或用内网地址手动安装"
            } else {
                userMsg = error.localizedDescription
            }
            self.finishAllCandidatesFailed(userMsg)
        }
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
