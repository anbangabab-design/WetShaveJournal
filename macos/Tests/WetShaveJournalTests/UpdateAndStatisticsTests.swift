import XCTest
import CryptoKit
@testable import WetShaveJournal

final class MockUpdateTransport: UpdateNetworkTransport, @unchecked Sendable {
    private let handler: (URLRequest) async throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

@MainActor
final class UpdateAndStatisticsTests: XCTestCase {

    // MARK: - S02 & R06: 在线更新安全校验与降级通道

    func testSemVerComparisonAndPrereleaseRejection() {
        XCTAssertTrue(UpdateReleaseParser.isNewerVersion("1.3.10", than: "1.3.2"))
        XCTAssertTrue(UpdateReleaseParser.isNewerVersion("v1.4.0", than: "1.3.4"))
        XCTAssertFalse(UpdateReleaseParser.isNewerVersion("1.3.4", than: "1.3.4"))
        XCTAssertFalse(UpdateReleaseParser.isNewerVersion("1.3.3", than: "1.3.4"))
        XCTAssertFalse(UpdateReleaseParser.isNewerVersion("1.4.0-beta.1", than: "1.3.4"))
        XCTAssertFalse(UpdateReleaseParser.isNewerVersion("1.4.0-rc1", than: "1.3.4"))
    }

    func testReleaseDecodingAssetSelectionAndSourceAllowlist() throws {
        let validDigest = "sha256:" + String(repeating: "a", count: 64)
        let apiJSON = """
        {
          "tag_name": "v1.3.5",
          "name": "v1.3.5",
          "body": "## 简体中文\\n修复稳定性问题\\n\\n## English\\nStability fixes",
          "html_url": "https://github.com/anbangabab-design/WetShaveJournal/releases/tag/v1.3.5",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "WetShaveJournal-1.3.5-source.zip",
              "browser_download_url": "https://github.com/anbangabab-design/WetShaveJournal/releases/download/v1.3.5/WetShaveJournal-1.3.5-source.zip",
              "size": 1000,
              "digest": "\(validDigest)"
            },
            {
              "name": "WetShaveJournal-1.3.5-x86_64.pkg",
              "browser_download_url": "https://github.com/anbangabab-design/WetShaveJournal/releases/download/v1.3.5/WetShaveJournal-1.3.5-x86_64.pkg",
              "size": 2000,
              "digest": "\(validDigest)"
            },
            {
              "name": "evil.pkg",
              "browser_download_url": "https://evil.example.com/WetShaveJournal-1.3.5-arm64.pkg",
              "size": 2000,
              "digest": "\(validDigest)"
            },
            {
              "name": "WetShaveJournal-1.3.5-arm64.pkg",
              "browser_download_url": "https://github.com/anbangabab-design/WetShaveJournal/releases/download/v1.3.5/WetShaveJournal-1.3.5-arm64.pkg",
              "size": 4096,
              "digest": "\(validDigest)"
            }
          ]
        }
        """

        let info = try UpdateReleaseParser.decodeAPIRelease(Data(apiJSON.utf8))
        XCTAssertEqual(info.version, "1.3.5")
        XCTAssertEqual(info.matchedAsset?.name, "WetShaveJournal-1.3.5-arm64.pkg")
        XCTAssertEqual(info.matchedAsset?.expectedSHA256Hex, String(repeating: "a", count: 64))

        // 双语日志自动截取
        XCTAssertEqual(UpdateReleaseParser.localizedReleaseNotes(from: info.body, isEnglish: false), "修复稳定性问题")
        XCTAssertEqual(UpdateReleaseParser.localizedReleaseNotes(from: info.body, isEnglish: true), "Stability fixes")

        // 预发布与草稿拒绝
        let preJSON = apiJSON.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
        XCTAssertThrowsError(try UpdateReleaseParser.decodeAPIRelease(Data(preJSON.utf8)))

        // 重定向主机白名单校验
        XCTAssertTrue(UpdateSecurityPolicy.isAllowedDownloadRedirectURL(URL(string: "https://objects.githubusercontent.com/file.pkg")!))
        XCTAssertTrue(UpdateSecurityPolicy.isAllowedDownloadRedirectURL(URL(string: "https://release-assets.githubusercontent.com/file.pkg")!))
        XCTAssertFalse(UpdateSecurityPolicy.isAllowedDownloadRedirectURL(URL(string: "https://attacker.com/file.pkg")!))
        XCTAssertFalse(UpdateSecurityPolicy.isAllowedDownloadRedirectURL(URL(string: "http://objects.githubusercontent.com/file.pkg")!))
    }

