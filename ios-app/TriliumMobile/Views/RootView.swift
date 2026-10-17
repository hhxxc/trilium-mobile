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
            await validateToken()
            if settings.lockEnabled { authenticate() }
            // 启动补交离线积压（有网才成功，失败留队列）
            await NoteCache.shared.flushPendingOps()
        }
        // 进后台立即上锁（锁屏/切走都算）；回前台弹认证 + 补交离线积压
        .onChange(of: scenePhase) { phase in
            guard !validating else { return }
            if phase == .background {
                if settings.lockEnabled { isLocked = true }
            } else if phase == .active {
                if settings.lockEnabled, isLocked { authenticate() }
                Task { await NoteCache.shared.flushPendingOps() }
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
                    .foregroundColor(Color(red: 0.17, green: 0.61, blue: 0.56))
                Text("已锁定").font(.headline)
                Button("解锁") { authenticate() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func authenticate() {
        settings.authenticate { ok in
            isLocked = !ok  // 取消认证保持锁定，点「解锁」可重试
        }
    }

    /// 启动时用本地 token 实测一次：有效才放行，无效/过期则清 token 回登录页。
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
        } catch {
            AppLogger.shared.log("启动校验失败：\(error.localizedDescription)，清 token 回登录页")
            settings.logout()
        }
    }
}

/// 主界面：单一 NavigationView，列表优先（有道云风格）。
/// 首页=笔记列表；右上角入口到「树」与「设置」；右下角悬浮「+」速记。
struct MainView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showTree = false
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            NoteListView()
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button { showTree = true } label: {
                            Image(systemName: "folder")
                        }
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showTree) { TreeView() }
                .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .navigationViewStyle(.stack)
        // 登出信号：sheet 的 dismiss() 在「sheet+根视图条件切换」组合下会与视图销毁竞争
        // 导致面板残留（实测点三次都不关）。这里由持有 sheet 状态的 MainView 显式关闭，
        // 等 sheet 关闭动画结束后再清 token 切换根视图，时序才稳。
        .onReceive(NotificationCenter.default.publisher(for: .performLogout)) { _ in
            AppLogger.shared.log("MainView 收到登出信号：关闭所有面板")
            showSettings = false
            showTree = false
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
            showTree = false
        }
    }
}
