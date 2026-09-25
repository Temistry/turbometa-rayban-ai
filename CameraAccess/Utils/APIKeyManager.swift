/*
 * API Key Manager
 *
 * 실제 인증값은 iOS Keychain의 현재 기기 전용 항목에만 저장한다.
 * 인증값의 내용, 일부 문자열, 접두사, 접미사 또는 해시는 콘솔과 파일에 기록하지 않는다.
 *
 * 일반 실행 경로는 Google Gemini Key 하나를 사용한다. 기존 Alibaba/OpenRouter 항목은
 * 이전 설치 데이터와 개발자 호환성을 위해 보존하지만 자동으로 읽거나 삭제하지 않는다.
 */

import Foundation
import Security

/// 키체인 읽기 결과. 잠금 때문에 못 읽은 경우를 '없음'과 구분한다.
enum APIKeyReadResult: Equatable {
    case found(String)
    case notFound
    case locked
}

final class APIKeyManager {
    static let shared = APIKeyManager()

    private let service = "com.smartview.glassai.apikey"

    /// 보안 기준: 잠금 해제 상태에서만 읽기 + 이 기기 전용.
    private let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    /// 한 번 읽은 키는 실행 중 메모리에만 보관한다(로그·파일 기록 없음).
    /// 회의는 화면이 잠긴 뒤에도 이어지므로, 시작 시점(잠금 해제 상태)에 읽어 둔 키를 쓴다.
    private let cacheLock = NSLock()
    private var cache: [String: String] = [:]

    private let alibabaBeijingAccount = "alibaba-beijing-api-key"
    private let alibabaSingaporeAccount = "alibaba-singapore-api-key"
    private let openrouterAccount = "openrouter-api-key"
    private let googleAccount = "google-api-key"
    private let jevAccount = "typesafe-jev-api-key"
    private let legacyAccount = "qwen-api-key"
    private let legacyAlibabaAccount = "alibaba-api-key"

    private var allAccounts: [String] {
        [
            alibabaBeijingAccount,
            alibabaSingaporeAccount,
            openrouterAccount,
            googleAccount,
            jevAccount,
            legacyAccount,
            legacyAlibabaAccount
        ]
    }

    private init() {
        migrateLegacyKey()
        hardenExistingItems()
    }

    // MARK: - Migration and hardening

    private func migrateLegacyKey() {
        if let legacyKey = getKey(for: legacyAccount),
           getKey(for: alibabaBeijingAccount) == nil {
            _ = saveKey(legacyKey, for: alibabaBeijingAccount)
            _ = deleteKey(for: legacyAccount)
            print("[Keychain][INFO] 이전 Qwen 자격 증명 항목 이전 완료")
        }

        if let legacyKey = getKey(for: legacyAlibabaAccount),
           getKey(for: alibabaBeijingAccount) == nil {
            _ = saveKey(legacyKey, for: alibabaBeijingAccount)
            _ = deleteKey(for: legacyAlibabaAccount)
            print("[Keychain][INFO] 이전 Alibaba 자격 증명 항목 이전 완료")
        }
    }

    private func hardenExistingItems() {
        for account in allAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]

