import SwiftUI

/// 根视图：未登录 → 登录页；已登录 → 主界面（Tab）。
/// 监听会话过期通知（服务端重启导致 token 失效），自动踢回登录页。
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if settings.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            settings.logout()
        }
    }
}

/// 主界面：4 个 Tab（最近 / 笔记树 / 搜索 / 设置）
struct MainTabView: View {
    var body: some View {
        TabView {
            RecentView()
                .tabItem { Label("最近", systemImage: "clock") }
            TreeView()
                .tabItem { Label("笔记树", systemImage: "list.bullet") }
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