    func testS02ArtifactVerificationBlocksMismatchWrongSizeMissingDigestAndAllowsValid() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wsj_upd_\(UUID().uuidString)", isDirectory: true)
        let downloadsDir = tempDir.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let payload = Data("fake-pkg-binary-content-v1.3.5".utf8)
        let realSHA = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let downloadURL = URL(string: "https://github.com/anbangabab-design/WetShaveJournal/releases/download/v1.3.5/WetShaveJournal-1.3.5.pkg")!
        let htmlURL = URL(string: "https://github.com/anbangabab-design/WetShaveJournal/releases/tag/v1.3.5")!
        let okResp = HTTPURLResponse(url: URL(string: "https://objects.githubusercontent.com/release-1.3.5.pkg")!, statusCode: 200, httpVersion: nil, headerFields: nil)!

        var openedURLs: [URL] = []
        let service = UpdateService(
            transport: MockUpdateTransport { _ in throw URLError(.notConnectedToInternet) },
            currentVersionProvider: { "1.3.4" },
            installerOpener: { openedURLs.append($0) },
            downloadsDirectoryProvider: { downloadsDir },
            persistPreferences: false
        )

        func makeStaging() throws -> URL {
            let url = tempDir.appendingPathComponent("stage-\(UUID().uuidString).tmp")
            try payload.write(to: url)
            return url
        }

        // 1. 摘要不匹配 -> 删除临时文件且不打开
        let badDigestAsset = GitHubReleaseAsset(name: "WetShaveJournal-1.3.5.pkg", browserDownloadURL: downloadURL.absoluteString, size: Int64(payload.count), digest: "sha256:" + String(repeating: "0", count: 64))
        let releaseBadDigest = GitHubReleaseInfo(tagName: "v1.3.5", version: "1.3.5", title: "v1.3.5", body: "", htmlURL: htmlURL, matchedAsset: badDigestAsset, downloadURL: downloadURL)
        let stage1 = try makeStaging()
        let res1 = service.finalizeDownloadedTempFile(stagingURL: stage1, release: releaseBadDigest, asset: badDigestAsset, httpResponse: okResp)
        if case .failure(.digestMismatch) = res1 {} else { XCTFail("Expected digestMismatch") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage1.path))
        XCTAssertTrue(openedURLs.isEmpty)

