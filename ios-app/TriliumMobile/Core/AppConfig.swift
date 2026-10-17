import Foundation

/// 全局默认配置
enum AppConfig {
    /// 默认服务器地址（ddnsto 公网映射，家内外通用；仅 https，http 打不通）
    static let defaultServer = "https://dsm920-ddsnto-trilium-notes.x.ddnsto.com"

    /// 备用服务器地址（家里内网直连，公网穿透证书过期/挂掉时自动顶替）
    static let defaultBackupServer = "http://192.168.31.198:18190"

    /// 速记落点：根下的「收件箱」
    static let defaultInboxTitle = "收件箱"

    /// 本地缓存条数上限
    static let cacheLimit = 200

    /// GitHub 仓库（用于更新检测的 Releases）
    static let repo = "hhxxc/trilium-mobile"
}
