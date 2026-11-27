import XCTest
import AppKit
@testable import WetShaveJournal

final class MockAITransport: AIClientTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [(URLRequest) async throws -> (Data, HTTPURLResponse)]
    private(set) var recordedRequests: [URLRequest] = []

    init(handlers: [(URLRequest) async throws -> (Data, HTTPURLResponse)]) {
        self.handlers = handlers
    }

    private func nextHandler(for request: URLRequest) -> (URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        return handlers.isEmpty
            ? { _ in throw URLError(.badServerResponse) }
            : handlers.removeFirst()
    }

    func data(for request: URLRequest, timeout: TimeInterval, resourceTimeout: TimeInterval) async throws -> (Data, URLResponse) {
        let handler = nextHandler(for: request)
        return try await handler(request)
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }
}

final class AIServiceTests: XCTestCase {

    private func makeConfig(googleSearch: Bool = true, deepSeek: Bool = false) -> AIConfig {
        AIConfig(
            enabled: true,
            preset: deepSeek ? .deepseek : .custom,
            baseURL: deepSeek ? "https://api.deepseek.com/v1" : "http://127.0.0.1:8317/v1",
            model: deepSeek ? "deepseek-flash" : "gemini-2.5-pro",
            apiKey: "sk-unit-test-secret-key",
            enableWebSearch: deepSeek,
            enableGoogleSearch: googleSearch
        )
    }

