import Foundation
import CryptoKit

// MARK: - 本机私有加密凭据存储（专用于 AI API Key，独立于云盘目录，绝不在日志/错误中打印明文）
// 存储路径：~/Library/Application Support/WetShaveJournal_Secrets/ai_key.bin
// 目录权限 0700、文件权限 0600，AES-256-GCM 封装；彻底避免 ad-hoc 签名更新后的 macOS 钥匙串密码弹窗。

enum LocalSecretStoreError: LocalizedError {
    case ioFailed(String)
    case unexpectedData
    case verificationMismatch

    var errorDescription: String? {
        switch self {
        case .ioFailed(let msg):
            return L10n.t("本机凭据文件读写失败：\(msg)", "Local credential storage error: \(msg)")
        case .unexpectedData:
            return L10n.t("本机凭据文件数据格式无效或已损坏", "Invalid or corrupted local credential data")
        case .verificationMismatch:
            return L10n.t("本机凭据文件回读校验不一致", "Local credential read-back verification failed")
        }
    }
}

/// 兼容旧调用的错误别名（不再依赖 macOS 钥匙串）
enum KeychainStoreError: LocalizedError {
    case osStatus(Int32)
    case unexpectedData
    case verificationMismatch

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            return L10n.t("凭据存储操作失败（错误码 \(status)）", "Credential store error (\(status))")
        case .unexpectedData:
            return LocalSecretStoreError.unexpectedData.errorDescription
        case .verificationMismatch:
            return LocalSecretStoreError.verificationMismatch.errorDescription
        }
    }
}

enum LocalSecretStore {
    private static let secretsDirectoryName = "WetShaveJournal_Secrets"
    private static let aiKeyFileName = "ai_key.bin"
    private static let fileMagic: [UInt8] = [0x57, 0x53, 0x4A, 0x4B, 0x01] // "WSJK\x01"
    private static let saltLength = 16
    private static let appDomainPepper = "com.personal.wetshavejournal.local-secret.v1"

    /// 独立于云盘同步目录（不经由 JournalRepository.defaultAppSupportDirectory()）的本机私有凭据目录
    static var defaultSecretsDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent(secretsDirectoryName, isDirectory: true)
    }

    static var defaultAIKeyFileURL: URL {
        defaultSecretsDirectoryURL.appendingPathComponent(aiKeyFileName, isDirectory: false)
    }

    private static func deriveKey(salt: Data) -> SymmetricKey {
        var material = Data(appDomainPepper.utf8)
        material.append(0x00)
        material.append(Data(NSUserName().utf8))
        material.append(0x00)
        material.append(salt)
        let digest = SHA256.hash(data: material)
        return SymmetricKey(data: digest)
    }

    private static func randomSalt(count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return Data(bytes)
    }

    static func read(from fileURL: URL = defaultAIKeyFileURL) throws -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let raw: Data
        do {
            raw = try Data(contentsOf: fileURL)
        } catch {
            throw LocalSecretStoreError.ioFailed(error.localizedDescription)
        }

        let headerLen = fileMagic.count + saltLength
        // AES-GCM combined 最少需要 12B nonce + 16B tag = 28B
        guard raw.count >= headerLen + 28 else {
            throw LocalSecretStoreError.unexpectedData
        }
        let magicSlice = Array(raw.prefix(fileMagic.count))
        guard magicSlice == fileMagic else {
            throw LocalSecretStoreError.unexpectedData
        }

        let salt = raw.subdata(in: fileMagic.count..<headerLen)
        let combined = raw.subdata(in: headerLen..<raw.count)
        let key = deriveKey(salt: salt)

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw LocalSecretStoreError.unexpectedData
            }
            return value
        } catch let storeErr as LocalSecretStoreError {
            throw storeErr
        } catch {
            throw LocalSecretStoreError.unexpectedData
        }
    }

    static func save(_ secret: String, to fileURL: URL = defaultAIKeyFileURL) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(at: fileURL)
            return
        }

        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            throw LocalSecretStoreError.ioFailed(error.localizedDescription)
        }

        let salt = randomSalt(count: saltLength)
        let key = deriveKey(salt: salt)
        let payload: Data
        do {
            let sealed = try AES.GCM.seal(Data(trimmed.utf8), using: key)
            guard let combined = sealed.combined else {
                throw LocalSecretStoreError.unexpectedData
            }
            var buffer = Data(fileMagic)
            buffer.append(salt)
            buffer.append(combined)
            payload = buffer
        } catch let storeErr as LocalSecretStoreError {
            throw storeErr
        } catch {
            throw LocalSecretStoreError.ioFailed(error.localizedDescription)
        }

        let tmpURL = dir.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString.prefix(10)).tmp")
        do {
            let fd = open(tmpURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                throw LocalSecretStoreError.ioFailed(String(cString: strerror(errno)))
            }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: payload)
            try handle.synchronize()
            try handle.close()

            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpURL.path)
            if rename(tmpURL.path, fileURL.path) != 0 {
                let errStr = String(cString: strerror(errno))
                try? fm.removeItem(at: tmpURL)
                throw LocalSecretStoreError.ioFailed(errStr)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let storeErr as LocalSecretStoreError {
            try? fm.removeItem(at: tmpURL)
            throw storeErr
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw LocalSecretStoreError.ioFailed(error.localizedDescription)
        }
    }

    static func delete(at fileURL: URL = defaultAIKeyFileURL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            try fm.removeItem(at: fileURL)
        } catch {
            throw LocalSecretStoreError.ioFailed(error.localizedDescription)
        }
    }

    /// 脱敏任意错误/日志文本中的真实 API Key，杜绝敏感凭据外泄
    static func redactSecret(_ secret: String, in text: String) -> String {
        let clean = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 6 else { return text }
        return text.replacingOccurrences(of: clean, with: "[REDACTED]")
    }
}

/// 兼容桥接层：统一委托给本机私有加密文件（彻底停止访问系统钥匙串，消除密码弹窗）
enum KeychainStore {
    static func read() throws -> String? {
        try LocalSecretStore.read()
    }

    static func save(_ secret: String) throws {
        try LocalSecretStore.save(secret)
    }

    static func delete() throws {
        try LocalSecretStore.delete()
    }

    static func redactSecret(_ secret: String, in text: String) -> String {
        LocalSecretStore.redactSecret(secret, in: text)
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
