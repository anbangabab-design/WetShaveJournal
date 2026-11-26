import Foundation
import AppKit

// MARK: - 更新状态机与下载管理器

@MainActor
final class UpdateService: NSObject, ObservableObject {
    nonisolated static let githubRepo = "anbangabab-design/WetShaveJournal"

    static let shared = UpdateService()

    private static let autoCheckDefaultsKey = "WetShaveJournal.Update.AutoCheckOnLaunch"
    private static let ignoredVersionDefaultsKey = "WetShaveJournal.Update.IgnoredVersion"

    @Published var isChecking: Bool = false
    @Published var availableRelease: GitHubReleaseInfo? = nil
    @Published var downloadState: UpdateDownloadState = .idle

    @Published var statusMessage: String? = nil
    @Published var statusIsError: Bool = false
    @Published var statusIsUpToDate: Bool = false
    @Published var menuAlertMessage: String? = nil

    @Published var autoCheckOnLaunch: Bool {
        didSet {
            guard persistPreferences else { return }
            UserDefaults.standard.set(autoCheckOnLaunch, forKey: Self.autoCheckDefaultsKey)
        }
    }

    @Published var ignoredVersion: String {
        didSet {
            guard persistPreferences else { return }
            UserDefaults.standard.set(ignoredVersion, forKey: Self.ignoredVersionDefaultsKey)
        }
    }

    private let transport: UpdateNetworkTransport
    private let currentVersionProvider: () -> String
    private let installerOpener: (URL) -> Void
    private let downloadsDirectoryProvider: () -> URL
    private let persistPreferences: Bool

    private var hasPerformedLaunchCheck: Bool = false
    private var downloadSession: URLSession?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadRelease: GitHubReleaseInfo?
    private var activeDownloadAsset: GitHubReleaseAsset?
    private var activeStagingURL: URL?

