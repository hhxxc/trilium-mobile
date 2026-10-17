import SwiftUI

@main
struct TriliumMobileApp: App {
    // 全 App 唯一的设置实例（单例），所有视图通过 @ObservedObject 引用，
    // 避免 @StateObject 包装单例造成的「多实例/通知断裂」隐患。
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
        }
    }
}
