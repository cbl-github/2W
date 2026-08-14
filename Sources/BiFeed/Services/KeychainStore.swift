import Foundation
import Security

/// 极简 Keychain 封装。Keychain 不可用不是本 app 要兜的底：读失败返回 nil，写失败忽略。
enum KeychainStore {
    private static let service = "com.paul.bifeed"

    /// 按源 HTTP Basic 密码的账户名。
    static func basicAccount(feedId: Int64) -> String { "feed-basic-\(feedId)" }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 空串 = 删除。
    static func set(account: String, value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(base as CFDictionary) // 先删后加，覆盖写最简单
        guard !value.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData as String] = Data(value.utf8)
        _ = SecItemAdd(attrs as CFDictionary, nil)
    }
}
