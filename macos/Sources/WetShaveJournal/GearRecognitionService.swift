import Foundation
import AppKit

// MARK: - AI 业务领域结构化解码模型（R05）

private struct RecognizeGearPayload: Decodable {
    let brand: String?
    let handleBrand: String?
    let model: String?
    let name: String?
    let razorType: String?
    let isAdjustable: Bool?
    let isSlant: Bool?
    let material: String?
    let plateType: String?
    let gapOrSpec: String?
    let notes: String?
    let bladeType: String?
    let brushMaterial: String?
    let badgerTreatment: String?
    let badgerBand: String?
    let knotSize: String?
    let knotShape: String?
    let confidence: Double?
    let isCorrection: Bool?
    let note: String?
}

private struct AuditBatchItemInput: Encodable {
    let id: String
    let category: String
    let brand: String
    let model: String
    let name: String
    let count: Int
    let pending: Bool
    let manuallyConfirmed: Bool
    let razorType: String?
    let isAdjustable: Bool?
    let isSlant: Bool?
    let material: String?
    let plateType: String?
    let gapOrSpec: String?
    let notes: String?
    let bladeType: String?
    let handleBrand: String?
    let brushMaterial: String?
    let badgerTreatment: String?
    let badgerBand: String?
    let knotSize: String?
    let knotShape: String?
}

private struct AuditUpdatePayload: Decodable {
    let id: String
    let brand: String?
    let handleBrand: String?
    let model: String?
    let name: String?
    let razorType: String?
    let isAdjustable: Bool?
    let isSlant: Bool?
    let material: String?
    let plateType: String?
    let gapOrSpec: String?
    let notes: String?
    let bladeType: String?
    let brushMaterial: String?
    let badgerTreatment: String?
    let badgerBand: String?
    let knotSize: String?
    let knotShape: String?
    let confidence: Double?
    let reason: String?
}

private struct AuditMergePayload: Decodable {
    let sourceId: String
    let targetId: String
    let reason: String?
}

private struct AuditBatchResponsePayload: Decodable {
    let checkedIds: [String]?
    let undeterminedIds: [String]?
    let updates: [AuditUpdatePayload]?
    let merges: [AuditMergePayload]?
}

private struct NaturalSOTDPayload: Decodable {
    struct PassPayload: Decodable {
        let pass: String
        let setting: String?
    }
    let razor: String?
    let blade: String?
    let bladeUseCount: Int?
    let brush: String?
    let soap: String?
    let bowl: String?
    let preShave: String?
    let afterShave: String?
    let loadingMethod: String?
    let latheringMethod: String?
    let hotTowel: Bool?
    let afterShower: Bool?
    let useAlum: Bool?
    let passes: [PassPayload]?
    let result: String?
    let irritation: String?
    let note: String?
}

private struct PhotoSOTDPayload: Decodable {
    let razor: String?
    let blade: String?
    let brush: String?
    let soap: String?
    let bowl: String?
    let preShave: String?
    let afterShave: String?
    let uncertainNote: String?
    let note: String?
}

private struct SetupRecommendationPayload: Decodable {
    let razor: String?
    let blade: String?
    let brush: String?
    let soap: String?
    let bowl: String?
    let preShave: String?
    let afterShave: String?
    let reason: String?
}

// MARK: - SOTD 照片等比缩放与 JPEG 压缩工具（长边 <= 1280px，质量 0.82，节省 Token 并提速）

enum SOTDPhotoCompressor {
    static func compressToJPEGDataURL(
        image: NSImage,
        maxLongEdge: CGFloat = 1280,
        quality: CGFloat = 0.82
    ) -> String? {
        let pixelSize: CGSize = {
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               cg.width > 0, cg.height > 0 {
                return CGSize(width: cg.width, height: cg.height)
            }
            let maxRepW = image.representations.map(\.pixelsWide).max() ?? 0
            let maxRepH = image.representations.map(\.pixelsHigh).max() ?? 0
            if maxRepW > 0, maxRepH > 0 {
                return CGSize(width: maxRepW, height: maxRepH)
            }
            return image.size
        }()

        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }

        let longEdge = max(pixelSize.width, pixelSize.height)
        let scale = longEdge > maxLongEdge ? (maxLongEdge / longEdge) : 1.0
        let targetWidth = max(1, Int((pixelSize.width * scale).rounded()))
        let targetHeight = max(1, Int((pixelSize.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: targetWidth,
            pixelsHigh: targetHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: Double(quality))]
        ), !jpegData.isEmpty else {
            return nil
        }
        return "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }
}

// MARK: - 湿剃 AI 与联网识别核心服务

/// 湿剃 AI 与联网识别核心服务（S07 / S08 / R05）：
/// - 支持可注入 AIClientTransport 进行离线 Mock 测试
/// - 统一超时策略（常规 90s/180s、体检 180s/300s），仅在明确的参数/工具不兼容响应时执行有限降级重试，绝不盲目重试 401/403/429/5xx/超时/取消
/// - 体检响应严格按输入 ID 追踪逐条状态，拒绝未知/重复 ID，缺失或截断条目绝不计为完成
// MARK: - 湿剃 AI 业务编排与社区免费识别服务（R05 / S07 / S08）

