import Foundation
import AppKit
import CryptoKit

// MARK: - 数据模型

struct GitHubReleaseAsset: Codable, Hashable, Identifiable {
    var id: String { browserDownloadURL }
    let name: String
    let browserDownloadURL: String
    let size: Int64
    /// GitHub Releases API 返回的资产摘要（例如 "sha256:<64位十六进制>"）
    let digest: String?

    init(name: String, browserDownloadURL: String, size: Int64, digest: String? = nil) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
        self.digest = digest
    }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
    }

    /// 严格解析 "sha256:<64-hex>" 格式，非法格式或缺失均返回 nil
    var expectedSHA256Hex: String? {
        guard let raw = digest?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        guard lower.hasPrefix("sha256:") else { return nil }
        let hex = String(lower.dropFirst("sha256:".count))
        guard hex.count == 64, hex.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return nil
        }
        return hex
    }
}

struct GitHubReleaseInfo: Equatable, Identifiable {
    var id: String { version }
    let tagName: String
    let version: String
    let title: String
    let body: String
    let htmlURL: URL
    let matchedAsset: GitHubReleaseAsset?
    let downloadURL: URL?
    let isPrerelease: Bool
    let isFromWebFallback: Bool

    init(
        tagName: String,
        version: String,
        title: String,
        body: String,
        htmlURL: URL,
        matchedAsset: GitHubReleaseAsset?,
        downloadURL: URL?,
        isPrerelease: Bool = false,
        isFromWebFallback: Bool = false
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.body = body
        self.htmlURL = htmlURL
        self.matchedAsset = matchedAsset
        self.downloadURL = downloadURL
        self.isPrerelease = isPrerelease
        self.isFromWebFallback = isFromWebFallback
    }

    var hasDirectAsset: Bool {
        matchedAsset != nil && downloadURL != nil
    }

    var hasTrustedDigest: Bool {
        matchedAsset?.expectedSHA256Hex != nil
    }

    func withMatchedAsset(_ asset: GitHubReleaseAsset?) -> GitHubReleaseInfo {
        GitHubReleaseInfo(
            tagName: tagName,
            version: version,
            title: title,
            body: body,
            htmlURL: htmlURL,
            matchedAsset: asset,
            downloadURL: asset.flatMap { URL(string: $0.browserDownloadURL) },
            isPrerelease: isPrerelease,
            isFromWebFallback: isFromWebFallback
        )
    }
}

enum UpdateDownloadState: Equatable {
    case idle
    case downloading(progress: Double, downloadedBytes: Int64, totalBytes: Int64)
    case verifying
    case completed(fileURL: URL, sha256Hex: String)
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .downloading, .verifying: return true
        default: return false
        }
    }
}

// MARK: - 可注入网络传输协议（便于单元测试 Mock）

protocol UpdateNetworkTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionUpdateTransport: UpdateNetworkTransport {
    let session: URLSession

    init(timeoutRequest: TimeInterval = 15, timeoutResource: TimeInterval = 25) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutRequest
        config.timeoutIntervalForResource = timeoutResource
        self.session = URLSession(configuration: config)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - 安全校验与完整性验证策略（S02）

enum UpdateVerificationError: LocalizedError, Equatable {
    case httpStatus(Int)
    case unauthorizedSourceURL(String)
    case invalidAssetFile(String)
    case emptyFile
    case sizeMismatch(expected: Int64, actual: Int64)
    case missingDigest
    case digestMismatch(expected: String, actual: String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return L10n.t("下载失败（HTTP \(code)）", "Download failed (HTTP \(code))")
        case .unauthorizedSourceURL(let host):
            return L10n.t(
                "已阻止下载：来源或重定向域名不受信任（\(host)）",
                "Download blocked: untrusted source or redirect host (\(host))"
            )
        case .invalidAssetFile(let name):
            return L10n.t(
                "已阻止下载：资源文件名或架构不符合预期（\(name)）",
                "Download blocked: unexpected asset file or architecture (\(name))"
            )
        case .emptyFile:
            return L10n.t("校验失败：下载的安装包为空文件，已删除", "Verification failed: downloaded installer is empty and was deleted")
        case .sizeMismatch(let expected, let actual):
            return L10n.t(
                "校验失败：文件大小与 Release 元数据不一致（预期 \(expected) 字节，实际 \(actual) 字节），已删除",
                "Verification failed: file size mismatch (expected \(expected), got \(actual)); file deleted"
            )
        case .missingDigest:
            return L10n.t(
                "未能从 GitHub Releases API 或 SHA256SUMS.txt 获取可信 SHA-256 摘要，出于安全考虑已禁止自动打开安装包，请前往官方 Release 页面手动核验下载",
                "Could not obtain a trusted SHA-256 digest from GitHub Releases API or SHA256SUMS.txt. Auto-opening is disabled; please download manually from the official Release page."
            )
        case .digestMismatch:
            return L10n.t(
                "校验失败：安装包 SHA-256 与 Release 摘要不匹配，已自动删除并阻止打开",
                "Verification failed: installer SHA-256 mismatch. File deleted and blocked from opening."
            )
        case .ioFailed(let detail):
            return L10n.t("处理安装包失败：\(detail)", "Failed to process installer: \(detail)")
        }
    }
}