        // 2. 文件大小不匹配 -> 删除临时文件且不打开
        let wrongSizeAsset = GitHubReleaseAsset(name: "WetShaveJournal-1.3.5.pkg", browserDownloadURL: downloadURL.absoluteString, size: 99999, digest: "sha256:\(realSHA)")
        let stage2 = try makeStaging()
        let res2 = service.finalizeDownloadedTempFile(stagingURL: stage2, release: releaseBadDigest, asset: wrongSizeAsset, httpResponse: okResp)
        if case .failure(.sizeMismatch) = res2 {} else { XCTFail("Expected sizeMismatch") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage2.path))
        XCTAssertTrue(openedURLs.isEmpty)

        // 3. 缺少摘要（网页降级无摘要）-> 删除临时文件且绝不打开
        let noDigestAsset = GitHubReleaseAsset(name: "WetShaveJournal-1.3.5.pkg", browserDownloadURL: downloadURL.absoluteString, size: Int64(payload.count), digest: nil)
        let stage3 = try makeStaging()
        let res3 = service.finalizeDownloadedTempFile(stagingURL: stage3, release: releaseBadDigest, asset: noDigestAsset, httpResponse: okResp)
        if case .failure(.missingDigest) = res3 {} else { XCTFail("Expected missingDigest") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage3.path))
        XCTAssertTrue(openedURLs.isEmpty)

        // 4. 正确摘要与大小 -> 移动至下载目录并触发 opener（Mock，不实际启动安装程序）
        let goodAsset = GitHubReleaseAsset(name: "WetShaveJournal-1.3.5.pkg", browserDownloadURL: downloadURL.absoluteString, size: Int64(payload.count), digest: "sha256:\(realSHA)")
        let stage4 = try makeStaging()
        let res4 = service.finalizeDownloadedTempFile(stagingURL: stage4, release: releaseBadDigest, asset: goodAsset, httpResponse: okResp)
        switch res4 {
        case .success(let dest):
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
            XCTAssertEqual(openedURLs, [dest])
        case .failure(let err):
            XCTFail("Expected verification success, got \(err)")
        }
    }

    func testWebFallbackBlocksAutoDownloadWhenAPIDigestRecoveryFails() async {
        let transport = MockUpdateTransport { req in
            let urlStr = req.url?.absoluteString ?? ""
            if urlStr.contains("api.github.com") {
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            if urlStr.contains("/releases/latest") {
                let finalURL = URL(string: "https://github.com/anbangabab-design/WetShaveJournal/releases/tag/v1.3.9")!
                let html = #"<div class="markdown-body"><h2>简体中文</h2><p>网页降级日志</p></div>"#
                return (Data(html.utf8), HTTPURLResponse(url: finalURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if urlStr.contains("/releases/expanded_assets/") {
                let assetsHTML = #"<a href="/anbangabab-design/WetShaveJournal/releases/download/v1.3.9/WetShaveJournal-1.3.9.pkg">pkg</a>"#
                return (Data(assetsHTML.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }

        let service = UpdateService(
            transport: transport,
            currentVersionProvider: { "1.3.4" },
            installerOpener: { _ in XCTFail("Must never auto-open unverified installer") },
            persistPreferences: false
        )

        await service.checkForUpdates(manual: true)
        guard let release = service.availableRelease else {
            return XCTFail("Expected web fallback to discover v1.3.9")
        }
        XCTAssertEqual(release.version, "1.3.9")
        XCTAssertTrue(release.isFromWebFallback)
        XCTAssertFalse(release.hasTrustedDigest)

        await service.prepareAndStartDownload(for: release)
        if case .failed(let msg) = service.downloadState {
            XCTAssertTrue(msg.contains("SHA-256"))
        } else {
            XCTFail("Expected missingDigest failure when API digest recovery fails, got \(service.downloadState)")
        }
    }

    // MARK: - R04 & S09: 统计引擎、编号配对与刀片估算口径

    func testS09NumberedSlotPairingAndBladeLongevityEstimationFlag() {
        let entries = [
            JournalEntry(
                id: "e1",
                date: "2025-12-31",
                fields: [
                    JournalField(label: "剃须刀1", value: "Blackbird"),
                    JournalField(label: "剃须刀2", value: "Overlander"),
                    JournalField(label: "刀片1", value: "Astra SP 1st"),
                    JournalField(label: "刀片2", value: "Feather 1st"),
                    JournalField(label: "过程", value: "顺横无痛BBS")
                ]
            ),
            JournalEntry(
                id: "e2",
                date: "2026-01-01",
                fields: [
                    JournalField(label: "剃须刀1", value: "Blackbird"),
                    JournalField(label: "刀片1", value: "Astra SP 2nd"),
                    JournalField(label: "过程", value: "3档顺2档逆微痛DFS 略拉扯")
                ]
            ),
            JournalEntry(
                id: "e3",
                date: "2026-01-01",
                fields: [
                    JournalField(label: "剃须刀", value: "Overlander"),
                    JournalField(label: "刀片", value: "Feather 2nd"),
                    JournalField(label: "过程", value: "顺刺痛CCS")
                ]
            )
        ]

        let db = JournalDatabase(entries: entries)
        let snapshot = StatisticsEngine.buildSnapshot(database: db, revision: 1, isEnglish: false)

        XCTAssertEqual(snapshot.totalEntries, 3)
        XCTAssertEqual(snapshot.bbsCount, 1)
        XCTAssertEqual(snapshot.painlessCount, 1)
        XCTAssertEqual(snapshot.monthlyTrend.map(\.month), ["2025-12", "2026-01"])

        // 确认同日多条记录的日历状态取最严重级别（微痛 + 刺痛 -> 刺痛）
        XCTAssertEqual(snapshot.calendarStatusByDate["2026-01-01"]?.count, 2)
        XCTAssertEqual(snapshot.calendarStatusByDate["2026-01-01"]?.worstSeverity, .stinging)

        // 确认编号槽位配对无交叉（Blackbird 只配 Astra SP，Overlander 只配 Feather）
        XCTAssertEqual(snapshot.comboStats.count, 2)
        XCTAssertTrue(snapshot.comboStats.contains(where: { $0.razorName == "Blackbird" && $0.bladeName == "Astra SP" && $0.uses == 2 }))
        XCTAssertTrue(snapshot.comboStats.contains(where: { $0.razorName == "Overlander" && $0.bladeName == "Feather" && $0.uses == 2 }))

        // 确认刀片寿命显式标注估算口径
        XCTAssertEqual(snapshot.bladeLongevityStats.count, 2)
        XCTAssertTrue(snapshot.bladeLongevityStats.allSatisfy(\.isEstimated))

        // ProcessParser 细节验证
        let p2 = snapshot.parsedProcessByEntryID["e2"]
        XCTAssertEqual(p2?.passes.count, 2)
        XCTAssertEqual(p2?.passes[0].setting, "3")
        XCTAssertEqual(p2?.passes[1].setting, "2")
        XCTAssertEqual(p2?.result, .dfs)
        XCTAssertEqual(p2?.irritation, .mild)
        XCTAssertEqual(p2?.note, "略拉扯")
    }
}