actor WebGearRecognizer {
    static let shared = WebGearRecognizer()

    private let client: AIClient
    private let enableFreeCommunityFallback: Bool
    private var transport: AIClientTransport { client.transport }

    private static let gapSpecRegex = try! NSRegularExpression(pattern: #"(?i)\b(\d\.\d{1,2}\s*(?:mm)?(?:\+{1,2})?)\b"#)

    init(
        transport: AIClientTransport = URLSessionAIClientTransport(),
        enableFreeCommunityFallback: Bool = true
    ) {
        self.client = AIClient(transport: transport)
        self.enableFreeCommunityFallback = enableFreeCommunityFallback
    }

    func chatCompletion(
        system: String,
        user: String,
        config: AIConfig,
        useWebSearch: Bool = false,
        useAuditTimeout: Bool = false,
        maxTokens: Int? = nil,
        temperature: Double = 0.15
    ) async throws -> AIChatCompletionResult {
        try await client.chatCompletion(
            system: system,
            user: user,
            config: config,
            useWebSearch: useWebSearch,
            useAuditTimeout: useAuditTimeout,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }

    // MARK: - 测试连接

    func testAIConnection(config: AIConfig) async -> (ok: Bool, message: String) {
        let start = Date()
        do {
            let res = try await chatCompletion(
                system: "You are a concise assistant.",
                user: "Reply OK",
                config: config,
                useWebSearch: false,
                maxTokens: 12,
                temperature: 0
            )
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            return (
                true,
                L10n.t("连接成功（实际模型：\(res.actualModel)，耗时 \(ms) ms）", "Connected (model: \(res.actualModel), \(ms) ms)")
            )
        } catch {
            let safeMsg = KeychainStore.redactSecret(config.apiKey, in: error.localizedDescription)
            return (false, L10n.t("连接失败：\(safeMsg)", "Failed: \(safeMsg)"))
        }
    }

    // MARK: - 单件器材识别

    func recognize(name: String, category: GearCategory, aiConfig: AIConfig = AIConfig()) async -> WebRecognitionResult {
        var aiFallbackNote: String? = nil

        if aiConfig.isReady {
            do {
                return try await recognizeViaLLM(name: name, category: category, config: aiConfig)
            } catch let secErr as EndpointSecurityError {
                aiFallbackNote = secErr.localizedDescription
            } catch {
                aiFallbackNote = L10n.t("AI 接口暂不可用，已回退免费识别", "AI unavailable, fell back to free lookup")
            }
        }

        var fallback = await recognizeFree(name: name, category: category)
        if let note = aiFallbackNote {
            fallback.sourceSummary = "\(note) · \(fallback.sourceSummary)"
        }
        return fallback
    }

    private func recognizeViaLLM(name: String, category: GearCategory, config: AIConfig) async throws -> WebRecognitionResult {
        let systemPrompt = """
        You are an expert wet-shaving gear archivist familiar with Badger & Blade, Damn Fine Shave, Reddit r/wetshaving, and official manufacturer catalogs.
        Given a user's gear entry and category, return ONLY a valid JSON object (no markdown fences, no commentary) using these exact keys:
        {
          "brand": string or null,
          "handleBrand": string or null,
          "model": string or null,
          "name": string or null,
          "razorType": one of ["Double Edge (DE)", "Single Edge (AC)", "Single Edge (GEM)", "Single Edge (Injector)", "Single Edge (半DE)", "盒刀", "Twin Blade", "直剃", "替刃", "其他"] or null,
          "isAdjustable": boolean or null,
          "isSlant": boolean or null,
          "material": one of ["不锈钢", "钛合金", "黄铜", "红铜", "青铜", "磷青铜", "铝合金", "锌合金"] or null,
          "plateType": one of ["SB", "OC", "DC"] or null,
          "gapOrSpec": string (MAX 10 chars, e.g. "0.99", "1.12+", "Standard", "Lite") or null,
          "notes": string (optional detailed specs such as blade exposure, weight, etc.) or null,
          "bladeType": one of ["DE", "AC", "GEM", "Injector", "盒刀头", "其他"] or null,
          "brushMaterial": one of ["獾毛", "人造丝", "猪鬃", "马毛", "羊毛", "混毛", "其他"] or null,
          "badgerTreatment": one of ["无漂", "漂尖"] or null,
          "badgerBand": one of ["二段", "三段"] or null,
          "knotSize": string like "26mm" or null,
          "knotShape": one of ["Fan", "Bulb", "Hybrid"] or null,
          "confidence": number between 0.0 and 1.0,
          "isCorrection": boolean,
          "note": short summary string
        }
        HARD RULES (MUST OBEY):
        1. "model" MUST preserve differentiating sub-model / version codes (e.g. "Next Level 112+", "Next Level 150++", "MR112+", "WR1 0.74", "BR-1"). Strip ONLY material suffixes (SS/Ti/Cu) and baseplate codes (OC/SB/DC) when redundant.
        2. "gapOrSpec" MUST ONLY contain an ultra-short spec (e.g. "0.99", "1.12+", "Standard", "Lite"), MAX 10 characters; leave null if none. Put long descriptions into "notes".
        3. "material" MUST strictly be ONE of ["不锈钢", "钛合金", "黄铜", "红铜", "青铜", "磷青铜", "铝合金", "锌合金"] or null.
        4. Every enum field MUST use the exact allowed value above; if uncertain, return null and set confidence < 0.70.
        5. For brushes (剃须刷), "brand" MUST be the knot brand; "handleBrand" is ONLY set for custom/hybrid handles from a different maker.
        6. For clone razors, set "brand" to "仿刀".
        """

        let completion = try await chatCompletion(
            system: systemPrompt,
            user: "Category: \(category.rawValue)\nGear input: \(name)",
            config: config,
            useWebSearch: true,
            temperature: 0.1
        )

        let jsonStr = AIClient.extractJSONObjectString(from: completion.content)
        guard let jsonData = jsonStr.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(RecognizeGearPayload.self, from: jsonData) else {
            throw AIClientError.invalidResponse
        }

        let suggestedBrand = GearSanitizer.sanitizeBrand(Self.cleanStr(parsed.brand))
        let suggestedHandle: String? = {
            guard category == .brush, let h = Self.cleanStr(parsed.handleBrand) else { return nil }
            if let b = suggestedBrand, h.lowercased() == b.lowercased() { return nil }
            return h
        }()
        let sanitizedModel = category == .razor ? GearSanitizer.sanitizeModel(Self.cleanStr(parsed.model)) : Self.cleanStr(parsed.model)
        let sanitizedMat = category == .razor ? GearSanitizer.sanitizeMaterialStrict(Self.cleanStr(parsed.material)) : nil
        let gapAndNotes = category == .razor
            ? GearSanitizer.sanitizeGapAndNotes(gapOrSpec: Self.cleanStr(parsed.gapOrSpec), existingNotes: nil, extraNotes: Self.cleanStr(parsed.notes))
            : (gapOrSpec: nil, notes: Self.cleanStr(parsed.notes))

        let confidence = max(0.0, min(0.99, parsed.confidence ?? 0.65))
        let webTag: String = {
            switch completion.webSearchEvidence {
            case .verifiedWithSources: return L10n.t(" · 已联网核验", " · Web-grounded")
            case .toolAcceptedUnverified: return L10n.t(" · 通道已接受联网参数（无引用元数据）", " · Web tool accepted (unverified grounding)")
            case .downgradedToPlain: return L10n.t(" · 已降级为常规推理", " · Downgraded to plain inference")
            case .notRequested: return ""
            }
        }()
        let note = Self.cleanStr(parsed.note)
        let summary = note != nil
            ? L10n.t("AI 识别（\(completion.actualModel)\(webTag)）：\(note!)", "AI (\(completion.actualModel)\(webTag)): \(note!)")
            : L10n.t("已通过 AI 接口识别（\(completion.actualModel)\(webTag)）", "Recognized via AI (\(completion.actualModel)\(webTag))")

        return WebRecognitionResult(
            suggestedBrand: suggestedBrand,
            suggestedHandleBrand: suggestedHandle,
            suggestedName: Self.cleanStr(parsed.name) ?? name,
            suggestedModel: sanitizedModel,
            razorType: category == .razor ? Self.cleanStr(parsed.razorType).flatMap(RazorType.init(rawValue:)) : nil,
            isAdjustable: category == .razor ? parsed.isAdjustable : nil,
            isSlant: category == .razor ? parsed.isSlant : nil,
            material: sanitizedMat,
            plateType: category == .razor ? Self.cleanStr(parsed.plateType).flatMap(PlateType.init(rawValue:)) : nil,
            gapOrSpec: gapAndNotes.gapOrSpec,
            notes: gapAndNotes.notes,
            bladeType: category == .blade ? Self.cleanStr(parsed.bladeType).flatMap(BladeType.init(rawValue:)) : nil,
            brushMaterial: category == .brush ? Self.cleanStr(parsed.brushMaterial).flatMap(BrushMaterial.init(rawValue:)) : nil,
            badgerTreatment: category == .brush ? Self.cleanStr(parsed.badgerTreatment).flatMap(BadgerTreatment.init(rawValue:)) : nil,
            badgerBand: category == .brush ? Self.cleanStr(parsed.badgerBand).flatMap(BadgerBand.init(rawValue:)) : nil,
            knotSize: category == .brush ? Self.cleanStr(parsed.knotSize) : nil,
            knotShape: category == .brush ? Self.cleanStr(parsed.knotShape).flatMap(BrushKnotShape.init(rawValue:)) : nil,
            confidence: confidence,
            sourceSummary: summary,
            sourceURL: nil,
            isCorrection: parsed.isCorrection ?? false,
            webSearchVerified: completion.webSearchEvidence == .verifiedWithSources
        )
    }

    // MARK: - AI 功能 ①：全库 AI 体检（S08：逐项状态追踪、未知/重复 ID 拒绝、截断遗漏绝不计为成功）

    func auditGearItems(
        items: [GearItem],
        aiConfig: AIConfig,
        onProgress: (@MainActor @Sendable (GearAuditProgress) -> Void)? = nil
    ) async throws -> GearAuditReport {
        guard aiConfig.isReady else { throw AIClientError.apiNotEnabled }
        _ = try EndpointSecurityValidator.validatedURL(aiConfig.baseURL, allowLocalHTTP: true, contextLabel: "Base URL")

        guard !items.isEmpty else {
            return GearAuditReport(
                updates: [],
                merges: [],
                modelUsed: aiConfig.model,
                plannedCount: 0,
                verifiedCount: 0,
                undeterminedItems: [],
                failedItems: [],
                skippedCount: 0,
                unknownOrDuplicateIDCount: 0,
                itemStatuses: [:],
                failures: []
            )
        }

        let itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let snapshotByID = Dictionary(items.map { ($0.id, $0.snapshotFingerprint) }, uniquingKeysWith: { first, _ in first })
        let langHint = L10n.isEnglish ? "English" : "Simplified Chinese"

        let systemPrompt = """
        You are a wet-shaving database auditor (Badger & Blade / Damn Fine Shave / official maker standards).
        You MUST account for EVERY SINGLE input item id in the JSON array returned below (no omissions, no invented IDs, no duplicate IDs).
        Return ONLY a valid JSON object (no markdown fences) with this exact schema:
        {
          "checkedIds": ["<exact input item ids verified accurate and needing NO changes>"],
          "undeterminedIds": ["<exact input item ids that cannot be reliably verified>"],
          "updates": [
            {
              "id": "<exact input item id needing correction or missing-spec fill>",
              "brand": string or null,
              "handleBrand": string or null,
              "model": string or null,
              "name": string or null,
              "razorType": one of ["Double Edge (DE)", "Single Edge (AC)", "Single Edge (GEM)", "Single Edge (Injector)", "Single Edge (半DE)", "盒刀", "Twin Blade", "直剃", "替刃", "其他"] or null,
              "isAdjustable": boolean or null,
              "isSlant": boolean or null,
              "material": one of ["不锈钢", "钛合金", "黄铜", "红铜", "青铜", "磷青铜", "铝合金", "锌合金"] or null,
              "plateType": one of ["SB", "OC", "DC"] or null,
              "gapOrSpec": string (MAX 10 chars, e.g. "0.99", "1.12+", "Standard", "Lite") or null,
              "notes": string (detailed specs like blade exposure, weight, etc.) or null,
              "bladeType": one of ["DE", "AC", "GEM", "Injector", "盒刀头", "其他"] or null,
              "brushMaterial": one of ["獾毛", "人造丝", "猪鬃", "马毛", "羊毛", "混毛", "其他"] or null,
              "badgerTreatment": one of ["无漂", "漂尖"] or null,
              "badgerBand": one of ["二段", "三段"] or null,
              "knotSize": string or null,
              "knotShape": one of ["Fan", "Bulb", "Hybrid"] or null,
              "confidence": number 0.0-1.0,
              "reason": "short explanation in \(langHint)"
            }
          ],
          "merges": [
            {
              "sourceId": "<item id to merge away>",
              "targetId": "<canonical item id to keep>",
              "reason": "short explanation in \(langHint)"
            }
          ]
        }
        HARD RULES (MUST OBEY):
        1. Every input id MUST appear in EXACTLY ONE of "checkedIds", "undeterminedIds", or "updates". NEVER omit an input id and NEVER invent IDs not in the input.
        2. "model" MUST keep differentiating sub-model/version codes (e.g. "Next Level 112+", "WR1 0.74", "BR-1").
        3. "gapOrSpec" MUST ONLY be an ultra-short spec (MAX 10 chars); put long descriptions into "notes".
        4. "material" MUST strictly be ONE of ["不锈钢", "钛合金", "黄铜", "红铜", "青铜", "磷青铜", "铝合金", "锌合金"] or null.
        5. Every enum field MUST use the exact allowed values above; if uncertain, put the id in "undeterminedIds" or set confidence < 0.70.
        6. For brushes, "brand" = knot brand, "handleBrand" = custom handle brand (null if factory).
        7. ONLY suggest "merges" for clearly duplicate items; NEVER merge different gaps, materials, baseplates, knot sizes, or Fan vs Bulb.
        """

        var allUpdates: [GearAuditUpdateProposal] = []
        var allMerges: [GearAuditMergeProposal] = []
        var undeterminedItems: [GearItem] = []
        var failedItems: [GearItem] = []
        var failures: [GearAuditBatchFailure] = []
        var itemStatuses: [String: GearAuditItemStatus] = [:]
        var verifiedCount = 0
        var skippedCount = 0
        var unknownOrDuplicateIDCount = 0
        var modelUsed = aiConfig.model

        let webSearchEnabled = aiConfig.shouldUseDeepSeekWebSearch || aiConfig.shouldUseGoogleSearch
        let batchSize = webSearchEnabled ? 6 : 8
        let totalBatches = max(1, (items.count + batchSize - 1) / batchSize)

        func emitProgress(_ currentBatch: Int) async {
            guard let onProgress else { return }
            let progress = GearAuditProgress(
                currentBatch: currentBatch,
                totalBatches: totalBatches,
                plannedCount: items.count,
                verifiedCount: verifiedCount,
                undeterminedCount: undeterminedItems.count,
                failedCount: failedItems.count,
                skippedCount: skippedCount
            )
            await onProgress(progress)
        }

        var idx = 0
        var batchIndex = 0
        while idx < items.count {
            try Task.checkCancellation()
            batchIndex += 1
            let chunk = Array(items[idx..<min(idx + batchSize, items.count)])
            idx += batchSize
            await emitProgress(batchIndex)

            let payloadItems = chunk.map { it in
                AuditBatchItemInput(
                    id: it.id,
                    category: it.category.rawValue,
                    brand: it.brand,
                    model: it.model,
                    name: it.name,
                    count: it.count,
                    pending: it.isPending,
                    manuallyConfirmed: it.isManuallyConfirmed,
                    razorType: it.razorType?.rawValue,
                    isAdjustable: it.isAdjustable ? true : nil,
                    isSlant: it.isSlant ? true : nil,
                    material: it.material,
                    plateType: it.plateType?.rawValue,
                    gapOrSpec: it.gapOrSpec,
                    notes: it.notes,
                    bladeType: it.bladeType?.rawValue,
                    handleBrand: it.handleBrand,
                    brushMaterial: it.brushMaterial?.rawValue,
                    badgerTreatment: it.badgerTreatment?.rawValue,
                    badgerBand: it.badgerBand?.rawValue,
                    knotSize: it.knotSize,
                    knotShape: it.knotShape?.rawValue
                )
            }

            let userPrompt: String
            do {
                let jsonBytes = try JSONEncoder().encode(payloadItems)
                userPrompt = String(data: jsonBytes, encoding: .utf8) ?? "[]"
            } catch {
                let reason = L10n.t("构造请求 JSON 失败：\(error.localizedDescription)", "Failed to encode batch payload: \(error.localizedDescription)")
                for it in chunk { itemStatuses[it.id] = .failed }
                failedItems.append(contentsOf: chunk)
                failures.append(GearAuditBatchFailure(batchIndex: batchIndex, items: chunk, reason: reason))
                await emitProgress(batchIndex)
                continue
            }

            let completion: AIChatCompletionResult
            do {
                completion = try await chatCompletion(
                    system: systemPrompt,
                    user: userPrompt,
                    config: aiConfig,
                    useWebSearch: true,
                    useAuditTimeout: true,
                    temperature: 0.1
                )
                modelUsed = completion.actualModel
            } catch is CancellationError {
                throw AIClientError.cancelled
            } catch AIClientError.cancelled {
                throw AIClientError.cancelled
            } catch {
                let safeReason = KeychainStore.redactSecret(aiConfig.apiKey, in: error.localizedDescription)
                for it in chunk { itemStatuses[it.id] = .failed }
                failedItems.append(contentsOf: chunk)
                failures.append(GearAuditBatchFailure(batchIndex: batchIndex, items: chunk, reason: safeReason))
                await emitProgress(batchIndex)
                continue
            }

            let jsonStr = AIClient.extractJSONObjectString(from: completion.content)
            guard let parsedData = jsonStr.data(using: .utf8),
                  let batchResp = try? JSONDecoder().decode(AuditBatchResponsePayload.self, from: parsedData),
                  (batchResp.checkedIds != nil || batchResp.undeterminedIds != nil || batchResp.updates != nil || batchResp.merges != nil) else {
                let reason = L10n.t("AI 返回内容解析失败（非预期 JSON 结构）", "Failed to parse AI response as valid audit JSON")
                for it in chunk { itemStatuses[it.id] = .failed }
                failedItems.append(contentsOf: chunk)
                failures.append(GearAuditBatchFailure(batchIndex: batchIndex, items: chunk, reason: reason))
                await emitProgress(batchIndex)
                continue
            }

            let chunkIDs = Set(chunk.map(\.id))
            var occurrenceCounts: [String: Int] = [:]
            var updatePayloadByID: [String: AuditUpdatePayload] = [:]
            var checkedSet: Set<String> = []
            var undeterminedSet: Set<String> = []

            for cid in (batchResp.checkedIds ?? []) {
                guard chunkIDs.contains(cid) else {
                    unknownOrDuplicateIDCount += 1
                    continue
                }
                occurrenceCounts[cid, default: 0] += 1
                checkedSet.insert(cid)
            }

            for uid in (batchResp.undeterminedIds ?? []) {
                guard chunkIDs.contains(uid) else {
                    unknownOrDuplicateIDCount += 1
                    continue
                }
                occurrenceCounts[uid, default: 0] += 1
                undeterminedSet.insert(uid)
            }

            for u in (batchResp.updates ?? []) {
                guard chunkIDs.contains(u.id) else {
                    unknownOrDuplicateIDCount += 1
                    continue
                }
                occurrenceCounts[u.id, default: 0] += 1
                if updatePayloadByID[u.id] == nil {
                    updatePayloadByID[u.id] = u
                }
            }

            var missingOrAmbiguousInBatch: [GearItem] = []

            for orig in chunk {
                let count = occurrenceCounts[orig.id] ?? 0
                if count == 0 {
                    // S08：模型响应遗漏/截断了该器材，绝不计为成功
                    itemStatuses[orig.id] = .failed
                    missingOrAmbiguousInBatch.append(orig)
                    continue
                }
                if count > 1 {
                    // S08：同一器材在同一批响应中出现多次或状态冲突，记为异常并要求重试
                    unknownOrDuplicateIDCount += (count - 1)
                    itemStatuses[orig.id] = .failed
                    missingOrAmbiguousInBatch.append(orig)
                    continue
                }

                if checkedSet.contains(orig.id) {
                    itemStatuses[orig.id] = .unchanged
                    verifiedCount += 1
                    continue
                }

                if undeterminedSet.contains(orig.id) {
                    itemStatuses[orig.id] = .undetermined
                    undeterminedItems.append(orig)
                    continue
                }

                if let u = updatePayloadByID[orig.id] {
                    if let proposal = Self.buildAuditProposal(
                        orig: orig,
                        payload: u,
                        actualModel: completion.actualModel,
                        snapshotFingerprint: snapshotByID[orig.id] ?? orig.snapshotFingerprint
                    ) {
                        allUpdates.append(proposal)
                        itemStatuses[orig.id] = .suggestedUpdate
                        verifiedCount += 1
                    } else {
                        if orig.isManuallyConfirmed {
                            itemStatuses[orig.id] = .skippedManual
                            skippedCount += 1
                        } else {
                            itemStatuses[orig.id] = .unchanged
                            verifiedCount += 1
                        }
                    }
                }
            }

            if !missingOrAmbiguousInBatch.isEmpty {
                failedItems.append(contentsOf: missingOrAmbiguousInBatch)
                failures.append(GearAuditBatchFailure(
                    batchIndex: batchIndex,
                    items: missingOrAmbiguousInBatch,
                    reason: L10n.t(
                        "AI 响应遗漏或重复返回了 \(missingOrAmbiguousInBatch.count) 件器材（已拒收，未计入完成）",
                        "AI omitted or duplicated \(missingOrAmbiguousInBatch.count) item(s); rejected and marked incomplete"
                    )
                ))
            }

            for m in (batchResp.merges ?? []) {
                guard m.sourceId != m.targetId,
                      let src = itemByID[m.sourceId],
                      let dst = itemByID[m.targetId],
                      src.category == dst.category else {
                    unknownOrDuplicateIDCount += 1
                    continue
                }
                if GearMergeGuard.conflictReason(source: src, target: dst) != nil {
                    skippedCount += 1
                    continue
                }
                let reason = Self.cleanStr(m.reason) ?? L10n.t("疑似重复条目", "Suspected duplicate")
                if !allMerges.contains(where: { $0.source.id == src.id && $0.target.id == dst.id }) {
                    allMerges.append(GearAuditMergeProposal(
                        source: src,
                        target: dst,
                        reason: reason,
                        selected: !(src.isManuallyConfirmed || dst.isManuallyConfirmed),
                        sourceSnapshotFingerprint: snapshotByID[src.id] ?? src.snapshotFingerprint,
                        targetSnapshotFingerprint: snapshotByID[dst.id] ?? dst.snapshotFingerprint
                    ))
                }
            }

            await emitProgress(batchIndex)
        }

        return GearAuditReport(
            updates: allUpdates,
            merges: allMerges,
            modelUsed: modelUsed,
            plannedCount: items.count,
            verifiedCount: verifiedCount,
            undeterminedItems: undeterminedItems,
            failedItems: failedItems,
            skippedCount: skippedCount,
            unknownOrDuplicateIDCount: unknownOrDuplicateIDCount,
            itemStatuses: itemStatuses,
            failures: failures
        )
    }

    private nonisolated static func buildAuditProposal(
        orig: GearItem,
        payload u: AuditUpdatePayload,
        actualModel: String,
        snapshotFingerprint: String
    ) -> GearAuditUpdateProposal? {
        let protectManual = orig.isManuallyConfirmed
        let brandIsUnknown = orig.brand == "品牌未注明" || orig.brand == "无品牌" || orig.brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var rawOv = GearOverride.from(item: orig, recognizedSource: "AI 体检 (\(actualModel))")
        if !protectManual || brandIsUnknown, let b = cleanStr(u.brand) { rawOv.brand = b }
        if !protectManual, let n = cleanStr(u.name) { rawOv.name = n }
        if !protectManual, let m = cleanStr(u.model) { rawOv.model = m }

        switch orig.category {
        case .razor:
            if (!protectManual || orig.razorType == nil), let rt = cleanStr(u.razorType).flatMap(RazorType.init(rawValue:)) {
                rawOv.razorType = rt
            }
            if !protectManual, let adj = u.isAdjustable { rawOv.isAdjustable = adj }
            if !protectManual, let sl = u.isSlant { rawOv.isSlant = sl }
            if (!protectManual || orig.material == nil), let mat = GearSanitizer.sanitizeMaterialStrict(cleanStr(u.material)) {
                rawOv.material = mat
            }
            if (!protectManual || orig.plateType == nil), let pt = cleanStr(u.plateType).flatMap(PlateType.init(rawValue:)) {
                rawOv.plateType = pt
            }
            if (!protectManual || orig.gapOrSpec == nil), let gap = cleanStr(u.gapOrSpec) {
                rawOv.gapOrSpec = gap
            }
        case .blade:
            if (!protectManual || orig.bladeType == nil), let bt = cleanStr(u.bladeType).flatMap(BladeType.init(rawValue:)) {
                rawOv.bladeType = bt
            }
        case .brush:
            if (!protectManual || orig.handleBrand == nil), let hb = cleanStr(u.handleBrand) { rawOv.handleBrand = hb }
            if (!protectManual || orig.brushMaterial == nil), let bm = cleanStr(u.brushMaterial).flatMap(BrushMaterial.init(rawValue:)) {
                rawOv.brushMaterial = bm
            }
            if (!protectManual || orig.badgerTreatment == nil), let tr = cleanStr(u.badgerTreatment).flatMap(BadgerTreatment.init(rawValue:)) {
                rawOv.badgerTreatment = tr
            }
            if (!protectManual || orig.badgerBand == nil), let bb = cleanStr(u.badgerBand).flatMap(BadgerBand.init(rawValue:)) {
                rawOv.badgerBand = bb
            }
            if (!protectManual || orig.knotSize == nil), let ks = cleanStr(u.knotSize) { rawOv.knotSize = ks }
            if (!protectManual || orig.knotShape == nil), let sh = cleanStr(u.knotShape).flatMap(BrushKnotShape.init(rawValue:)) {
                rawOv.knotShape = sh
            }
        default:
            break
        }

        let ov = GearSanitizer.sanitizeOverride(
            rawOv,
            category: orig.category,
            extraNotes: (protectManual && orig.notes != nil) ? nil : cleanStr(u.notes)
        )

        var diffs: [String] = []
        if ov.brand != orig.brand { diffs.append("\(L10n.t("品牌", "Brand")): \(orig.brand) → \(ov.brand)") }
        if ov.displayModel != orig.model { diffs.append("\(L10n.t("型号", "Model")): \(orig.model) → \(ov.displayModel)") }
        if ov.name != orig.name { diffs.append("\(L10n.t("全称", "Name")): \(orig.name) → \(ov.name)") }
        if ov.razorType != orig.razorType, let v = ov.razorType { diffs.append("\(L10n.t("刀型", "Type")): \(orig.razorType?.shortLabel ?? "—") → \(v.shortLabel)") }
        if ov.material != orig.material, let v = ov.material { diffs.append("\(L10n.t("材质", "Material")): \(orig.material ?? "—") → \(L10n.materialDisplay(v))") }
        if ov.plateType != orig.plateType, let v = ov.plateType { diffs.append("\(L10n.t("底板", "Plate")): \(orig.plateType?.rawValue ?? "—") → \(v.rawValue)") }
        if (ov.isSlant ?? false) != orig.isSlant { diffs.append("Slant: \(orig.isSlant ? "Yes" : "No") → \((ov.isSlant ?? false) ? "Yes" : "No")") }
        if (ov.isAdjustable ?? false) != orig.isAdjustable { diffs.append("\(L10n.t("可调", "Adj")): \(orig.isAdjustable ? "Yes" : "No") → \((ov.isAdjustable ?? false) ? "Yes" : "No")") }
        if ov.gapOrSpec != orig.gapOrSpec { diffs.append("\(L10n.t("规格", "Spec")): \(orig.gapOrSpec ?? "—") → \(ov.gapOrSpec ?? "—")") }
        if ov.notes != orig.notes, let v = ov.notes { diffs.append("\(L10n.t("详细参数", "Notes")): \(orig.notes ?? "—") → \(v)") }
        if ov.bladeType != orig.bladeType, let v = ov.bladeType { diffs.append("\(L10n.t("刀片型", "Blade")): \(orig.bladeType?.rawValue ?? "—") → \(v.rawValue)") }
        if ov.handleBrand != orig.handleBrand { diffs.append("\(L10n.t("手柄", "Handle")): \(orig.handleBrand ?? "—") → \(ov.handleBrand ?? "—")") }
        if ov.brushMaterial != orig.brushMaterial, let v = ov.brushMaterial { diffs.append("\(L10n.t("刷毛", "Hair")): \(orig.brushMaterial?.displayName ?? "—") → \(v.displayName)") }
        if ov.badgerTreatment != orig.badgerTreatment, let v = ov.badgerTreatment { diffs.append("\(L10n.t("处理", "Tips")): \(orig.badgerTreatment?.displayName ?? "—") → \(v.displayName)") }
        if ov.badgerBand != orig.badgerBand, let v = ov.badgerBand { diffs.append("\(L10n.t("段数", "Band")): \(orig.badgerBand?.displayName ?? "—") → \(v.displayName)") }
        if ov.knotSize != orig.knotSize, let v = ov.knotSize { diffs.append("\(L10n.t("结径", "Size")): \(orig.knotSize ?? "—") → \(v)") }
        if ov.knotShape != orig.knotShape, let v = ov.knotShape { diffs.append("\(L10n.t("毛型", "Shape")): \(orig.knotShape?.rawValue ?? "—") → \(v.rawValue)") }

        guard !diffs.isEmpty else { return nil }
        let conf = max(0.0, min(0.99, u.confidence ?? 0.78))
        let reason = cleanStr(u.reason) ?? L10n.t("官网规范与属性补全", "Standardized naming & specs")
        return GearAuditUpdateProposal(
            item: orig,
            proposed: ov,
            changesSummary: diffs,
            reason: reason,
            confidence: conf,
            selected: !protectManual && conf >= 0.72,
            sourceSnapshotFingerprint: snapshotFingerprint
        )
    }

    // MARK: - AI 功能 ②：一句话自然语言快速记 SOTD

    func parseNaturalLanguageSOTD(
        sentence: String,
        catalog: [GearCategory: [String]],
        aiConfig: AIConfig
    ) async throws -> AINaturalSOTDResult {
        guard aiConfig.isReady else { throw AIClientError.apiNotEnabled }

        let catalogDesc = GearCategory.allCases.map { cat in
            let names = (catalog[cat] ?? []).prefix(45).joined(separator: " | ")
            return "\(cat.rawValue): \(names)"
        }.joined(separator: "\n")

        let systemPrompt = """
        You parse a wet-shaving SOTD sentence into structured fields matched against the user's real gear catalog.
        Return ONLY a valid JSON object (no markdown fences):
        {
          "razor": exact matching name from catalog or user text (or null),
          "blade": exact matching base blade name from catalog without 1st/2nd suffix (or null),
          "bladeUseCount": integer >= 1 or null,
          "brush": exact matching name from catalog or user text (or null),
          "soap": exact matching name from catalog or user text (or null),
          "bowl": exact matching name from catalog or user text (or null),
          "preShave": exact matching name from catalog or user text (or null),
          "afterShave": exact matching name from catalog or user text (or null),
          "loadingMethod": one of ["挖取", "刷取", "涂抹"] or null,
          "latheringMethod": one of ["碗起", "脸起", "手起"] or null,
          "hotTowel": boolean or null,
          "afterShower": boolean or null,
          "useAlum": boolean or null,
          "passes": [{"pass": one of ["顺刮", "横刮", "逆刮", "补刀"], "setting": string like "5" or ""}],
          "result": one of ["BBS", "DFS", "CCS", "SAS"] or null,
          "irritation": one of ["无痛", "微痛", "刺痛"] or null,
          "note": short extra note string or null
        }
        Match Chinese nicknames to catalog names when obvious (e.g. 黑鸟钛 -> Blackland Blackbird Ti, 俄纸 -> Gillette 俄产纸飞机, 苦艾 -> MDC Absinthe).
        """

        let completion = try await chatCompletion(
            system: systemPrompt,
            user: "User's gear catalog:\n\(catalogDesc)\n\nSOTD sentence:\n\(sentence)",
            config: aiConfig,
            useWebSearch: false,
            temperature: 0.1
        )

        let jsonStr = AIClient.extractJSONObjectString(from: completion.content)
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(NaturalSOTDPayload.self, from: data) else {
            throw AIClientError.invalidResponse
        }

        let passes: [PassStep] = (parsed.passes ?? []).compactMap { p in
            guard let pt = ShavePassType(rawValue: p.pass) else { return nil }
            return PassStep(pass: pt, setting: p.setting ?? "")
        }

        return AINaturalSOTDResult(
            razor: Self.cleanStr(parsed.razor),
            blade: Self.cleanStr(parsed.blade),
            bladeUseCount: parsed.bladeUseCount,
            brush: Self.cleanStr(parsed.brush),
            soap: Self.cleanStr(parsed.soap),
            bowl: Self.cleanStr(parsed.bowl),
            preShave: Self.cleanStr(parsed.preShave),
            afterShave: Self.cleanStr(parsed.afterShave),
            loadingMethod: Self.cleanStr(parsed.loadingMethod).flatMap(SoapLoadingMethod.init(rawValue:)),
            latheringMethod: Self.cleanStr(parsed.latheringMethod).flatMap(LatheringMethod.init(rawValue:)),
            hotTowel: parsed.hotTowel,
            afterShower: parsed.afterShower,
            useAlum: parsed.useAlum,
            passes: passes,
            result: Self.cleanStr(parsed.result).flatMap(ShaveResult.init(rawValue:)),
            irritation: Self.cleanStr(parsed.irritation).flatMap(IrritationLevel.init(rawValue:)),
            note: Self.cleanStr(parsed.note)
        )
    }

    // MARK: - AI 功能 ②-B：SOTD 拍照 / 传图多模态装备识别

    func recognizeSOTDPhoto(
        imageDataURL: String,
        catalog: [GearCategory: [String]],
        aiConfig: AIConfig
    ) async throws -> AIPhotoSOTDResult {
        guard aiConfig.isReady else { throw AIClientError.apiNotEnabled }

        let catalogDesc = GearCategory.allCases.map { cat in
            let names = (catalog[cat] ?? []).prefix(60).joined(separator: " | ")
            return "\(cat.rawValue): \(names.isEmpty ? "(空)" : names)"
        }.joined(separator: "\n")

        let langHint = L10n.isEnglish ? "English" : "Simplified Chinese"

        let systemPrompt = """
        You are an expert traditional wet-shaving gear archivist identifying shaving gear from a SOTD (Shave of the Day) photo.
        Return ONLY a valid JSON object (no markdown fences, no commentary) using these exact keys:
        {
          "razor": exact matching name from the user's catalog, or clearly visible brand + model if not in catalog (or null),
          "blade": exact matching base blade name from the user's catalog WITHOUT 1st/2nd suffix, or clearly visible blade name (or null),
          "brush": exact matching name from the user's catalog, or clearly visible brush name (or null),
          "soap": exact matching name from the user's catalog, or clearly visible soap name (or null),
          "bowl": exact matching name from the user's catalog, or clearly visible shaving bowl name (or null),
          "preShave": exact matching name from the user's catalog, or clearly visible pre-shave name (or null),
          "afterShave": exact matching name from the user's catalog, or clearly visible aftershave name (or null),
          "uncertainNote": short reminder in \(langHint) about any uncertain, partially obscured, or visually ambiguous items (or null if all recognized items are confident)
        }
        HARD RULES (MUST OBEY):
        1. ALWAYS prioritize exact names from the user's in-hand gear catalog below whenever an item in the photo matches one.
        2. If a category is NOT shown in the photo or is too blurry/obscured to recognize reliably, return null. NEVER fabricate or guess items not present in the photo.
        3. For "blade", return ONLY the base blade name (no 1st/2nd/3rd use count).
        4. If an item is ambiguous between candidates or partially occluded, briefly remind the user to verify it in "uncertainNote".
        """

        let userText = """
        User's current in-hand gear catalog:
        \(catalogDesc)

        Please inspect the attached SOTD photo, match visible gear against the catalog above first, leave absent or unclear categories as null, and return the JSON object only.
        """

        let completion = try await client.chatCompletion(
            system: systemPrompt,
            user: userText,
            imageDataURL: imageDataURL,
            config: aiConfig,
            useWebSearch: false,
            useAuditTimeout: false,
            temperature: 0.1
        )

        let jsonStr = AIClient.extractJSONObjectString(from: completion.content)
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PhotoSOTDPayload.self, from: data) else {
            throw AIClientError.invalidResponse
        }

        return AIPhotoSOTDResult(
            razor: Self.cleanStr(parsed.razor),
            blade: Self.cleanStr(parsed.blade),
            brush: Self.cleanStr(parsed.brush),
            soap: Self.cleanStr(parsed.soap),
            bowl: Self.cleanStr(parsed.bowl),
            preShave: Self.cleanStr(parsed.preShave),
            afterShave: Self.cleanStr(parsed.afterShave),
            uncertainNote: Self.cleanStr(parsed.uncertainNote) ?? Self.cleanStr(parsed.note)
        )
    }

    // MARK: - AI 功能 ③：AI 智能配装顾问

    func recommendSetup(
        requirement: String,
        eligibleByCategory: [GearCategory: [GearItem]],
        comboStats: [RazorBladeComboStat],
        aiConfig: AIConfig
    ) async throws -> AISetupRecommendation {
        guard aiConfig.isReady else { throw AIClientError.apiNotEnabled }

        let langHint = L10n.isEnglish ? "English" : "Simplified Chinese"
        var invLines: [String] = []
        for cat in GearCategory.allCases {
            let list = eligibleByCategory[cat] ?? []
            let summary = list.prefix(50).map { item -> String in
                var meta: [String] = ["uses:\(item.count)"]
                if !item.lastUsedDate.isEmpty { meta.append("last:\(item.lastUsedDate)") }
                if let rt = item.razorType { meta.append(rt.shortLabel) }
                if let bt = item.bladeType { meta.append("blade:\(bt.rawValue)") }
                if let pt = item.plateType { meta.append(pt.rawValue) }
                if let gap = item.gapOrSpec, !gap.isEmpty { meta.append("gap:\(gap)") }
                if item.isAdjustable { meta.append("adjustable") }
                if item.isSlant { meta.append("slant") }
                if let bm = item.brushMaterial { meta.append(bm.rawValue) }
                if let ks = item.knotSize { meta.append(ks) }
                if item.isSample { meta.append("sample") }
                return "\(item.name) [\(meta.joined(separator: ","))]"
            }.joined(separator: "; ")
            invLines.append("\(cat.rawValue): \(summary)")
        }

        let topGolden = comboStats.filter { $0.uses >= 2 && $0.stingingCount == 0 }.prefix(10)
            .map { "\($0.razorName) + \($0.bladeName) (uses:\($0.uses), painless:\(Int($0.painlessRate * 100))%, BBS:\(Int($0.bbsRate * 100))%)" }
            .joined(separator: "; ")
        let warningCombos = comboStats.filter { $0.stingingCount > 0 }.prefix(8)
            .map { "\($0.razorName) + \($0.bladeName) (stinging:\($0.stingingCount)/\($0.uses))" }
            .joined(separator: "; ")

        let systemPrompt = """
        You are a wet-shaving setup advisor. Recommend ONE cohesive SOTD setup strictly from the user's eligible in-hand gear list.
        Return ONLY a valid JSON object (no markdown fences):
        {
          "razor": "<exact name from 剃须刀 list>",
          "blade": "<exact name from 刀片 list matching razor type, or null if straight razor>",
          "brush": "<exact name from 剃须刷 list>",
          "soap": "<exact name from 剃须皂 list>",
          "bowl": "<exact name from 剃须碗 list or null>",
          "preShave": "<exact name from 须前 list or null>",
          "afterShave": "<exact name from 须后 list or null>",
          "reason": "2-3 concise sentences in \(langHint) explaining why this pairing fits the request"
        }
        CRITICAL RULES:
        1. You MUST pick exact names present in the provided inventory.
        2. Blade type MUST strictly match razor type: DE/SE·半DE/Twin Blade -> blade:DE; SE·AC/替刃 -> blade:AC; SE·GEM -> blade:GEM; SE·Injector -> blade:Injector; 盒刀 -> blade:盒刀头; 直剃 -> null.
        3. Avoid combinations in the high-stinging list when the user asks for gentle/painless shaves.
        """

        let userPrompt = """
        User request: \(requirement)

        Eligible in-hand gear:
        \(invLines.joined(separator: "\n"))

        Proven painless combos: \(topGolden.isEmpty ? "none" : topGolden)
        High-stinging combos to avoid: \(warningCombos.isEmpty ? "none" : warningCombos)
        """

        let completion = try await chatCompletion(
            system: systemPrompt,
            user: userPrompt,
            config: aiConfig,
            useWebSearch: false,
            temperature: 0.35
        )

        let jsonStr = AIClient.extractJSONObjectString(from: completion.content)
        guard let data = jsonStr.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SetupRecommendationPayload.self, from: data) else {
            throw AIClientError.invalidResponse
        }

        return AISetupRecommendation(
            razorName: Self.cleanStr(parsed.razor),
            bladeName: Self.cleanStr(parsed.blade),
            brushName: Self.cleanStr(parsed.brush),
            soapName: Self.cleanStr(parsed.soap),
            bowlName: Self.cleanStr(parsed.bowl),
            preShaveName: Self.cleanStr(parsed.preShave),
            afterShaveName: Self.cleanStr(parsed.afterShave),
            reason: Self.cleanStr(parsed.reason) ?? ""
        )
    }

    // MARK: - AI 功能 ④：AI 个人湿剃复盘诊断

    func generateShaveDiagnosis(statsSummary: String, aiConfig: AIConfig) async throws -> (text: String, model: String) {
        guard aiConfig.isReady else { throw AIClientError.apiNotEnabled }
        let langHint = L10n.isEnglish ? "English" : "Simplified Chinese"
        let systemPrompt = """
        You are an experienced traditional wet-shaving coach.
        Analyze the user's real aggregated SOTD statistics and write a concise, practical, data-backed review in \(langHint).
        Structure your response cleanly into 3 short sections with plain headings and bullet points (under 350 words):
        1. Core Strengths & Golden Combos
        2. Irritation Triggers & Routine Insights (hot towel / post-shower / lather method / blade pairings)
        3. 3 Actionable Next-Month Recommendations
        Avoid fluff; cite the user's actual gear and percentages.
        """
        let completion = try await chatCompletion(
            system: systemPrompt,
            user: statsSummary,
            config: aiConfig,
            useWebSearch: false,
            temperature: 0.35
        )
        return (completion.content.trimmingCharacters(in: .whitespacesAndNewlines), completion.actualModel)
    }

    private nonisolated static func cleanStr(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: - 免费本地资料库 + 社区联网识别（默认 / 自动回退）

    private func recognizeFree(name: String, category: GearCategory) async -> WebRecognitionResult {
        let (spellFixed, wasCorrected) = GearKnowledgeBase.quickSpellCorrect(name, category: category)
        let localGuess = GearKnowledgeBase.inferDefaultOverride(rawName: spellFixed, category: category)

        let communityResult: (snippets: [String], sources: [String], primaryURL: String?) = enableFreeCommunityFallback
            ? await queryCommunityReference(query: spellFixed, category: category)
            : ([], [], nil)
        let combinedText = ([spellFixed] + communityResult.snippets).joined(separator: " \n ")

        var detectedBrand = localGuess.brand
        if detectedBrand == "品牌未注明" {
            let lowerAll = combinedText.lowercased()
            for item in GearKnowledgeBase.knownBrands {
                let token = item.prefix.trimmingCharacters(in: .whitespaces)
                if token.count >= 2 && lowerAll.contains(token) {
                    detectedBrand = item.canonical
                    break
                }
            }
        }
        if category == .razor && GearKnowledgeBase.isCloneRazor(spellFixed) {
            detectedBrand = "仿刀"
        }

        var razorType = localGuess.razorType
        var isAdjustable = localGuess.isAdjustable
        var isSlant = localGuess.isSlant
        var material = localGuess.material
        var plateType = localGuess.plateType
        var gapOrSpec = localGuess.gapOrSpec
        var bladeType = localGuess.bladeType
        let handleBrand = localGuess.handleBrand
        var brushMaterial = localGuess.brushMaterial
        var badgerTreatment = localGuess.badgerTreatment
        var badgerBand = localGuess.badgerBand
        var knotSize = localGuess.knotSize
        var knotShape = localGuess.knotShape

        if category == .razor {
            if let webType = inferRazorTypeFromText(combinedText), razorType == nil || razorType == .de {
                razorType = webType
            }
            if isAdjustable != true {
                let lowerWeb = combinedText.lowercased()
                if lowerWeb.contains("adjustable razor") || lowerWeb.contains("adjustable safety") || lowerWeb.contains("adjustable de") || lowerWeb.contains("adjustable se") {
                    isAdjustable = true
                }
            }
            if isSlant != true, GearKnowledgeBase.inferIsSlant(from: combinedText) { isSlant = true }
            if material == nil { material = GearKnowledgeBase.inferMaterial(from: combinedText) }
            if plateType == nil { plateType = GearKnowledgeBase.inferPlateType(from: combinedText) }
            if gapOrSpec == nil { gapOrSpec = extractGapSpec(from: spellFixed) }
        } else if category == .blade {
            if bladeType == nil { bladeType = GearKnowledgeBase.inferBladeType(from: combinedText) }
        } else if category == .brush {
            let webBrush = GearKnowledgeBase.inferBrushAttributes(from: combinedText)
            if brushMaterial == nil { brushMaterial = webBrush.material }
            if badgerTreatment == nil { badgerTreatment = webBrush.treatment }
            if badgerBand == nil { badgerBand = webBrush.band }
            if knotSize == nil { knotSize = webBrush.knotSize }
            if knotShape == nil { knotShape = webBrush.knotShape }
        }

        var confidence: Double = 0.25
        if detectedBrand != "品牌未注明" { confidence += 0.30 }
        if !communityResult.sources.isEmpty { confidence += 0.25 }
        switch category {
        case .razor:
            if material != nil { confidence += 0.10 }
            if plateType != nil || (isAdjustable == true) { confidence += 0.10 }
        case .blade:
            if bladeType != nil { confidence += 0.20 }
        case .brush:
            if brushMaterial != nil { confidence += 0.20 }
        default:
            if detectedBrand != "品牌未注明" { confidence += 0.20 }
        }
        confidence = min(0.98, confidence)

        let sourceSummary: String = communityResult.sources.isEmpty
            ? L10n.t("本地资料库识别", "Local knowledge base")
            : L10n.t("已参考：\(Array(Set(communityResult.sources)).prefix(3).joined(separator: " / "))", "Sources: \(Array(Set(communityResult.sources)).prefix(3).joined(separator: " / "))")

        let cleanModel: String? = {
            if detectedBrand != "品牌未注明", detectedBrand != "仿刀",
               spellFixed.lowercased().hasPrefix(detectedBrand.lowercased()) {
                let m = spellFixed.dropFirst(detectedBrand.count).trimmingCharacters(in: .whitespacesAndNewlines)
                return m.isEmpty ? nil : m
            }
            return nil
        }()

        return WebRecognitionResult(
            suggestedBrand: detectedBrand == "品牌未注明" ? nil : detectedBrand,
            suggestedHandleBrand: category == .brush ? handleBrand : nil,
            suggestedName: spellFixed,
            suggestedModel: cleanModel,
            razorType: category == .razor ? razorType : nil,
            isAdjustable: category == .razor ? isAdjustable : nil,
            isSlant: category == .razor ? isSlant : nil,
            material: category == .razor ? material : nil,
            plateType: category == .razor ? plateType : nil,
            gapOrSpec: category == .razor ? gapOrSpec : nil,
            bladeType: category == .blade ? bladeType : nil,
            brushMaterial: category == .brush ? brushMaterial : nil,
            badgerTreatment: category == .brush ? badgerTreatment : nil,
            badgerBand: category == .brush ? badgerBand : nil,
            knotSize: category == .brush ? knotSize : nil,
            knotShape: category == .brush ? knotShape : nil,
            confidence: confidence,
            sourceSummary: sourceSummary,
            sourceURL: communityResult.primaryURL,
            isCorrection: wasCorrected,
            webSearchVerified: !communityResult.sources.isEmpty
        )
    }

    private func queryCommunityReference(query: String, category: GearCategory) async -> (snippets: [String], sources: [String], primaryURL: String?) {
        var snippets: [String] = []
        var sources: [String] = []
        var primaryURL: String? = nil

        let hint: String = {
            switch category {
            case .razor: return "safety razor"
            case .blade: return "razor blade"
            case .brush: return "shaving brush"
            case .soap: return "shaving soap"
            default: return "wet shaving"
            }
        }()

        var ddgComp = URLComponents()
        ddgComp.scheme = "https"
        ddgComp.host = "api.duckduckgo.com"
        ddgComp.path = "/"
        ddgComp.queryItems = [
            URLQueryItem(name: "q", value: "\(query) \(hint)"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1")
        ]

        if let url = ddgComp.url,
           let (data, resp) = try? await transport.data(for: URLRequest(url: url, timeoutInterval: 15), timeout: 15, resourceTimeout: 25),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let abstract = obj["AbstractText"] as? String, !abstract.isEmpty {
                snippets.append(abstract)
                sources.append((obj["AbstractSource"] as? String) ?? "Web")
                if let u = obj["AbstractURL"] as? String, !u.isEmpty { primaryURL = u }
            }
            if let related = obj["RelatedTopics"] as? [[String: Any]] {
                for item in related.prefix(4) {
                    if let t = item["Text"] as? String, !t.isEmpty { snippets.append(t) }
                }
            }
        }

        var redditComp = URLComponents()
        redditComp.scheme = "https"
        redditComp.host = "www.reddit.com"
        redditComp.path = "/r/wetshaving+wicked_edge/search.json"
        redditComp.queryItems = [
            URLQueryItem(name: "q", value: "\(query) \(hint)"),
            URLQueryItem(name: "restrict_sr", value: "1"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "sort", value: "relevance")
        ]

        if let rURL = redditComp.url,
           let (data, resp) = try? await transport.data(for: URLRequest(url: rURL, timeoutInterval: 15), timeout: 15, resourceTimeout: 25),
           let http = resp as? HTTPURLResponse, http.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = obj["data"] as? [String: Any],
           let children = d["children"] as? [[String: Any]] {
            for c in children.prefix(4) {
                if let post = c["data"] as? [String: Any] {
                    let title = post["title"] as? String ?? ""
                    let body = String((post["selftext"] as? String ?? "").prefix(350))
                    if !title.isEmpty {
                        snippets.append("\(title) \(body)")
                        sources.append("Reddit")
                        if primaryURL == nil, let p = post["permalink"] as? String {
                            primaryURL = "https://www.reddit.com\(p)"
                        }
                    }
                }
            }
        }

        if primaryURL == nil {
            var qComp = URLComponents()
            qComp.scheme = "https"
            qComp.host = "www.google.com"
            qComp.path = "/search"
            qComp.queryItems = [
                URLQueryItem(name: "q", value: "\(query) \(hint) site:badgerandblade.com OR site:damnfineshave.com OR site:reddit.com/r/wetshaving")
            ]
            primaryURL = qComp.url?.absoluteString
        }

        return (snippets, sources, primaryURL)
    }

    private func inferRazorTypeFromText(_ text: String) -> RazorType? {
        let lower = text.lowercased()
        if lower.contains("half de") || lower.contains("half-de") { return .seHalfDE }
        if lower.contains("injector") { return .seInjector }
        if lower.contains("gem blade") || lower.contains("gem se") { return .seGEM }
        if lower.contains("artist club") || lower.contains("ac blade") || lower.contains("single edge") { return .seAC }
        if lower.contains("twin blade") { return .twinBlade }
        if lower.contains("shavette") { return .shavette }
        if lower.contains("straight razor") { return .straight }
        if lower.contains("cartridge") { return .cartridge }
        if lower.contains("double edge") || lower.contains("de safety razor") { return .de }
        return nil
    }

    private func extractGapSpec(from name: String) -> String? {
        if let match = Self.gapSpecRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let r = Range(match.range(at: 1), in: name) {
            return String(name[r]).replacingOccurrences(of: "mm", with: "").trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