enum UpdateSecurityPolicy {
    static let checksumsAssetFileName = "SHA256SUMS.txt"
    static let maxChecksumsFileBytes = 1_048_576

    /// 允许的 GitHub Release 附件下载重定向 CDN 主机白名单
    static let allowedCDNHosts: Set<String> = [
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com"
    ]

    /// 校验 Release 页面 HTML URL 必须指向预期仓库的 HTTPS GitHub Releases 路径
    nonisolated static func isAllowedReleasePageURL(_ url: URL, repo: String = UpdateService.githubRepo) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            return false
        }
        let path = url.path.lowercased()
        guard !path.contains("..") else { return false }
        return path.hasPrefix("/\(repo.lowercased())/releases/")
    }

    /// 校验初始下载 URL 必须严格指向预期仓库的 /releases/download/
    nonisolated static func isAllowedReleaseAssetURL(_ url: URL, repo: String = UpdateService.githubRepo) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            return false
        }
        let path = url.path.lowercased()
        guard !path.contains("..") else { return false }
        return path.hasPrefix("/\(repo.lowercased())/releases/download/")
    }

    /// 校验下载重定向目标与最终响应 URL：只允许预期仓库或 GitHub 官方资产 CDN（均强制 HTTPS）
    nonisolated static func isAllowedDownloadRedirectURL(_ url: URL, repo: String = UpdateService.githubRepo) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "github.com" {
            return isAllowedReleaseAssetURL(url, repo: repo)
        }
        return allowedCDNHosts.contains(host)
    }

    /// 构造并校验同一 Release 下的 SHA256SUMS.txt 官方下载地址
    nonisolated static func releaseChecksumsURL(
        tagName: String,
        repo: String = UpdateService.githubRepo
    ) -> URL? {
        let trimmed = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("..") else {
            return nil
        }
        let encodedTag = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let raw = "https://github.com/\(repo)/releases/download/\(encodedTag)/\(checksumsAssetFileName)"
        guard let url = URL(string: raw),
              isAllowedReleaseAssetURL(url, repo: repo) else {
            return nil
        }
        return url
    }

    /// 校验给定的 SHA256SUMS.txt URL 严格属于目标仓库的同一个 Release tag
    nonisolated static func isSameReleaseChecksumsURL(
        _ url: URL,
        tagName: String,
        repo: String = UpdateService.githubRepo
    ) -> Bool {
        guard isAllowedReleaseAssetURL(url, repo: repo) else { return false }
        let trimmedTag = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTag.isEmpty else { return false }

        let path = url.path
        let prefix = "/\(repo)/releases/download/"
        guard path.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        let remainder = String(path.dropFirst(prefix.count))
        let parts = remainder.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return false }

        let urlTag = (parts[0].removingPercentEncoding ?? parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let urlFile = (parts[1].removingPercentEncoding ?? parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return urlTag == trimmedTag && urlFile.caseInsensitiveCompare(checksumsAssetFileName) == .orderedSame
    }

    /// 解析 sha256sum / shasum / BSD 校验清单，提取目标安装包文件名对应的 64 位小写 SHA-256
    /// 兼容 `artifacts/<name>` 前缀、`*` 二进制标记及空格路径；若同名存在冲突摘要则拒绝返回 nil
    nonisolated static func parseSHA256Sums(
        _ content: String,
        matchingFileName targetFileName: String
    ) -> String? {
        let targetBase = normalizedFileBasename(targetFileName)
        guard !targetBase.isEmpty else { return nil }
        let targetLower = targetBase.lowercased()

        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var exactMatches: Set<String> = []
        var ciMatches: Set<String> = []

        for line in normalized.components(separatedBy: "\n") {
            guard let parsed = parseSHA256SumsLine(line) else { continue }
            if parsed.fileName == targetBase {
                exactMatches.insert(parsed.sha256Hex)
            } else if parsed.fileName.lowercased() == targetLower {
                ciMatches.insert(parsed.sha256Hex)
            }
        }

        if !exactMatches.isEmpty {
            return exactMatches.count == 1 ? exactMatches.first : nil
        }
        return ciMatches.count == 1 ? ciMatches.first : nil
    }

    private nonisolated static func isValidSHA256Hex(_ raw: String) -> Bool {
        guard raw.count == 64 else { return false }
        return raw.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }

    private nonisolated static func normalizedFileBasename(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        let unified = trimmed.replacingOccurrences(of: "\\", with: "/")
        let lastSeg = unified.split(separator: "/").last.map(String.init) ?? ""
        return lastSeg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseSHA256SumsLine(_ line: String) -> (sha256Hex: String, fileName: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        // BSD / OpenSSL 格式: SHA256 (<path>) = <64-hex>
        if trimmed.lowercased().hasPrefix("sha256") {
            let afterLabel = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if afterLabel.hasPrefix("("),
               let closeIdx = afterLabel.lastIndex(of: ")") {
                let pathPart = String(afterLabel[afterLabel.index(after: afterLabel.startIndex)..<closeIdx])
                let afterParen = afterLabel[afterLabel.index(after: closeIdx)...].trimmingCharacters(in: .whitespaces)
                if afterParen.hasPrefix("=") {
                    let hashPart = afterParen.dropFirst().trimmingCharacters(in: .whitespaces)
                    let base = normalizedFileBasename(pathPart)
                    if isValidSHA256Hex(hashPart), !base.isEmpty {
                        return (hashPart.lowercased(), base)
                    }
                }
            }
        }

        // GNU sha256sum / shasum 格式: [\]<64-hex><spaces/tabs>[*]<path>
        let gnuLine = trimmed.hasPrefix("\\") ? String(trimmed.dropFirst()) : trimmed
        guard let wsIdx = gnuLine.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let hashPart = String(gnuLine[..<wsIdx])
        guard isValidSHA256Hex(hashPart) else { return nil }

        var pathPart = String(gnuLine[wsIdx...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        if pathPart.hasPrefix("*") {
            pathPart.removeFirst()
        }
        let base = normalizedFileBasename(pathPart)
        guard !base.isEmpty else { return nil }
        return (hashPart.lowercased(), base)
    }

    /// 校验目标资产文件名、扩展名、排除源码包、拒绝非本机架构（arm64 上拒绝纯 x86_64/intel 包）与版本一致性
    nonisolated static func isAllowedAssetFileName(
        _ name: String,
        expectedVersion: String,
        isAppleSilicon: Bool = {
            #if arch(arm64)
            return true
            #else
            return false
            #endif
        }()
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("..") else {
            return false
        }
        let lower = trimmed.lowercased()
        let allowedExt = lower.hasSuffix(".pkg") || lower.hasSuffix(".dmg") || lower.hasSuffix(".zip")
        guard allowedExt else { return false }

        if lower.hasSuffix("-source.zip") || lower.hasSuffix("_source.zip") || lower.contains("source.zip") {
            return false
        }

        if isAppleSilicon {
            let isIntelOnly = (lower.contains("x86_64") || lower.contains("amd64") || lower.contains("intel"))
                && !lower.contains("universal")
                && !lower.contains("arm64")
                && !lower.contains("aarch64")
            if isIntelOnly { return false }
        }

        // 若文件名显式携带版本号，必须与目标 Release 版本一致，防止错配旧版资源
        let cleanVersion = UpdateReleaseParser.normalizeVersion(expectedVersion)
        if !cleanVersion.isEmpty,
           let versionRegex = try? NSRegularExpression(pattern: #"(?:^|[-_vV])(\d+\.\d+\.\d+(?:\.\d+)?)(?:[-_.]|$)"#),
           let match = versionRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let r = Range(match.range(at: 1), in: trimmed) {
            let embeddedVersion = String(trimmed[r])
            if embeddedVersion != cleanVersion {
                return false
            }
        }
        return true
    }

    /// 流式计算本地文件 SHA-256（CryptoKit，适合大安装包，避免整文件读入内存）
    nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 对临时目录中刚下载完毕的安装包执行完整安全与完整性校验（S02）
    nonisolated static func verifyDownloadedArtifact(
        tempFileURL: URL,
        asset: GitHubReleaseAsset,
        expectedVersion: String,
        httpResponse: HTTPURLResponse?,
        repo: String = UpdateService.githubRepo
    ) -> Result<String, UpdateVerificationError> {
        if let http = httpResponse {
            guard (200...299).contains(http.statusCode) else {
                return .failure(.httpStatus(http.statusCode))
            }
            if let finalURL = http.url, !isAllowedDownloadRedirectURL(finalURL, repo: repo) {
                return .failure(.unauthorizedSourceURL(finalURL.host ?? finalURL.absoluteString))
            }
        }

        guard let assetURL = URL(string: asset.browserDownloadURL),
              isAllowedReleaseAssetURL(assetURL, repo: repo) else {
            return .failure(.unauthorizedSourceURL(asset.browserDownloadURL))
        }

        guard isAllowedAssetFileName(asset.name, expectedVersion: expectedVersion) else {
            return .failure(.invalidAssetFile(asset.name))
        }

        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: tempFileURL.path)
        } catch {
            return .failure(.ioFailed(error.localizedDescription))
        }

        let actualSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard actualSize > 0 else {
            return .failure(.emptyFile)
        }
        if asset.size > 0 && actualSize != asset.size {
            return .failure(.sizeMismatch(expected: asset.size, actual: actualSize))
        }

        guard let expectedSHA = asset.expectedSHA256Hex else {
            return .failure(.missingDigest)
        }

        let actualSHA: String
        do {
            actualSHA = try sha256Hex(ofFileAt: tempFileURL)
        } catch {
            return .failure(.ioFailed(error.localizedDescription))
        }

        guard actualSHA == expectedSHA else {
            return .failure(.digestMismatch(expected: expectedSHA, actual: actualSHA))
        }

        return .success(actualSHA)
    }
}

// MARK: - API Release 解析、版本比较与资产选择（R06）

enum UpdateFetchError: LocalizedError, Equatable {
    case noReleases
    case prereleaseOnly
    case httpStatus(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noReleases:
            return L10n.t("仓库暂无已发布的 Release 版本", "No published releases found in repository")
        case .prereleaseOnly:
            return L10n.t("最新 Release 为预发布版本，已忽略", "Latest release is a pre-release and was ignored")
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .invalidResponse(let msg):
            return msg
        }
    }
}

enum UpdateReleaseParser {
    struct RawAPIRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GitHubReleaseAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }

    nonisolated static func decodeAPIRelease(
        _ data: Data,
        repo: String = UpdateService.githubRepo
    ) throws -> GitHubReleaseInfo {
        let decoded: RawAPIRelease
        do {
            decoded = try JSONDecoder().decode(RawAPIRelease.self, from: data)
        } catch {
            throw UpdateFetchError.invalidResponse(L10n.t("解析 Release JSON 失败", "Failed to decode release JSON"))
        }

        if decoded.draft == true {
            throw UpdateFetchError.noReleases
        }
        let normalizedVersion = normalizeVersion(decoded.tagName)
        guard !normalizedVersion.isEmpty else {
            throw UpdateFetchError.invalidResponse(L10n.t("Release 缺少有效版本号", "Release is missing a valid tag_name"))
        }

        let isPre = (decoded.prerelease == true) || isPrereleaseVersion(normalizedVersion)
        if isPre {
            throw UpdateFetchError.prereleaseOnly
        }

        guard let htmlURL = URL(string: decoded.htmlURL),
              UpdateSecurityPolicy.isAllowedReleasePageURL(htmlURL, repo: repo) else {
            throw UpdateFetchError.invalidResponse(L10n.t("发布页链接无效或不受信任", "Invalid or untrusted release page URL"))
        }

        let assets = decoded.assets ?? []
        let matchedAsset = selectPreferredAsset(from: assets, expectedVersion: normalizedVersion, repo: repo)
        let downloadURL = matchedAsset.flatMap { URL(string: $0.browserDownloadURL) }
        let releaseTitle = (decoded.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? decoded.name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : decoded.tagName

        return GitHubReleaseInfo(
            tagName: decoded.tagName,
            version: normalizedVersion,
            title: releaseTitle,
            body: (decoded.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            htmlURL: htmlURL,
            matchedAsset: matchedAsset,
            downloadURL: downloadURL,
            isPrerelease: false,
            isFromWebFallback: false
        )
    }

    nonisolated static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("v") || s.hasPrefix("V") {
            s.removeFirst()
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func isPrereleaseVersion(_ version: String) -> Bool {
        let norm = normalizeVersion(version).lowercased()
        if norm.contains("-") {
            return true
        }
        let markers = ["alpha", "beta", "rc", "preview", "dev", "nightly"]
        return markers.contains { norm.contains($0) }
    }

    /// 严格语义化版本对比（拒绝预发布版本误当稳定版，拒绝相同/旧版本更新，确保 1.3.10 > 1.3.2）
    nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        let normCand = normalizeVersion(candidate)
        let normCurr = normalizeVersion(current)
        guard !normCand.isEmpty, !normCurr.isEmpty else { return false }
        // 稳定更新通道不向用户推送预发布版本
        if isPrereleaseVersion(normCand) {
            return false
        }

        func numericParts(_ v: String) -> [Int]? {
            let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
            let segs = core.split(separator: ".")
            guard !segs.isEmpty else { return nil }
            var nums: [Int] = []
            for seg in segs {
                guard let n = Int(seg) else { return nil }
                nums.append(n)
            }
            return nums
        }

        guard let a = numericParts(normCand), let b = numericParts(normCurr) else {
            return false
        }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }

    /// 筛选符合来源白名单、架构与版本约束的 macOS 安装包（严格优先 arm64/universal 的 .dmg，其次 .pkg / .zip）
    nonisolated static func selectPreferredAsset(
        from assets: [GitHubReleaseAsset],
        expectedVersion: String = "",
        repo: String = UpdateService.githubRepo
    ) -> GitHubReleaseAsset? {
        let validAssets = assets.filter { asset in
            guard let url = URL(string: asset.browserDownloadURL),
                  UpdateSecurityPolicy.isAllowedReleaseAssetURL(url, repo: repo) else {
                return false
            }
            return UpdateSecurityPolicy.isAllowedAssetFileName(asset.name, expectedVersion: expectedVersion)
        }
        guard !validAssets.isEmpty else { return nil }

        func isArchMatch(_ name: String) -> Bool {
            name.contains("arm64") || name.contains("aarch64") || name.contains("universal")
        }

        if let preferredDmg = validAssets.first(where: { let n = $0.name.lowercased(); return n.hasSuffix(".dmg") && isArchMatch(n) }) {
            return preferredDmg
        }
        if let dmg = validAssets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
            return dmg
        }
        if let preferredPkg = validAssets.first(where: { let n = $0.name.lowercased(); return n.hasSuffix(".pkg") && isArchMatch(n) }) {
            return preferredPkg
        }
        if let pkg = validAssets.first(where: { $0.name.lowercased().hasSuffix(".pkg") }) {
            return pkg
        }
        if let archZip = validAssets.first(where: { let n = $0.name.lowercased(); return n.hasSuffix(".zip") && isArchMatch(n) }) {
            return archZip
        }
        return validAssets.first(where: { $0.name.lowercased().hasSuffix(".zip") })
    }

    /// 若更新说明同时包含 `## English` 与 `## 简体中文`（或 `## 中文`）分段，按当前语言自动截取
    nonisolated static func localizedReleaseNotes(from rawBody: String, isEnglish: Bool) -> String {
        let normalized = rawBody
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        enum SectionLang { case zh, en }
        var sections: [(lang: SectionLang, startLine: Int)] = []

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("## ") else { continue }
            let heading = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
            if heading == "english" {
                sections.append((.en, idx))
            } else if heading == "简体中文" || heading == "中文" {
                sections.append((.zh, idx))
            }
        }

        guard sections.contains(where: { $0.lang == .en }),
              sections.contains(where: { $0.lang == .zh }) else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let targetLang: SectionLang = isEnglish ? .en : .zh
        guard let targetSection = sections.first(where: { $0.lang == targetLang }) else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let contentStart = targetSection.startLine + 1
        var contentEnd = lines.count
        for i in contentStart..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
                contentEnd = i
                break
            }
        }
        guard contentStart < contentEnd else {
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sliced = lines[contentStart..<contentEnd]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sliced.isEmpty ? normalized.trimmingCharacters(in: .whitespacesAndNewlines) : sliced
    }
}

