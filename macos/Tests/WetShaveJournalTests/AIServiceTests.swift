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
}