    init(
        transport: UpdateNetworkTransport = URLSessionUpdateTransport(),
        currentVersionProvider: @escaping () -> String = { AppMetadata.version },
        installerOpener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        downloadsDirectoryProvider: @escaping () -> URL = {
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        },
        persistPreferences: Bool = true
    ) {
        self.transport = transport
        self.currentVersionProvider = currentVersionProvider
        self.installerOpener = installerOpener
        self.downloadsDirectoryProvider = downloadsDirectoryProvider
        self.persistPreferences = persistPreferences

        if persistPreferences {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Self.autoCheckDefaultsKey) != nil {
                self.autoCheckOnLaunch = defaults.bool(forKey: Self.autoCheckDefaultsKey)
            } else {
                self.autoCheckOnLaunch = true
            }
            self.ignoredVersion = defaults.string(forKey: Self.ignoredVersionDefaultsKey) ?? ""
        } else {
            self.autoCheckOnLaunch = false
            self.ignoredVersion = ""
        }
        super.init()
    }

    // MARK: - 冷启动静默检查

    func performSilentLaunchCheckIfEnabled() async {
        guard !hasPerformedLaunchCheck else { return }
        hasPerformedLaunchCheck = true
        guard autoCheckOnLaunch else { return }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await checkForUpdates(manual: false, presentAlertOnNoUpdate: false)
    }

    // MARK: - 检查更新（API 主流程 + 独立 HTML 降级）

    func checkForUpdates(manual: Bool, presentAlertOnNoUpdate: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        if manual {
            statusMessage = nil
            statusIsError = false
            statusIsUpToDate = false
        }
        defer { isChecking = false }

        let release: GitHubReleaseInfo
        do {
            release = try await fetchLatestReleaseViaAPI()
        } catch let apiError {
            if case UpdateFetchError.prereleaseOnly = apiError {
                // 最新 Release 明确为预发布版本：按已是最新处理，不降级强行推送预发布版
                presentUpToDateIfManual(manual: manual, presentAlert: presentAlertOnNoUpdate)
                return
            }

            let shouldFallback: Bool
            switch apiError {
            case UpdateFetchError.httpStatus, UpdateFetchError.invalidResponse, UpdateFetchError.noReleases:
                shouldFallback = true
            default:
                shouldFallback = false
            }

            if shouldFallback {
                do {
                    release = try await fetchLatestReleaseViaWebFallback()
                } catch {
                    if manual {
                        handleCheckFailure(error.localizedDescription, presentAlert: presentAlertOnNoUpdate)
                    }
                    return
                }
            } else {
                if manual {
                    handleCheckFailure(apiError.localizedDescription, presentAlert: presentAlertOnNoUpdate)
                }
                return
            }
        }

        let currentVersion = currentVersionProvider()
        if UpdateReleaseParser.isNewerVersion(release.version, than: currentVersion) {
            if !manual && release.version == ignoredVersion {
                return
            }
            downloadState = .idle
            availableRelease = release
            if manual {
                statusIsError = false
                statusIsUpToDate = false
                statusMessage = L10n.t(
                    "发现新版本 v\(release.version)",
                    "Update available: v\(release.version)"
                )
            }
        } else {
            presentUpToDateIfManual(manual: manual, presentAlert: presentAlertOnNoUpdate)
        }
    }

    private func presentUpToDateIfManual(manual: Bool, presentAlert: Bool) {
        guard manual else { return }
        let currentVersion = currentVersionProvider()
        let msg = L10n.t(
            "当前已是最新版本（v\(currentVersion)）",
            "You're up to date (v\(currentVersion))"
        )
        statusIsError = false
        statusIsUpToDate = true
        statusMessage = msg
        if presentAlert {
            menuAlertMessage = msg
        }
    }

    func fetchLatestReleaseViaAPI() async throws -> GitHubReleaseInfo {
        let endpoint = "https://api.github.com/repos/\(Self.githubRepo)/releases/latest"
        var release = try await fetchAPIRelease(endpoint: endpoint)
        if !release.hasTrustedDigest,
           let asset = release.matchedAsset,
           let shaHex = await fetchSHA256FromReleaseChecksums(
               tagName: release.tagName,
               assetName: asset.name
           ) {
            let enriched = GitHubReleaseAsset(
                name: asset.name,
                browserDownloadURL: asset.browserDownloadURL,
                size: asset.size,
                digest: "sha256:\(shaHex)"
            )
            release = release.withMatchedAsset(enriched)
        }
        return release
    }

    func fetchReleaseByTagViaAPI(tagName: String) async throws -> GitHubReleaseInfo {
        let encodedTag = tagName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tagName
        let endpoint = "https://api.github.com/repos/\(Self.githubRepo)/releases/tags/\(encodedTag)"
        return try await fetchAPIRelease(endpoint: endpoint)
    }

    /// 从同一 Release 的 SHA256SUMS.txt 下载并解析目标安装包对应的 64 位小写 SHA-256
    func fetchSHA256FromReleaseChecksums(
        tagName: String,
        assetName: String,
        candidateAssets: [GitHubReleaseAsset] = []
    ) async -> String? {
        let candidateURL: URL? = candidateAssets.compactMap { asset -> URL? in
            guard asset.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(UpdateSecurityPolicy.checksumsAssetFileName) == .orderedSame,
                  let url = URL(string: asset.browserDownloadURL),
                  UpdateSecurityPolicy.isSameReleaseChecksumsURL(url, tagName: tagName, repo: Self.githubRepo) else {
                return nil
            }
            return url
        }.first

        guard let checksumsURL = candidateURL
            ?? UpdateSecurityPolicy.releaseChecksumsURL(tagName: tagName, repo: Self.githubRepo),
              UpdateSecurityPolicy.isAllowedReleaseAssetURL(checksumsURL, repo: Self.githubRepo) else {
            return nil
        }

        var req = URLRequest(url: checksumsURL, timeoutInterval: 15)
        req.setValue("text/plain, */*", forHTTPHeaderField: "Accept")
        req.setValue("WetShaveJournal/\(currentVersionProvider())", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await transport.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !data.isEmpty,
              data.count <= UpdateSecurityPolicy.maxChecksumsFileBytes else {
            return nil
        }
        if let finalURL = http.url,
           !UpdateSecurityPolicy.isAllowedDownloadRedirectURL(finalURL, repo: Self.githubRepo) {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return UpdateSecurityPolicy.parseSHA256Sums(text, matchingFileName: assetName)
    }

    private func fetchAPIRelease(endpoint: String) async throws -> GitHubReleaseInfo {
        let url = try EndpointSecurityValidator.validatedURL(
            endpoint,
            allowLocalHTTP: false,
            contextLabel: "GitHub Releases API"
        )
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("WetShaveJournal/\(currentVersionProvider())", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await transport.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw UpdateFetchError.invalidResponse(L10n.t("服务器响应无效", "Invalid server response"))
        }
        if http.statusCode == 404 {
            throw UpdateFetchError.noReleases
        }
        guard http.statusCode == 200 else {
            throw UpdateFetchError.httpStatus(http.statusCode)
        }
        return try UpdateReleaseParser.decodeAPIRelease(data, repo: Self.githubRepo)
    }

    func fetchLatestReleaseViaWebFallback() async throws -> GitHubReleaseInfo {
        let latestURL = try EndpointSecurityValidator.validatedURL(
            "https://github.com/\(Self.githubRepo)/releases/latest",
            allowLocalHTTP: false,
            contextLabel: "GitHub Releases"
        )
        var pageReq = URLRequest(url: latestURL, timeoutInterval: 15)
        pageReq.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        pageReq.setValue("WetShaveJournal/\(currentVersionProvider())", forHTTPHeaderField: "User-Agent")

        let (pageData, pageResp) = try await transport.data(for: pageReq)
        guard let http = pageResp as? HTTPURLResponse else {
            throw UpdateFetchError.invalidResponse(L10n.t("网页通道响应无效", "Invalid response from GitHub web"))
        }
        if http.statusCode == 404 {
            throw UpdateFetchError.noReleases
        }
        guard (200...299).contains(http.statusCode) else {
            throw UpdateFetchError.httpStatus(http.statusCode)
        }

        guard let finalURL = pageResp.url,
              let rawTag = UpdateWebFallbackParser.extractTagFromReleaseURL(finalURL, repo: Self.githubRepo) else {
            throw UpdateFetchError.noReleases
        }

        let normalizedVersion = UpdateReleaseParser.normalizeVersion(rawTag)
        guard !normalizedVersion.isEmpty else {
            throw UpdateFetchError.noReleases
        }
        if UpdateReleaseParser.isPrereleaseVersion(normalizedVersion) {
            throw UpdateFetchError.prereleaseOnly
        }

        let pageHTML = String(data: pageData, encoding: .utf8) ?? ""
        let extractedNotes = UpdateWebFallbackParser.extractReleaseNotesFromHTML(pageHTML)

        var assets: [GitHubReleaseAsset] = []
        let encodedTag = rawTag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rawTag
        let assetsEndpoint = "https://github.com/\(Self.githubRepo)/releases/expanded_assets/\(encodedTag)"
        if let assetsURL = EndpointSecurityValidator.validate(assetsEndpoint, allowLocalHTTP: false).url {
            var assetsReq = URLRequest(url: assetsURL, timeoutInterval: 15)
            assetsReq.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            assetsReq.setValue("WetShaveJournal/\(currentVersionProvider())", forHTTPHeaderField: "User-Agent")
            if let (assetsData, assetsResp) = try? await transport.data(for: assetsReq),
               let assetsHTTP = assetsResp as? HTTPURLResponse,
               (200...299).contains(assetsHTTP.statusCode),
               let assetsHTML = String(data: assetsData, encoding: .utf8) {
                assets = UpdateWebFallbackParser.extractAssetsFromExpandedHTML(assetsHTML, repo: Self.githubRepo)
            }
        }

        var matchedAsset = UpdateReleaseParser.selectPreferredAsset(
            from: assets,
            expectedVersion: normalizedVersion,
            repo: Self.githubRepo
        )
        if let asset = matchedAsset,
           asset.expectedSHA256Hex == nil,
           let shaHex = await fetchSHA256FromReleaseChecksums(
               tagName: rawTag,
               assetName: asset.name,
               candidateAssets: assets
           ) {
            matchedAsset = GitHubReleaseAsset(
                name: asset.name,
                browserDownloadURL: asset.browserDownloadURL,
                size: asset.size,
                digest: "sha256:\(shaHex)"
            )
        }
        let downloadURL = matchedAsset.flatMap { URL(string: $0.browserDownloadURL) }

        return GitHubReleaseInfo(
            tagName: rawTag,
            version: normalizedVersion,
            title: rawTag,
            body: extractedNotes,
            htmlURL: finalURL,
            matchedAsset: matchedAsset,
            downloadURL: downloadURL,
            isPrerelease: false,
            isFromWebFallback: true
        )
    }

    private func handleCheckFailure(_ reason: String, presentAlert: Bool) {
        let msg = L10n.t("检查更新失败：\(reason)", "Update check failed: \(reason)")
        statusIsError = true
        statusIsUpToDate = false
        statusMessage = msg
        if presentAlert {
            menuAlertMessage = msg
        }
    }

    // MARK: - 忽略版本 & 下载状态控制

    func ignoreVersion(_ version: String) {
        cancelDownload()
        ignoredVersion = version
        availableRelease = nil
    }

    func clearIgnoredVersion() {
        ignoredVersion = ""
    }

    func dismissSheet() {
        cancelDownload()
        availableRelease = nil
    }

    /// 启动安全下载：禁止并行重复下载；若缺少可信 SHA-256（如网页降级）先尝试通过 API 或同 Release 的 SHA256SUMS.txt 恢复摘要，仍缺失则阻止自动打开并引导前往 Release 页
    func startDownload(for release: GitHubReleaseInfo) {
        guard !downloadState.isBusy else { return }

        Task { @MainActor in
            await prepareAndStartDownload(for: release)
        }
    }

    /// 下载前补全可信 SHA-256 摘要：优先尝试 GitHub API，失败或无 digest 时自动从同一 Release 下载 SHA256SUMS.txt 解析
    func resolveTrustedReleaseForDownload(_ release: GitHubReleaseInfo) async -> GitHubReleaseInfo {
        var effectiveRelease = release
        if !effectiveRelease.hasTrustedDigest {
            // 1. 优先通过 GitHub API 按 tag 恢复官方 digest 与精确文件大小（S02）
            if let apiRecovered = try? await fetchReleaseByTagViaAPI(tagName: release.tagName) {
                if apiRecovered.hasTrustedDigest {
                    effectiveRelease = apiRecovered
                } else if let currentAsset = effectiveRelease.matchedAsset,
                          let apiAsset = apiRecovered.matchedAsset,
                          currentAsset.size == 0,
                          apiAsset.size > 0,
                          apiAsset.name.caseInsensitiveCompare(currentAsset.name) == .orderedSame {
                    effectiveRelease = apiRecovered
                }
            }
        }

        if !effectiveRelease.hasTrustedDigest,
           let asset = effectiveRelease.matchedAsset,
           let shaHex = await fetchSHA256FromReleaseChecksums(
               tagName: effectiveRelease.tagName,
               assetName: asset.name
           ) {
            let enrichedAsset = GitHubReleaseAsset(
                name: asset.name,
                browserDownloadURL: asset.browserDownloadURL,
                size: asset.size,
                digest: "sha256:\(shaHex)"
            )
            effectiveRelease = effectiveRelease.withMatchedAsset(enrichedAsset)
        }

        if effectiveRelease != release, availableRelease?.version == effectiveRelease.version {
            availableRelease = effectiveRelease
        }
        return effectiveRelease
    }

    func prepareAndStartDownload(for release: GitHubReleaseInfo) async {
        guard !downloadState.isBusy else { return }

        let effectiveRelease = await resolveTrustedReleaseForDownload(release)

        guard let asset = effectiveRelease.matchedAsset,
              let url = effectiveRelease.downloadURL else {
            downloadState = .failed(L10n.t("未找到适配当前架构的安装包，请前往官方 Release 页面下载", "No compatible installer found; please download from the official Release page."))
            return
        }

        guard UpdateSecurityPolicy.isAllowedReleaseAssetURL(url, repo: Self.githubRepo) else {
            downloadState = .failed(UpdateVerificationError.unauthorizedSourceURL(url.host ?? url.absoluteString).localizedDescription)
            return
        }

        guard UpdateSecurityPolicy.isAllowedAssetFileName(asset.name, expectedVersion: effectiveRelease.version) else {
            downloadState = .failed(UpdateVerificationError.invalidAssetFile(asset.name).localizedDescription)
            return
        }

        guard asset.expectedSHA256Hex != nil else {
            downloadState = .failed(UpdateVerificationError.missingDigest.localizedDescription)
            return
        }

        activeDownloadRelease = effectiveRelease
        activeDownloadAsset = asset
        downloadState = .downloading(progress: 0, downloadedBytes: 0, totalBytes: max(0, asset.size))

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadSession = session

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("WetShaveJournal/\(currentVersionProvider())", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: req)
        task.taskDescription = asset.name
        activeDownloadTask = task
        task.resume()
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        activeDownloadRelease = nil
        activeDownloadAsset = nil
        cleanupStagingFile()
        if downloadState.isBusy {
            downloadState = .idle
        }
    }

    private func cleanupStagingFile() {
        if let staging = activeStagingURL {
            try? FileManager.default.removeItem(at: staging)
            activeStagingURL = nil
        }
    }

    /// 对下载落盘的临时文件执行安全验证、移动到目标目录并仅在全部校验通过后触发打开（可供测试直接驱动）
    @discardableResult
    func finalizeDownloadedTempFile(
        stagingURL: URL,
        release: GitHubReleaseInfo,
        asset: GitHubReleaseAsset,
        httpResponse: HTTPURLResponse?
    ) -> Result<URL, UpdateVerificationError> {
        downloadState = .verifying

        let verification = UpdateSecurityPolicy.verifyDownloadedArtifact(
            tempFileURL: stagingURL,
            asset: asset,
            expectedVersion: release.version,
            httpResponse: httpResponse,
            repo: Self.githubRepo
        )

        switch verification {
        case .failure(let error):
            try? FileManager.default.removeItem(at: stagingURL)
            downloadState = .failed(error.localizedDescription)
            return .failure(error)

        case .success(let sha256Hex):
            let fm = FileManager.default
            let downloadsDir = downloadsDirectoryProvider()
            let safeName = (asset.name as NSString).lastPathComponent
            let destURL = downloadsDir.appendingPathComponent(safeName.isEmpty ? "WetShaveJournal-Update.pkg" : safeName)
            do {
                try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.moveItem(at: stagingURL, to: destURL)
                downloadState = .completed(fileURL: destURL, sha256Hex: sha256Hex)
                installerOpener(destURL)
                return .success(destURL)
            } catch {
                try? fm.removeItem(at: stagingURL)
                let ioErr = UpdateVerificationError.ioFailed(error.localizedDescription)
                downloadState = .failed(ioErr.localizedDescription)
                return .failure(ioErr)
            }
        }
    }

    // MARK: - 静态兼容转发（供 UI 与测试调用）

    nonisolated static func normalizeVersion(_ raw: String) -> String {
        UpdateReleaseParser.normalizeVersion(raw)
    }

    nonisolated static func isNewerVersion(_ candidate: String, than current: String) -> Bool {
        UpdateReleaseParser.isNewerVersion(candidate, than: current)
    }

    nonisolated static func selectPreferredAsset(from assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        UpdateReleaseParser.selectPreferredAsset(from: assets, repo: githubRepo)
    }

    nonisolated static func localizedReleaseNotes(from rawBody: String, isEnglish: Bool) -> String {
        UpdateReleaseParser.localizedReleaseNotes(from: rawBody, isEnglish: isEnglish)
    }

    nonisolated static func formatMB(_ bytes: Int64) -> String {
        let mb = Double(max(0, bytes)) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }
}

// MARK: - URLSessionDownloadDelegate（安全重定向拦截 + 临时隔离落盘 + SHA-256 校验）

extension UpdateService: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let targetURL = request.url,
           UpdateSecurityPolicy.isAllowedDownloadRedirectURL(targetURL, repo: Self.githubRepo) {
            completionHandler(request)
        } else {
            let blockedHost = request.url?.host ?? request.url?.absoluteString ?? "unknown"
            Task { @MainActor in
                guard task === self.activeDownloadTask else { return }
                self.activeDownloadTask?.cancel()
                self.activeDownloadTask = nil
                self.downloadSession?.invalidateAndCancel()
                self.downloadSession = nil
                self.activeDownloadRelease = nil
                self.activeDownloadAsset = nil
                self.cleanupStagingFile()
                self.downloadState = .failed(UpdateVerificationError.unauthorizedSourceURL(blockedHost).localizedDescription)
            }
            completionHandler(nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard downloadTask === self.activeDownloadTask else { return }
            let expected = self.activeDownloadAsset?.size ?? 0
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
            let progress = total > 0 ? min(1.0, max(0.0, Double(totalBytesWritten) / Double(total))) : 0
            self.downloadState = .downloading(
                progress: progress,
                downloadedBytes: totalBytesWritten,
                totalBytes: total
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let fm = FileManager.default
        let stagingURL = fm.temporaryDirectory.appendingPathComponent("wsj-update-\(UUID().uuidString).tmp")
        let httpResponse = downloadTask.response as? HTTPURLResponse

        do {
            try fm.moveItem(at: location, to: stagingURL)
        } catch {
            let errMsg = error.localizedDescription
            Task { @MainActor in
                guard downloadTask === self.activeDownloadTask else { return }
                self.finishDownloadSession()
                self.downloadState = .failed(UpdateVerificationError.ioFailed(errMsg).localizedDescription)
            }
            return
        }

        Task { @MainActor in
            guard downloadTask === self.activeDownloadTask,
                  let release = self.activeDownloadRelease,
                  let asset = self.activeDownloadAsset else {
                try? FileManager.default.removeItem(at: stagingURL)
                return
            }
            self.activeStagingURL = stagingURL
            self.finishDownloadSession()
            _ = self.finalizeDownloadedTempFile(
                stagingURL: stagingURL,
                release: release,
                asset: asset,
                httpResponse: httpResponse
            )
            self.activeStagingURL = nil
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error = error else { return }
        let nsError = error as NSError
        Task { @MainActor in
            guard task === self.activeDownloadTask else { return }
            self.finishDownloadSession()
            self.cleanupStagingFile()
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                if case .downloading = self.downloadState {
                    self.downloadState = .idle
                }
            } else {
                self.downloadState = .failed(error.localizedDescription)
            }
        }
    }

    private func finishDownloadSession() {
        activeDownloadTask = nil
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        activeDownloadRelease = nil
        activeDownloadAsset = nil
    }
}