            let attributes: [String: Any] = [
                kSecAttrAccessible as String: accessibility
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status != errSecSuccess,
               status != errSecItemNotFound,
               status != errSecInteractionNotAllowed {
                print("[Keychain][WARN] 접근 정책 강화 실패 account=\(account) status=\(status)")
            }
        }
    }

    // MARK: - Provider-specific compatibility

    func saveAPIKey(_ key: String, for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> Bool {
        saveKey(key, for: accountName(for: provider, endpoint: endpoint))
    }

    func getAPIKey(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> String? {
        getKey(for: accountName(for: provider, endpoint: endpoint))
    }

    func deleteAPIKey(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> Bool {
        deleteKey(for: accountName(for: provider, endpoint: endpoint))
    }

    func hasAPIKey(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> Bool {
        guard let key = getAPIKey(for: provider, endpoint: endpoint) else { return false }
        return !key.isEmpty
    }

    // MARK: - Google Gemini credential

    func saveGoogleAPIKey(_ key: String) -> Bool {
        saveKey(key, for: googleAccount)
    }

    func getGoogleAPIKey() -> String? {
        getKey(for: googleAccount)
    }

    func deleteGoogleAPIKey() -> Bool {
        deleteKey(for: googleAccount)
    }

    func hasGoogleAPIKey() -> Bool {
        guard let key = getGoogleAPIKey() else { return false }
        return !key.isEmpty
    }

    // MARK: - TypeSafe Jev credential

    func saveJevAPIKey(_ key: String) -> Bool {
        saveKey(key, for: jevAccount)
    }

    func getJevAPIKey() -> String? {
        getKey(for: jevAccount)
    }

    func readJevAPIKey() -> APIKeyReadResult {
        readKey(for: jevAccount)
    }

    /// 회의 시작 시(잠금 해제 상태) 회의에 필요한 키를 미리 읽어 메모리에 올린다.
    func prewarmMeetingKeys() {
        _ = readKey(for: jevAccount)
        _ = readKey(for: googleAccount)
    }

    func deleteJevAPIKey() -> Bool {
        deleteKey(for: jevAccount)
    }

    func hasJevAPIKey() -> Bool {
        guard let key = getJevAPIKey() else { return false }
        return !key.isEmpty
    }

    // MARK: - Current-provider compatibility

    func saveAPIKey(_ key: String) -> Bool {
        saveGoogleAPIKey(key)
    }

    func getAPIKey() -> String? {
        getGoogleAPIKey()
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        deleteGoogleAPIKey()
    }

    func hasAPIKey() -> Bool {
        hasGoogleAPIKey()
    }

    // MARK: - Private helpers

    private func accountName(for provider: APIProvider, endpoint: AlibabaEndpoint? = nil) -> String {
        switch provider {
        case .google:
            return googleAccount
        case .alibaba:
            let effectiveEndpoint = endpoint ?? APIProviderManager.staticAlibabaEndpoint
            switch effectiveEndpoint {
            case .beijing: return alibabaBeijingAccount
            case .singapore: return alibabaSingaporeAccount
            }
        case .openrouter:
            return openrouterAccount
        }
    }

    private func saveKey(_ key: String, for account: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty,
              let data = normalizedKey.data(using: .utf8) else {
            print("[Keychain][WARN] 빈 자격 증명 저장 요청 거부 account=\(account)")
            return false
        }

        _ = deleteKey(for: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: accessibility,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[Keychain][ERROR] 자격 증명 저장 실패 account=\(account) status=\(status)")
        } else {
            setCached(normalizedKey, for: account)
            print("[Keychain][INFO] 자격 증명 저장 완료 account=\(account)")
        }
        return status == errSecSuccess
    }

    private func getKey(for account: String) -> String? {
        if case .found(let key) = readKey(for: account) {
            return key
        }
        return nil
    }

    private func readKey(for account: String) -> APIKeyReadResult {
        if let cached = cachedKey(for: account) {
            return .found(cached)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            if status == errSecInteractionNotAllowed {
                print("[Keychain][WARN] 기기 잠금으로 자격 증명 읽기 실패 account=\(account)")
                return .locked
            }
            if status != errSecItemNotFound {
                print("[Keychain][WARN] 자격 증명 읽기 실패 account=\(account) status=\(status)")
            }
            return .notFound
        }

        setCached(key, for: account)
        return .found(key)
    }

    private func deleteKey(for account: String) -> Bool {
        setCached(nil, for: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        let succeeded = status == errSecSuccess || status == errSecItemNotFound
        if !succeeded {
            print("[Keychain][ERROR] 자격 증명 삭제 실패 account=\(account) status=\(status)")
        }
        return succeeded
    }

    private func cachedKey(for account: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[account]
    }

    private func setCached(_ key: String?, for account: String) {
        cacheLock.lock()
        cache[account] = key
        cacheLock.unlock()
    }
}
