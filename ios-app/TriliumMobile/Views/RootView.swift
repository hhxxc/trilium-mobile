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
    @State private var validating = true

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
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            AppLogger.shared.log("收到 sessionExpired 通知，执行 logout")
            settings.logout()
        }
        .task { await validateToken() }
        .onChange(of: settings.isLoggedIn) { loggedIn in
            AppLogger.shared.log("isLoggedIn 变为 \(loggedIn)")
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
    }
}