// MARK: - 独立网页降级解析器（R06：与 API 主流程解耦；HTML 链接本身不携带摘要，由同 Release 的 SHA256SUMS.txt 或 API 校验）

enum UpdateWebFallbackParser {
    private static let markdownBodyStartRegex = try! NSRegularExpression(
        pattern: #"<div\b[^>]*\bclass="[^"]*\bmarkdown-body\b[^"]*"[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let divTagRegex = try! NSRegularExpression(pattern: #"</?div\b[^>]*>"#, options: [.caseInsensitive])
    private static let numericEntityRegex = try! NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]+)|(\d+));"#)

    nonisolated static func extractTagFromReleaseURL(_ url: URL, repo: String = UpdateService.githubRepo) -> String? {
        guard UpdateSecurityPolicy.isAllowedReleasePageURL(url, repo: repo) else {
            return nil
        }
        let path = url.path
        guard let range = path.range(of: "/releases/tag/", options: .caseInsensitive) else {
            return nil
        }
        let remainder = String(path[range.upperBound...])
        let rawSegment = remainder.split(separator: "/").first.map(String.init) ?? ""
        let decoded = (rawSegment.removingPercentEncoding ?? rawSegment)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    nonisolated static func extractReleaseNotesFromHTML(_ html: String) -> String {
        guard let firstMatch = markdownBodyStartRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let openRange = Range(firstMatch.range, in: html) else {
            return ""
        }

        let tailRange = NSRange(openRange.upperBound..<html.endIndex, in: html)
        let matches = divTagRegex.matches(in: html, range: tailRange)
        var depth = 1
        var bodyEnd: String.Index? = nil
        for m in matches {
            guard let r = Range(m.range, in: html) else { continue }
            if html[r].lowercased().hasPrefix("</div") {
                depth -= 1
                if depth == 0 {
                    bodyEnd = r.lowerBound
                    break
                }
            } else {
                depth += 1
            }
        }
        guard let endIdx = bodyEnd else { return "" }

        var text = String(html[openRange.upperBound..<endIdx])
        let replacements: [(String, String)] = [
            (#"(?is)<svg\b[^>]*>.*?</svg>"#, ""),
            (#"(?is)<script\b[^>]*>.*?</script>"#, ""),
            (#"(?is)<style\b[^>]*>.*?</style>"#, ""),
            (#"(?is)<h2\b[^>]*>(.*?)</h2>"#, "\n\n## $1\n"),
            (#"(?is)<h3\b[^>]*>(.*?)</h3>"#, "\n### $1\n"),
            (#"(?is)<li\b[^>]*>"#, "\n• "),
            (#"(?is)</li>"#, ""),
            (#"(?is)<br\s*/?>"#, "\n"),
            (#"(?is)</p>"#, "\n\n"),
            (#"<[^>]+>"#, "")
        ]
        for (pat, rep) in replacements {
            text = text.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
        }

        text = decodeHTMLEntities(text)
        let cleanedLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cleanedLines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func extractAssetsFromExpandedHTML(
        _ html: String,
        repo: String = UpdateService.githubRepo
    ) -> [GitHubReleaseAsset] {
        let escapedRepo = NSRegularExpression.escapedPattern(for: repo)
        let pattern = #"href="(/\#(escapedRepo)/releases/download/[^"'\s<>]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        var results: [GitHubReleaseAsset] = []
        var seenURLs: Set<String> = []
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let relativePath = String(html[r])
            let fullURL = "https://github.com\(relativePath)"
            guard !seenURLs.contains(fullURL) else { continue }
            seenURLs.insert(fullURL)

            let rawFileName = relativePath.split(separator: "/").last.map(String.init) ?? ""
            let decodedName = (rawFileName.removingPercentEncoding ?? rawFileName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decodedName.isEmpty else { continue }

            // 网页降级通道绝不将不可信网页文本当作可信摘要，digest 显式置 nil
            results.append(GitHubReleaseAsset(name: decodedName, browserDownloadURL: fullURL, size: 0, digest: nil))
        }
        return results
    }

    private nonisolated static func decodeHTMLEntities(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")

        let matches = numericEntityRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for m in matches {
            guard let fullRange = Range(m.range, in: s) else { continue }
            var scalarVal: UInt32? = nil
            if m.range(at: 1).location != NSNotFound, let r = Range(m.range(at: 1), in: s) {
                scalarVal = UInt32(s[r], radix: 16)
            } else if m.range(at: 2).location != NSNotFound, let r = Range(m.range(at: 2), in: s) {
                scalarVal = UInt32(s[r], radix: 10)
            }
            if let val = scalarVal, let scalar = UnicodeScalar(val) {
                s.replaceSubrange(fullRange, with: String(scalar))
            }
        }
        return s
    }
}

