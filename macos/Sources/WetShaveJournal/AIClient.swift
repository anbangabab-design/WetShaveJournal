import Foundation

// MARK: - 可注入 AI 传输协议、类型化通信信封与统一通信客户端（R05 / S07）

protocol AIClientTransport: Sendable {
    func data(for request: URLRequest, timeout: TimeInterval, resourceTimeout: TimeInterval) async throws -> (Data, URLResponse)
}

final class URLSessionAIClientTransport: AIClientTransport, @unchecked Sendable {
    private let standardSession: URLSession
    private let auditSession: URLSession

    init() {
        let std = URLSessionConfiguration.default
        std.timeoutIntervalForRequest = 90
        std.timeoutIntervalForResource = 180
        self.standardSession = URLSession(configuration: std)

        let aud = URLSessionConfiguration.default
        aud.timeoutIntervalForRequest = 180
        aud.timeoutIntervalForResource = 300
        self.auditSession = URLSession(configuration: aud)
    }

    func data(for request: URLRequest, timeout: TimeInterval, resourceTimeout: TimeInterval) async throws -> (Data, URLResponse) {
        let session = timeout >= 150 ? auditSession : standardSession
        var req = request
        req.timeoutInterval = timeout
        return try await session.data(for: req)
    }
}

enum AIWebSearchEvidence: Equatable, Sendable {
    case notRequested
    case downgradedToPlain
    case toolAcceptedUnverified
    case verifiedWithSources
}

struct AIChatCompletionResult: Sendable {
    let content: String
    let actualModel: String
    let webSearchEvidence: AIWebSearchEvidence
}

enum AIClientError: LocalizedError {
    case missingAPIKey
    case missingModel
    case apiNotEnabled
    case visionNotSupported
    case invalidResponse
    case cancelled
    case httpError(statusCode: Int, message: String)
    case transportError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L10n.t("未填写 API Key", "API key is empty")
        case .missingModel:
            return L10n.t("未填写模型名称", "Model name is empty")
        case .apiNotEnabled:
            return L10n.t("请先在设置页启用并配置 AI 接口", "Please enable and configure AI API in Settings first")
        case .visionNotSupported:
            return L10n.t(
                "当前模型不支持图片识别，请在设置中切换至支持视觉的模型（如 Gemini / GPT）",
                "The current model does not support image recognition. Please switch to a vision-capable model (e.g. Gemini / GPT) in Settings."
            )
        case .invalidResponse:
            return L10n.t("AI 接口返回了无法解析的响应", "AI API returned an unparseable response")
        case .cancelled:
            return L10n.t("AI 请求已取消", "AI request cancelled")
        case .httpError(let code, let message):
            return message.isEmpty ? "HTTP \(code)" : message
        case .transportError(_, let message):
            return message
        }
    }
}

private struct ChatImageURLPayload: Encodable {
    let url: String
}

private struct ChatContentPartPayload: Encodable {
    let type: String
    let text: String?
    let imageURL: ChatImageURLPayload?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func textPart(_ text: String) -> ChatContentPartPayload {
        ChatContentPartPayload(type: "text", text: text, imageURL: nil)
    }

    static func imageURLPart(_ dataURL: String) -> ChatContentPartPayload {
        ChatContentPartPayload(type: "image_url", text: nil, imageURL: ChatImageURLPayload(url: dataURL))
    }
}

private enum ChatMessageContentPayload: Encodable {
    case text(String)
    case parts([ChatContentPartPayload])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let str):
            try container.encode(str)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

private struct ChatMessagePayload: Encodable {
    let role: String
    let content: ChatMessageContentPayload
}

private struct ChatToolPayload: Encodable {
    let type: String?
    let googleSearch: [String: String]?

    enum CodingKeys: String, CodingKey {
        case type
        case googleSearch = "google_search"
    }

    static let deepSeekWebSearch = ChatToolPayload(type: "deepseek_web_search", googleSearch: nil)
    static let googleWebSearch = ChatToolPayload(type: nil, googleSearch: [:])
}

private struct ChatCompletionRequestBody: Encodable {
    let model: String
    let temperature: Double
    let messages: [ChatMessagePayload]
    let maxTokens: Int?
    let tools: [ChatToolPayload]?

    enum CodingKeys: String, CodingKey {
        case model, temperature, messages, tools
        case maxTokens = "max_tokens"
    }
}

private struct ChatCompletionResponseEnvelope: Decodable {
    struct Choice: Decodable {
        struct ContentPart: Decodable {
            let type: String?
            let text: String?
        }
        struct Message: Decodable {
            let content: String?
            let annotations: [Annotation]?