    private func httpResp(_ code: Int, url: URL = URL(string: "http://127.0.0.1:8317/v1/chat/completions")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    func testS07GoogleSearchDowngradesOn400AndDoesNotBlindlyRetry401Or429Or500() async throws {
        // 1. HTTP 400 -> 去掉 google_search tools 降级重试 1 次成功
        let downgradeTransport = MockAITransport(handlers: [
            { req in
                let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                XCTAssertTrue(bodyStr.contains("google_search"))
                return (Data(#"{"error":{"message":"unsupported tool google_search"}}"#.utf8), self.httpResp(400))
            },
            { req in
                let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
                XCTAssertFalse(bodyStr.contains("google_search"))
                let okJSON = #"{"model":"gemini-2.5-pro","choices":[{"message":{"content":"OK"}}]}"#
                return (Data(okJSON.utf8), self.httpResp(200))
            }
        ])
        let svc1 = WebGearRecognizer(transport: downgradeTransport, enableFreeCommunityFallback: false)
        let res1 = try await svc1.chatCompletion(system: "s", user: "u", config: makeConfig(googleSearch: true), useWebSearch: true)
        XCTAssertEqual(downgradeTransport.requestCount, 2)
        XCTAssertEqual(res1.webSearchEvidence, .downgradedToPlain)

        // 2. HTTP 401 / 429 / 500 绝不盲目重试，且错误消息脱敏 API Key
        for code in [401, 429, 500] {
            let noRetryTransport = MockAITransport(handlers: [
                { _ in
                    let errJSON = #"{"error":{"message":"invalid auth for sk-unit-test-secret-key"}}"#
                    return (Data(errJSON.utf8), self.httpResp(code))
                }
            ])
            let svc = WebGearRecognizer(transport: noRetryTransport, enableFreeCommunityFallback: false)
            do {
                _ = try await svc.chatCompletion(system: "s", user: "u", config: makeConfig(deepSeek: true), useWebSearch: true)
                XCTFail("Expected HTTP \(code) to throw")
            } catch {
                XCTAssertEqual(noRetryTransport.requestCount, 1, "HTTP \(code) must NOT retry")
                XCTAssertFalse(error.localizedDescription.contains("sk-unit-test-secret-key"))
            }
        }
    }

    func testS07DistinguishesToolAcceptedVsVerifiedGrounding() async throws {
        // 无 groundingMetadata / citations -> toolAcceptedUnverified
        let unverifiedTransport = MockAITransport(handlers: [
            { _ in
                let json = #"{"model":"gemini-2.5-pro","choices":[{"message":{"content":"OK"}}]}"#
                return (Data(json.utf8), self.httpResp(200))
            }
        ])
        let svc1 = WebGearRecognizer(transport: unverifiedTransport, enableFreeCommunityFallback: false)
        let r1 = try await svc1.chatCompletion(system: "s", user: "u", config: makeConfig(googleSearch: true), useWebSearch: true)
        XCTAssertEqual(r1.webSearchEvidence, .toolAcceptedUnverified)

        // 含 citations -> verifiedWithSources
        let verifiedTransport = MockAITransport(handlers: [
            { _ in
                let json = #"{"model":"gemini-2.5-pro","citations":["https://blacklandrazors.com"],"choices":[{"message":{"content":"OK"}}]}"#
                return (Data(json.utf8), self.httpResp(200))
            }
        ])
        let svc2 = WebGearRecognizer(transport: verifiedTransport, enableFreeCommunityFallback: false)
        let r2 = try await svc2.chatCompletion(system: "s", user: "u", config: makeConfig(googleSearch: true), useWebSearch: true)
        XCTAssertEqual(r2.webSearchEvidence, .verifiedWithSources)
    }

    func testS08AuditRejectsOmittedUnknownDuplicateIDsAndProtectsManualItems() async throws {
        func makeItem(_ id: String, name: String, manual: Bool = false) -> GearItem {
            GearItem(
                id: id,
                category: .razor,
                canonicalKey: id,
                brand: "Blackland",
                name: name,
                model: name,
                count: 5,
                lastUsedDate: "2026-04-01",
                rawKeys: [id],
                isPending: false,
                razorType: .de,
                isAdjustable: false,
                isSlant: false,
                material: manual ? "钛合金" : nil,
                plateType: nil,
                gapOrSpec: nil,
                bladeType: nil,
                handleBrand: nil,
                brushMaterial: nil,
                badgerTreatment: nil,
                badgerBand: nil,
                knotSize: nil,
                knotShape: nil,
                isSample: false,
                status: .active,
                notes: nil,
                recognizedSource: nil,
                isManuallyConfirmed: manual
            )
        }

        let items = [
            makeItem("r1", name: "Blackbird"),          // unchanged
            makeItem("r2", name: "Blackbird Manual", manual: true), // manual protected + low confidence
            makeItem("r3", name: "Unknown Spec"),       // undetermined
            makeItem("r4", name: "Omitted By AI"),      // omitted -> MUST be failed, never verified!
            makeItem("r5", name: "Duplicated By AI")    // returned in both checkedIds & updates -> rejected!
        ]

        let auditReplyContent = """
        {
          "checkedIds": ["r1", "r5", "invented-id-999"],
          "undeterminedIds": ["r3"],
          "updates": [
            {
              "id": "r2",
              "brand": "Blackland",
              "name": "Blackbird Changed",
              "material": "不锈钢",
              "plateType": "SB",
              "confidence": 0.65,
              "reason": "fill missing plate"
            },
            {
              "id": "r5",
              "brand": "Blackland",
              "material": "不锈钢",
              "confidence": 0.9,
              "reason": "duplicate status conflict"
            }
          ],
          "merges": []
        }
        """

        let escapedContent = String(data: try JSONEncoder().encode(auditReplyContent), encoding: .utf8)!
        let envelope = #"{"model":"gemini-2.5-pro","choices":[{"message":{"content":\#(escapedContent)}}]}"#

        let transport = MockAITransport(handlers: [
            { _ in (Data(envelope.utf8), self.httpResp(200)) }
        ])
        let svc = WebGearRecognizer(transport: transport, enableFreeCommunityFallback: false)
        let report = try await svc.auditGearItems(items: items, aiConfig: makeConfig(googleSearch: false))

        XCTAssertEqual(report.plannedCount, 5)
        // 仅 r1 (unchanged) + r2 (suggestedUpdate) 计入 verifiedCount
        XCTAssertEqual(report.verifiedCount, 2)
        XCTAssertEqual(report.itemStatuses["r1"], .unchanged)
        XCTAssertEqual(report.itemStatuses["r2"], .suggestedUpdate)
        XCTAssertEqual(report.itemStatuses["r3"], .undetermined)
        XCTAssertEqual(report.itemStatuses["r4"], .failed)
        XCTAssertEqual(report.itemStatuses["r5"], .failed)

        XCTAssertEqual(report.undeterminedItems.map(\.id), ["r3"])
        XCTAssertEqual(Set(report.failedItems.map(\.id)), Set(["r4", "r5"]))
        XCTAssertGreaterThanOrEqual(report.unknownOrDuplicateIDCount, 2) // invented-id-999 + r5 dup

        // r2 已人工确认：原有材质「钛合金」不可被覆盖为「不锈钢」，仅补全空白底板「SB」，且默认不勾选
        let r2Proposal = try XCTUnwrap(report.updates.first(where: { $0.item.id == "r2" }))
        XCTAssertEqual(r2Proposal.proposed.material, "钛合金")
        XCTAssertEqual(r2Proposal.proposed.plateType, .sb)
        XCTAssertFalse(r2Proposal.selected)
    }

    func testS08AuditHandlesCorruptJSONAsFailureNotSilentSuccess() async throws {
        let item = GearItem(
            id: "r1", category: .razor, canonicalKey: "r1", brand: "Karve", name: "CB", model: "CB",
            count: 1, lastUsedDate: "2026-04-01", rawKeys: ["r1"], isPending: false,
            razorType: .de, isAdjustable: false, isSlant: false, material: nil, plateType: nil,
            gapOrSpec: nil, bladeType: nil, handleBrand: nil, brushMaterial: nil, badgerTreatment: nil,
            badgerBand: nil, knotSize: nil, knotShape: nil, isSample: false, status: .active,
            notes: nil, recognizedSource: nil
        )
        let envelope = #"{"model":"gemini-2.5-pro","choices":[{"message":{"content":"not json at all"}}]}"#
        let transport = MockAITransport(handlers: [
            { _ in (Data(envelope.utf8), self.httpResp(200)) }
        ])
        let svc = WebGearRecognizer(transport: transport, enableFreeCommunityFallback: false)
        let report = try await svc.auditGearItems(items: [item], aiConfig: makeConfig(googleSearch: false))

        XCTAssertEqual(report.verifiedCount, 0)
        XCTAssertEqual(report.failedItems.count, 1)
        XCTAssertEqual(report.failures.count, 1)
    }

    func testSOTDPhotoRecognitionPayloadCompressionAndVisionUnsupportedError() async throws {
        // 1. 验证超大图等比压缩至长边 <= 1280px 并输出 data:image/jpeg;base64,...
        let bigRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2560,
            pixelsHigh: 1280,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let bigImage = NSImage(size: NSSize(width: 2560, height: 1280))
        bigImage.addRepresentation(bigRep)

        let dataURL = try XCTUnwrap(SOTDPhotoCompressor.compressToJPEGDataURL(image: bigImage, maxLongEdge: 1280, quality: 0.82))
        XCTAssertTrue(dataURL.hasPrefix("data:image/jpeg;base64,"))
        let b64 = String(dataURL.dropFirst("data:image/jpeg;base64,".count))
        let decodedData = try XCTUnwrap(Data(base64Encoded: b64))
        let decodedRep = try XCTUnwrap(NSBitmapImageRep(data: decodedData))
        XCTAssertEqual(decodedRep.pixelsWide, 1280)
        XCTAssertEqual(decodedRep.pixelsHigh, 640)

        // 2. 验证多模态请求体结构与器材库匹配解析
        let transport = MockAITransport(handlers: [
            { req in
                let bodyObj = try XCTUnwrap(JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
                let messages = try XCTUnwrap(bodyObj["messages"] as? [[String: Any]])
                XCTAssertEqual(messages.count, 2)
                let userContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
                XCTAssertEqual(userContent.count, 2)
                XCTAssertEqual(userContent[0]["type"] as? String, "text")
                XCTAssertEqual(userContent[1]["type"] as? String, "image_url")
                let imgObj = try XCTUnwrap(userContent[1]["image_url"] as? [String: Any])
                XCTAssertEqual(imgObj["url"] as? String, dataURL)

                let contentJSON = #"{"razor":"Blackland Blackbird Ti","blade":"Gillette Nacet","brush":"Oumo 26mm","soap":"MDC Absinthe","bowl":null,"preShave":null,"afterShave":null,"uncertainNote":"刀片包装反光请确认"}"#
                let envelope: [String: Any] = [
                    "model": "gemini-2.5-pro",
                    "choices": [["message": ["content": contentJSON]]]
                ]
                let respData = try JSONSerialization.data(withJSONObject: envelope)
                return (respData, self.httpResp(200))
            }
        ])
        let svc = WebGearRecognizer(transport: transport, enableFreeCommunityFallback: false)
        let result = try await svc.recognizeSOTDPhoto(
            imageDataURL: dataURL,
            catalog: [.razor: ["Blackland Blackbird Ti"], .blade: ["Gillette Nacet"]],
            aiConfig: makeConfig(googleSearch: false)
        )
        XCTAssertEqual(result.razor, "Blackland Blackbird Ti")
        XCTAssertEqual(result.blade, "Gillette Nacet")
        XCTAssertEqual(result.brush, "Oumo 26mm")
        XCTAssertEqual(result.soap, "MDC Absinthe")
        XCTAssertNil(result.bowl)
        XCTAssertEqual(result.recognizedFieldCount, 4)
        XCTAssertEqual(result.uncertainNote, "刀片包装反光请确认")

        // 3. 验证纯文本模型不支持 image_url 时准确映射为 AIClientError.visionNotSupported
        let textOnlyTransport = MockAITransport(handlers: [
            { _ in
                let err = #"{"error":{"message":"Invalid request: unknown variant `image_url`, expected string content"}}"#
                return (Data(err.utf8), self.httpResp(400))
            }
        ])
        let svc2 = WebGearRecognizer(transport: textOnlyTransport, enableFreeCommunityFallback: false)
        do {
            _ = try await svc2.recognizeSOTDPhoto(
                imageDataURL: dataURL,
                catalog: [:],
                aiConfig: makeConfig(deepSeek: true)
            )
            XCTFail("Expected visionNotSupported error")
        } catch let err as AIClientError {
            guard case .visionNotSupported = err else {
                return XCTFail("Expected .visionNotSupported, got \(err)")
            }
        }
    }

    func testBrandLogoImageProcessorTrimCircleAndBlankFiltering() throws {
        func makeCanvas(width: Int, height: Int, fill: NSColor, innerRect: NSRect?, innerColor: NSColor?) -> NSImage {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            fill.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            if let r = innerRect, let c = innerColor {
                c.setFill()
                r.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            let png = rep.representation(using: .png, properties: [:])!
            return NSImage(data: png)!
        }

        // 1. 纯白空白图必须被识别并过滤
        let blankWhite = makeCanvas(width: 120, height: 120, fill: .white, innerRect: nil, innerColor: nil)
        XCTAssertTrue(BrandLogoImageProcessor.isBlankOrUniform(blankWhite))

        // 2. 带大白边的宽字标自动去白边并长边缩放到 256px，保持横向比例
        let wideOnWhite = makeCanvas(
            width: 400,
            height: 200,
            fill: .white,
            innerRect: NSRect(x: 100, y: 70, width: 200, height: 60),
            innerColor: .systemBlue
        )
        XCTAssertFalse(BrandLogoImageProcessor.isBlankOrUniform(wideOnWhite))
        let normalized = try XCTUnwrap(BrandLogoImageProcessor.normalizeLogo(wideOnWhite, trimMode: .auto, maxLongEdge: 256))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: normalized.pngData))
        XCTAssertEqual(rep.pixelsWide, 256)
        XCTAssertLessThan(rep.pixelsHigh, 120) // 去掉上下白边后明显更紧凑

        // 3. 圆形裁切输出 256×256 且四角完全透明
        let squareLogo = makeCanvas(
            width: 180,
            height: 180,
            fill: .black,
            innerRect: NSRect(x: 30, y: 30, width: 120, height: 120),
            innerColor: .systemYellow
        )
        let circular = try XCTUnwrap(BrandLogoImageProcessor.normalizeLogo(squareLogo, trimMode: .none, circularMask: true, maxLongEdge: 256))
        let cRep = try XCTUnwrap(NSBitmapImageRep(data: circular.pngData))
        XCTAssertEqual(cRep.pixelsWide, 256)
        XCTAssertEqual(cRep.pixelsHigh, 256)
        let cornerAlpha = cRep.colorAt(x: 2, y: 2)?.alphaComponent ?? 1.0
        XCTAssertLessThan(cornerAlpha, 0.05)
    }

    func testAILogoFinderSSRFHeaderExtractionWaybackAndVisionPipeline() async throws {
        // 1. SSRF 私有网段与非法协议严格拦截，同时放行品牌官网及 Shopify 图片 CDN
        XCTAssertFalse(AILogoFinderService.isSafePublicURL(URL(string: "http://127.0.0.1:8080/logo.png")!, allowImageCDN: true))
        XCTAssertFalse(AILogoFinderService.isSafePublicURL(URL(string: "http://192.168.1.5/logo.png")!, allowImageCDN: true))
        XCTAssertFalse(AILogoFinderService.isSafePublicURL(URL(string: "http://169.254.169.254/latest/meta-data")!, allowImageCDN: true))
        XCTAssertFalse(AILogoFinderService.isSafePublicURL(URL(string: "file:///etc/passwd")!, allowImageCDN: true))
        XCTAssertFalse(AILogoFinderService.isSafePublicURL(URL(string: "https://www.etsy.com/shop/test")!, allowImageCDN: true))
        XCTAssertTrue(AILogoFinderService.isSafePublicURL(URL(string: "https://cdn.shopify.com/s/files/logo.png")!, allowImageCDN: true))
        XCTAssertTrue(AILogoFinderService.isSafePublicURL(URL(string: "https://ethosgroomingessentials.com/")!, allowImageCDN: false))

        // 2. HTML 页头智能提取：优先 <header> logo，跳过国旗与 .svg
        let sampleHTML = """
        <html><head>
        <link rel="icon" href="/favicon.svg">
        <meta property="og:image" content="https://examplebrand.com/og.png">
        </head><body>
        <header>
          <img src="//cdn.shopify.com/static/images/flags/ca.svg?format=jpg" class="country-flag">
          <img class="site-header__logo-image" src="//examplebrand.com/cdn/shop/files/brand-logo.png">
        </header>
        </body></html>
        """
        let extracted = AILogoFinderService.extractSmartHTMLCandidates(
            html: sampleHTML,
            baseURL: URL(string: "https://examplebrand.com/")!
        )
        XCTAssertEqual(extracted.first?.url, "https://examplebrand.com/cdn/shop/files/brand-logo.png")
        XCTAssertEqual(extracted.first?.source, .officialHeader)
        XCTAssertFalse(extracted.contains { $0.url.contains("flags/") || $0.url.hasSuffix(".svg") })

        // 3. 端到端 Mock：AI 发现官网 → 官网返回 402 → 自动走 Wayback 归档页提取页头标 → AI 视觉核验通过
        let samplePNG: Data = {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 120,
                pixelsHigh: 60,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 120, height: 60).fill()
            NSColor.systemRed.setFill()
            NSRect(x: 15, y: 12, width: 90, height: 36).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }()

        struct MockLogoHTTPFetcher: AILogoHTTPFetcher {
            let png: Data
            func fetch(url: URL) async -> (Data, HTTPURLResponse)? {
                let s = url.absoluteString
                func resp(_ code: Int, ct: String = "text/html") -> HTTPURLResponse {
                    HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": ct])!
                }
                if s == "https://archivedbrand.com" || s == "https://archivedbrand.com/" {
                    return (Data("Payment Required".utf8), resp(402))
                }
                if s.contains("archive.org/wayback/available") {
                    let wbJSON = #"{"archived_snapshots":{"closest":{"url":"https://web.archive.org/web/20250101/https://archivedbrand.com/"}}}"#
                    return (Data(wbJSON.utf8), resp(200, ct: "application/json"))
                }
                if s == "https://web.archive.org/web/20250101/https://archivedbrand.com/" {
                    let wbHTML = #"<header><img class="logo__img" src="https://web.archive.org/web/20250101im_/https://archivedbrand.com/logo.png"></header>"#
                    return (Data(wbHTML.utf8), resp(200))
                }
                if s.contains("archivedbrand.com/logo.png") {
                    return (png, resp(200, ct: "image/png"))
                }
                return nil
            }
        }

        let aiTransport = MockAITransport(handlers: [
            { _ in
                let discovery = #"{"canonicalName":"Archived Brand","officialSiteURL":"https://archivedbrand.com/","directLogoURLs":[],"reasoning":"Found official site"}"#
                let env: [String: Any] = ["model": "gemini-2.5-pro", "choices": [["message": ["content": discovery]]]]
                return (try JSONSerialization.data(withJSONObject: env), self.httpResp(200))
            },
            { _ in
                let audit = #"{"selectedIndex":0,"isAuthentic":true,"isCircularEmblem":false,"cropRect":null,"reason":"Verified official transparent wordmark"}"#
                let env: [String: Any] = ["model": "gemini-2.5-pro", "choices": [["message": ["content": audit]]]]
                return (try JSONSerialization.data(withJSONObject: env), self.httpResp(200))
            }
        ])

        let finder = AILogoFinderService(aiTransport: aiTransport, httpFetcher: MockLogoHTTPFetcher(png: samplePNG))
        let result = await finder.findLogoCandidates(for: "Archived Brand", category: .soap, aiConfig: makeConfig(googleSearch: true))

        XCTAssertTrue(result.visionVerified)
        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates.first?.source, .waybackHeader)
        XCTAssertEqual(result.candidates.first?.aiRecommended, true)
        XCTAssertEqual(result.candidates.first?.pixelWidth, 256)
        XCTAssertEqual(result.recommendedCandidateID, result.candidates.first?.id)
    }
}
