import SwiftUI

/// 根视图：未登录 → 登录页；已登录 → 主界面（列表优先，有道云风格）。
/// 监听会话过期通知（服务端重启导致 token 失效），自动踢回登录页。
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if settings.isLoggedIn {
                MainView()
            } else {
                LoginView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
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
