import Foundation
import Security

// MARK: - macOS Keychain 轻量凭据存储（专用于 AI API Key，绝不在日志/错误中打印明文）

enum KeychainStoreError: LocalizedError {
    case osStatus(OSStatus)
    case unexpectedData
    case verificationMismatch

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            let msg = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return L10n.t("钥匙串操作失败：\(msg)", "Keychain error: \(msg)")
        case .unexpectedData:
            return L10n.t("钥匙串中的凭据数据格式无效", "Invalid credential data in Keychain")
        case .verificationMismatch:
            return L10n.t("钥匙串回读校验不一致", "Keychain read-back verification failed")
        }
    }
}

enum KeychainStore {
    static let service = "com.personal.wetshavejournal"
    static let aiAPIKeyAccount = "ai_api_key"

    static func read(account: String = aiAPIKeyAccount) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.unexpectedData
        }
        return value
    }

    static func save(_ secret: String, account: String = aiAPIKeyAccount) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: account)
            return
        }

        let encoded = Data(trimmed.utf8)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: encoded
        ]

        let updateStatus = SecItemUpdate(matchQuery as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = matchQuery
            addQuery[kSecValueData as String] = encoded
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError.osStatus(addStatus)
            }
            return
        }

        throw KeychainStoreError.osStatus(updateStatus)
    }

    static func delete(account: String = aiAPIKeyAccount) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.osStatus(status)
        }
    }

    /// 脱敏任意错误/日志文本中的真实 API Key，杜绝敏感凭据外泄
    static func redactSecret(_ secret: String, in text: String) -> String {
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 6 else { return text }
        return text.replacingOccurrences(of: clean, with: "[REDACTED]")
    }
}

// MARK: - 网络端点安全校验（远程强制 HTTPS，仅本机回环地址允许 HTTP）

enum EndpointValidationStatus: Equatable {
    case validHTTPS(URL)
    case validLocalHTTP(URL)
    case invalid(String)

    var url: URL? {
        switch self {
        case .validHTTPS(let u), .validLocalHTTP(let u): return u
        case .invalid: return nil
        }
    }

    var isLocalHTTP: Bool {
        if case .validLocalHTTP = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .invalid(let msg) = self { return msg }
        return nil
    }
}

enum EndpointSecurityError: LocalizedError {
    case invalidEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let message):
            return message
        }
    }
}

enum EndpointSecurityValidator {
    static func isLoopbackHost(_ rawHost: String) -> Bool {
        let normalized = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
    }

    static func validate(
        _ rawURLString: String,
        allowLocalHTTP: Bool = true,
        contextLabel: String = "Base URL"
    ) -> EndpointValidationStatus {
        let trimmed = rawURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid(L10n.t("\(contextLabel) 不能为空", "\(contextLabel) cannot be empty"))
        }

        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return .invalid(L10n.t("\(contextLabel) 格式无效：包含非法空白字符", "Invalid \(contextLabel): contains whitespace"))
        }

        guard let comps = URLComponents(string: trimmed),
              let url = comps.url,
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host,
              !host.isEmpty else {
            return .invalid(L10n.t("\(contextLabel) 格式无效，请输入完整的 https:// 地址", "Invalid \(contextLabel). Please enter a valid https:// URL."))
        }

        if comps.user != nil || comps.password != nil {
            return .invalid(L10n.t("\(contextLabel) 不允许在地址中内嵌账号密码", "\(contextLabel) must not include embedded credentials"))
        }

        switch scheme {
        case "https":
            return .validHTTPS(url)
        case "http":
            if allowLocalHTTP && isLoopbackHost(host) {
                return .validLocalHTTP(url)
            }
            return .invalid(L10n.t(
                "安全拦截：远程地址必须使用 https://，已拒绝向明文 http:// 端点发送请求（仅 localhost / 127.0.0.1 / ::1 本机服务允许 http://）",
                "Security blocked: remote endpoints must use https://. Plaintext http:// is only allowed for local hosts (localhost, 127.0.0.1, ::1)."
            ))
        default:
            return .invalid(L10n.t(
                "\(contextLabel) 协议不受支持（仅支持 https:// 或本机 http://）",
                "Unsupported URL scheme in \(contextLabel) (only https:// or local http:// is allowed)."
            ))
        }
    }

    static func validatedURL(
        _ rawURLString: String,
        allowLocalHTTP: Bool = true,
        contextLabel: String = "Base URL"
    ) throws -> URL {
        switch validate(rawURLString, allowLocalHTTP: allowLocalHTTP, contextLabel: contextLabel) {
        case .validHTTPS(let url), .validLocalHTTP(let url):
            return url
        case .invalid(let msg):
            throw EndpointSecurityError.invalidEndpoint(msg)
        }
    }
}
