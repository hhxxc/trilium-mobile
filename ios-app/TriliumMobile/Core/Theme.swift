import SwiftUI
import UIKit

/// 设计 token 单点：主题色 / 遮罩等全局视觉常量统一从这里取。
///
/// 背景：主题青 `Color(red:0.17,0.61,0.56)` 曾散落在 6 个文件 14 处，
/// 想换个主题色或加个品牌色得全仓 grep；文字字号也有 50+ 处魔法数字，
/// 既不一致也不跟系统「动态字体」（大字号无障碍失效）。
/// 以后新增 UI 从这里取色，别再写魔法数字。
enum Theme {
    /// 主题青（Trilium 品牌色）：图标徽标 / 胶囊激活态 / 主按钮 / 链接强调共用
    static let accent = Color(red: 0.17, green: 0.61, blue: 0.56)

    /// 抽屉遮罩：暗色下加深，否则黑底上 0.28 的遮罩几乎看不出来
    static let scrim = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.50)
            : UIColor.black.withAlphaComponent(0.28)
    })
}

/// 隐藏宿主滚动视图的滚动指示条。
/// iOS 15 没有 `.scrollIndicators(.hidden)`（iOS 16+ 才有），
/// 用这个「背景探针」向上找 UIScrollView 再关掉竖向指示条。
/// 放在 `.background()` 里，不占布局、不挡点击。
struct ScrollIndicatorHider: UIViewRepresentable {
    final class Probe: UIView {
        override func didMoveToSuperview() { super.didMoveToSuperview(); hide() }
        override func didMoveToWindow() { super.didMoveToWindow(); hide() }
        func hide() {
            var v: UIView? = superview
            while let cur = v {
                if let sv = cur as? UIScrollView {
                    sv.showsVerticalScrollIndicator = false
                    sv.showsHorizontalScrollIndicator = false
                    return
                }
                v = cur.superview
            }
        }
    }

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) { uiView.hide() }
}

extension View {
    func hideScrollIndicators() -> some View {
        background(ScrollIndicatorHider())
    }
}
