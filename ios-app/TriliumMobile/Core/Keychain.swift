import Foundation
import Security

/// ETAPI token 的 Keychain 存储。
///
/// 为什么要换掉 UserDefaults：它是明文 plist，iTunes/Finder 备份、越狱工具、
/// 甚至某些清理类 App 都能直接读到 —— token 等于服务端钥匙，泄露等于笔记全裸。
/// 用 `kSecAttrAccessibleAfterFirstUnlock`：开机首次解锁后可用，
/// 这样后台下载、分享扩展这类「App 未前台运行」的场景也读得到。
enum Keychain {
    private static let service = "com.hhxxc.trilium"
    private static let account = "etapi.token"

    /// 写入（空串 = 删除）。返回是否成功，失败时调用方需自行决定降级策略。
    @discardableResult
    static func set(_ value: String) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return true }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