            enum CodingKeys: String, CodingKey {
                case content, annotations
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations)
                if let str = try? c.decodeIfPresent(String.self, forKey: .content) {
                    content = str
                } else if let parts = try? c.decodeIfPresent([ContentPart].self, forKey: .content) {
                    let joined = parts.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    content = joined.isEmpty ? nil : joined
                } else {
                    content = nil
                }
            }
        }
        struct Annotation: Decodable {
            let type: String?
        }
        let message: Message?
    }
    let model: String?
    let choices: [Choice]?
    let citations: [String]?
}

private struct APIErrorEnvelope: Decodable {
    struct Inner: Decodable {
        let message: String?
        let type: String?
        let code: String?
    }
    let error: Inner?
    let message: String?
}

/// OpenAI 兼容通信客户端（R05 / S07）：统一负责端点校验、认证头、超时策略、联网工具精准降级重试与密钥脱敏
struct AIClient: Sendable {
    let transport: AIClientTransport

    private static let jsonFencePrefixRegex = try! NSRegularExpression(pattern: #"^```(?:json)?\s*"#)
    private static let jsonFenceSuffixRegex = try! NSRegularExpression(pattern: #"\s*```$"#)

    init(transport: AIClientTransport = URLSessionAIClientTransport()) {
        self.transport = transport
    }

    func chatCompletion(
        system: String,
        user: String,
        imageDataURL: String? = nil,
        config: AIConfig,
        useWebSearch: Bool = false,
        useAuditTimeout: Bool = false,
        maxTokens: Int? = nil,
        temperature: Double = 0.15
    ) async throws -> AIChatCompletionResult {
        try Task.checkCancellation()

        let validatedBase = try EndpointSecurityValidator.validatedURL(
            config.baseURL,
            allowLocalHTTP: true,
            contextLabel: "Base URL"
        )
        let endpoint = Self.chatCompletionsURL(from: validatedBase.absoluteString)
        let url = try EndpointSecurityValidator.validatedURL(
            endpoint,
            allowLocalHTTP: true,
            contextLabel: "Base URL"
        )

        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AIClientError.missingAPIKey }
        guard !model.isEmpty else { throw AIClientError.missingModel }

        let cleanedImageURL = imageDataURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = (cleanedImageURL?.isEmpty == false)

        enum WebSearchToolMode {
            case none
            case deepseek
            case googleSearch
        }

        let requestTimeout: TimeInterval = useAuditTimeout ? 180 : 90
        let resourceTimeout: TimeInterval = useAuditTimeout ? 300 : 180

        func perform(toolMode: WebSearchToolMode) async throws -> (Data, HTTPURLResponse) {
            try Task.checkCancellation()
            var request = URLRequest(url: url, timeoutInterval: requestTimeout)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

            let tools: [ChatToolPayload]?
            switch toolMode {
            case .none: tools = nil
            case .deepseek: tools = [.deepSeekWebSearch]
            case .googleSearch: tools = [.googleWebSearch]
            }

            let userContent: ChatMessageContentPayload
            if let imgURL = cleanedImageURL, !imgURL.isEmpty {
                userContent = .parts([
                    .textPart(user),
                    .imageURLPart(imgURL)
                ])
            } else {
                userContent = .text(user)
            }

            let body = ChatCompletionRequestBody(
                model: model,
                temperature: temperature,
                messages: [
                    ChatMessagePayload(role: "system", content: .text(system)),
                    ChatMessagePayload(role: "user", content: userContent)
                ],
                maxTokens: maxTokens,
                tools: tools
            )
            request.httpBody = try JSONEncoder().encode(body)

            do {
                let (data, resp) = try await transport.data(for: request, timeout: requestTimeout, resourceTimeout: resourceTimeout)
                guard let http = resp as? HTTPURLResponse else {
                    throw AIClientError.invalidResponse
                }
                return (data, http)
            } catch is CancellationError {
                throw AIClientError.cancelled
            } catch let urlErr as URLError where urlErr.code == .cancelled {
                throw AIClientError.cancelled
            } catch let clientErr as AIClientError {
                throw clientErr
            } catch {
                let safeMsg = KeychainStore.redactSecret(key, in: error.localizedDescription)
                throw AIClientError.transportError(code: (error as NSError).code, message: safeMsg)
            }
        }

        let initialToolMode: WebSearchToolMode = {
            guard useWebSearch, !hasImage else { return .none }
            if config.shouldUseDeepSeekWebSearch { return .deepseek }
            if config.shouldUseGoogleSearch { return .googleSearch }
            return .none
        }()

        var (data, http) = try await perform(toolMode: initialToolMode)
        var didDowngrade = false

        // S07：仅在明确的参数/工具不兼容错误（HTTP 400/422 且不属于认证/限流/服务端错误）时降级重试一次
        if initialToolMode != .none && Self.shouldDowngradeWebSearchTool(statusCode: http.statusCode, responseData: data) {
            didDowngrade = true
            (data, http) = try await perform(toolMode: .none)
        }

        guard (200...299).contains(http.statusCode) else {
            if hasImage && Self.isVisionUnsupportedError(statusCode: http.statusCode, responseData: data) {
                throw AIClientError.visionNotSupported
            }
            let rawMsg = Self.extractAPIErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            let safeMsg = KeychainStore.redactSecret(key, in: rawMsg)
            throw AIClientError.httpError(statusCode: http.statusCode, message: safeMsg)
        }

        guard let envelope = try? JSONDecoder().decode(ChatCompletionResponseEnvelope.self, from: data),
              let content = envelope.choices?.first?.message?.content else {
            throw AIClientError.invalidResponse
        }

        let returnedModel = envelope.model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualModel = (returnedModel?.isEmpty == false ? returnedModel! : model)

        let evidence: AIWebSearchEvidence
        if initialToolMode == .none {
            evidence = .notRequested
        } else if didDowngrade {
            evidence = .downgradedToPlain
        } else if Self.hasWebSearchGroundingEvidence(data: data, envelope: envelope) {
            evidence = .verifiedWithSources
        } else {
            evidence = .toolAcceptedUnverified
        }

        return AIChatCompletionResult(content: content, actualModel: actualModel, webSearchEvidence: evidence)
    }

    static func shouldDowngradeWebSearchTool(statusCode: Int, responseData: Data) -> Bool {
        guard statusCode == 400 || statusCode == 422 else { return false }
        let msg = (extractAPIErrorMessage(from: responseData) ?? String(data: responseData, encoding: .utf8) ?? "").lowercased()
        if msg.contains("context_length") || msg.contains("maximum context") || msg.contains("insufficient_quota") || msg.contains("billing") {
            return false
        }
        return true
    }

    static func isVisionUnsupportedError(statusCode: Int, responseData: Data) -> Bool {
        guard statusCode == 400 || statusCode == 404 || statusCode == 415 || statusCode == 422 else {
            return false
        }
        let msg = (extractAPIErrorMessage(from: responseData) ?? String(data: responseData, encoding: .utf8) ?? "").lowercased()
        let indicators = [
            "image_url",
            "image input",
            "images are not supported",
            "does not support image",
            "doesn't support image",
            "not support image",
            "does not support vision",
            "vision is not supported",
            "multimodal",
            "multi-modal",
            "unsupported content type",
            "invalid content type",
            "content must be a string",
            "expected a string",
            "expected string",
            "unknown variant `image_url`",
            "image not supported",
            "cannot read image",
            "no vision",
            "unsupported modality",
            "image modality"
        ]
        return indicators.contains { msg.contains($0) }
    }

    private static func hasWebSearchGroundingEvidence(
        data: Data,
        envelope: ChatCompletionResponseEnvelope
    ) -> Bool {
        if let citations = envelope.citations, !citations.isEmpty {
            return true
        }
        if let annotations = envelope.choices?.first?.message?.annotations,
           annotations.contains(where: { ($0.type ?? "").lowercased().contains("citation") || ($0.type ?? "").lowercased().contains("search") }) {
            return true
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if root["groundingMetadata"] != nil || root["grounding_metadata"] != nil || root["search_results"] != nil {
            return true
        }
        if let choices = root["choices"] as? [[String: Any]], let first = choices.first {
            if first["groundingMetadata"] != nil || first["grounding_metadata"] != nil {
                return true
            }
            if let msg = first["message"] as? [String: Any],
               msg["groundingMetadata"] != nil || msg["grounding_metadata"] != nil || msg["citations"] != nil {
                return true
            }
        }
        return false
    }

    static func chatCompletionsURL(from baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/chat/completions") { return trimmed }
        return "\(trimmed)/chat/completions"
    }

    static func extractJSONObjectString(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            let r1 = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = jsonFencePrefixRegex.stringByReplacingMatches(in: cleaned, range: r1, withTemplate: "")
            let r2 = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = jsonFenceSuffixRegex.stringByReplacingMatches(in: cleaned, range: r2, withTemplate: "")
        }
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") {
            return String(cleaned[start...end])
        }
        return cleaned
    }

    static func extractAPIErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            if let m = decoded.error?.message, !m.isEmpty { return String(m.prefix(160)) }
            if let m = decoded.message, !m.isEmpty { return String(m.prefix(160)) }
        }
        return nil
    }
}
