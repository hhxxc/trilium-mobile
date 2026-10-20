import SwiftUI

/// 根视图：未登录 → 登录页；已登录 → 主界面（列表优先，有道云风格）。
/// 监听会话过期通知（服务端重启导致 token 失效），自动踢回登录页。
///
/// ⚠️ 登录态校验（2026-10-17 加固）：
///   ETAPI token 存 UserDefaults，同 Bundle ID 覆盖安装会残留旧 token；
///   且 token 会随服务端重启失效。故启动时**必须用 token 实测一次**，
///   有效才进主界面，否则清 token 回登录页 —— 不能只看本地有没有 token 值。
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var validating = true
    /// 生物识别锁：进后台即锁，回前台需认证（设置页可开关）
    @State private var isLocked = false
    /// 上次认证失败的原因（展示在锁定遮罩上，别让用户对着屏幕猜）
    @State private var authError: String?

    var body: some View {
        Group {
            if validating {
                ProgressView("校验登录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if settings.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .overlay {
            if isLocked {
                lockCover
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            AppLogger.shared.log("收到 sessionExpired 通知，执行 logout")
            settings.logout()
        }
        .task {
            // 先自愈连接：公网证书过期 / 出门回家换网时，主备地址自动互换
            if settings.isLoggedIn { await ServerProbe.ensureReachable() }
            await validateToken()
            // 冷启动也要上锁：以前只有「切过后台」才锁，重新打开 App 是不验的
            if settings.lockEnabled {
                isLocked = true
                authenticate()
            }
            // 启动补交离线积压（有网才成功，失败留队列）
            await NoteCache.shared.flushPendingOps()
            // 启动即静默检查更新：有新版直接在后台下，不弹任何东西
            if settings.isLoggedIn {
                Task { await UpdateCenter.shared.silentCheck() }
            }
        }
        // 进后台立即上锁（锁屏/切走都算）；回前台弹认证 + 补交离线积压
        .onChange(of: scenePhase) { phase in
            // ⚠️ 进后台的戳**不能**被 validating 挡掉：那时「进后台」是既成事实，
            //    不打戳 → 下次启动一律误报「疑似闪退」（2026-10-20 修）。
            //    validating 只挡「回前台弹认证」这类交互，不挡记录。
            if phase == .background {
                CrashBreadcrumb.markBackground()
            }
            guard !validating else { return }
            if phase == .background {
                if settings.lockEnabled { isLocked = true }
            } else if phase == .active {
                if settings.lockEnabled, isLocked { authenticate() }
                Task { await NoteCache.shared.flushPendingOps() }
                // 回前台补一次连接自愈（换网/证书恢复都能自动切回）
                if settings.isLoggedIn {
                    Task { await ServerProbe.ensureReachable() }
                }
                // 回前台顺带补一次更新检查（内部有 5 分钟节流，不会频繁打服务端）
                if settings.isLoggedIn {
                    Task { await UpdateCenter.shared.silentCheck() }
                }
            }
        }
        .onChange(of: settings.isLoggedIn) { loggedIn in
            AppLogger.shared.log("isLoggedIn 变为 \(loggedIn)")
        }
        // 分享扩展回传（trilium://quick-note?text=...）：直接进离线队列，断网也能收
        .onOpenURL { url in
            guard url.scheme == "trilium", url.host == "quick-note",
                  let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let text = comps.queryItems?.first(where: { $0.name == "text" })?.value,
                  !text.isEmpty else { return }
            NoteCache.shared.enqueue(PendingOp(kind: "create", id: UUID().uuidString,
                noteId: "", title: text, content: nil, parentNoteId: nil, createdAt: Date()))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            AppLogger.shared.log("分享收藏已入队：\(text.prefix(30))…")
            if settings.isLoggedIn {
                Task { await NoteCache.shared.flushPendingOps() }
            }
        }
    }

    /// 锁定遮罩：挡住全部内容，防后台截屏泄露
    private var lockCover: some View {
        ZStack {
            Color(UIColor.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44))
                    .foregroundColor(Theme.accent)
                Text("已锁定").font(.headline)
                if let authError {
                    Text(authError)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                Button("解锁") {
                    authError = nil
                    authenticate()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func authenticate() {
        settings.authenticate { ok, reason in
            isLocked = !ok
            // 失败原因要露出来：以前失败了界面上只有一句「已锁定」，
            // 用户看到的是「点了没反应」，实际可能是没录 Face ID / 被锁定 / 缺用途声明
            authError = ok ? nil : (reason ?? "认证失败")
        }
    }

    /// 启动时用本地 token 实测一次：只有服务端**明确 401** 才清 token 回登录页。
    /// ⚠️ 网络故障 / TLS 证书过期 / 服务端临时不可用 一律**保留登录态**，
    ///    先进主界面走本地缓存 —— 否则穿透证书一过期，用户就被无故登出（实测踩过）。
    private func validateToken() async {
        defer { validating = false }
        guard settings.isLoggedIn else {
            AppLogger.shared.log("启动校验：无 token，直接进登录页")
            return
        }
        do {
            // getNote("root") 明确需要鉴权：token 失效返回 401 → 抛错；
            // 能读到 root 说明 token 真实有效
            _ = try await ETAPIClient.shared.getNote("root")
            AppLogger.shared.log("启动校验：token 有效，进主界面")
        } catch let e as APIError {
            if case .http(let status) = e, status == 401 {
                AppLogger.shared.log("启动校验 401：token 已失效，清 token 回登录页")
                settings.logout()
            } else {
                AppLogger.shared.log("启动校验遇服务端异常（\(e.localizedDescription)），保留登录态离线进入")
            }
        } catch {
            AppLogger.shared.log("启动校验遇网络/证书异常（\(error.localizedDescription)），保留登录态离线进入")
        }
    }
}

/// 主界面：单一 NavigationView，列表优先（有道云风格）。
/// 首页=笔记列表；右上角只有「设置」；右下角悬浮「+」速记。
/// ⚠️ 树的入口刻意只留两处，各司其职：
///   底部「目录」胶囊 = 切到目录页正式浏览；左上/左滑抽屉 = 快速跳转（不改变当前浏览模式）。
///   这里原来还有个「文件夹」图标弹 TreeView sheet，和上面两个完全重叠，已删。
struct MainView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false
    /// 首页抽屉（目录树）是否打开。状态放在这里是因为导航栏按钮由 NavigationView
    /// 渲染、层级高于 NoteListView 内容区 —— 抽屉打开时必须由这里把按钮收掉，
    /// 否则「设置」图标会浮在遮罩和抽屉之上（穿模且能点穿）。
    @State private var drawerOpen = false

    var body: some View {
        NavigationView {
            NoteListView(drawerOpen: $drawerOpen)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                        .opacity(drawerOpen ? 0 : 1)
                        .disabled(drawerOpen)
                        .allowsHitTesting(!drawerOpen)
                        .accessibilityHidden(drawerOpen)
                    }
                }
                .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .navigationViewStyle(.stack)
        // 登出信号：sheet 的 dismiss() 在「sheet+根视图条件切换」组合下会与视图销毁竞争
        // 导致面板残留（实测点三次都不关）。这里由持有 sheet 状态的 MainView 显式关闭，
        // 等 sheet 关闭动画结束后再清 token 切换根视图，时序才稳。
        .onReceive(NotificationCenter.default.publisher(for: .performLogout)) { _ in
            AppLogger.shared.log("MainView 收到登出信号：关闭所有面板")
            showSettings = false
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000) // 等 sheet 关闭动画
                AppLogger.shared.log("面板已关，执行 settings.logout()")
                settings.logout()
            }
        }
        // token 失效被踢（服务端重启）时同样要先关面板，否则面板残留挡住登录页
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            AppLogger.shared.log("MainView 收到会话过期：关闭所有面板")
            showSettings = false
        }
    }
}
