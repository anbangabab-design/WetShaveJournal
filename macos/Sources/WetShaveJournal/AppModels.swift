import Foundation
import SwiftUI

// MARK: - 应用元信息

enum AppMetadata {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.4.1"
    }

    static var build: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "19"
    }
}

// MARK: - 底部状态提示单一状态模型

struct ToastState: Identifiable, Equatable {
    var id: UUID = UUID()
    var message: String
    var isLoading: Bool
}

// MARK: - 外观设置

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色模式"
    case dark = "深色模式"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.t("跟随系统", "System")
        case .light: return L10n.t("浅色", "Light")
        case .dark: return L10n.t("深色", "Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
}

// MARK: - OpenAI 兼容 AI 接口配置（API Key 仅存系统 Keychain，非敏感配置存 UserDefaults，绝不写入 journal.json）

enum AIProviderPreset: String, CaseIterable, Identifiable {
    case deepseek = "DeepSeek"
    case openai = "OpenAI"
    case gemini = "Gemini"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini"
        case .custom: return L10n.t("自定义", "Custom")
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .openai: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        case .custom: return ""
        }
    }

    var defaultWebSearch: Bool {
        self == .deepseek
    }

    var defaultGoogleSearch: Bool {
        self == .gemini
    }
}

struct AIConfig: Equatable {
    var enabled: Bool = false
    var preset: AIProviderPreset = .deepseek
    var baseURL: String = AIProviderPreset.deepseek.defaultBaseURL
    var model: String = AIProviderPreset.deepseek.defaultModel
    var apiKey: String = ""
    var enableWebSearch: Bool = true
    var enableGoogleSearch: Bool = false

    var isReady: Bool {
        enabled
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static let legacyAPIKeyDefaultsKey = "WetShaveJournal.AI.APIKey"

    var isDeepSeekEndpoint: Bool {
        let m = model.lowercased()
        let u = baseURL.lowercased()
        return preset == .deepseek || m.contains("deepseek") || u.contains("deepseek")
    }

    var shouldUseDeepSeekWebSearch: Bool {
        guard enableWebSearch else { return false }
        return isDeepSeekEndpoint
    }

    var shouldUseGoogleSearch: Bool {
        guard enableGoogleSearch, !isDeepSeekEndpoint else { return false }
        return true
    }

    static func loadWithKeychainMigration(
        defaults: UserDefaults = .standard,
        keychainRead: () throws -> String? = { try KeychainStore.read() },
        keychainSave: (String) throws -> Void = { try KeychainStore.save($0) }
    ) -> (config: AIConfig, warning: String?) {
        let preset = AIProviderPreset(rawValue: defaults.string(forKey: "WetShaveJournal.AI.Preset") ?? "") ?? .deepseek
        let baseURL = defaults.string(forKey: "WetShaveJournal.AI.BaseURL") ?? preset.defaultBaseURL
        var model = defaults.string(forKey: "WetShaveJournal.AI.Model") ?? preset.defaultModel
        if preset == .deepseek && model == "deepseek-chat" {
            model = "deepseek-flash"
        }
        let enabled = defaults.bool(forKey: "WetShaveJournal.AI.Enabled")
        let webSearch: Bool = defaults.object(forKey: "WetShaveJournal.AI.EnableWebSearch") != nil
            ? defaults.bool(forKey: "WetShaveJournal.AI.EnableWebSearch")
            : preset.defaultWebSearch
        let googleSearch: Bool = defaults.object(forKey: "WetShaveJournal.AI.EnableGoogleSearch") != nil
            ? defaults.bool(forKey: "WetShaveJournal.AI.EnableGoogleSearch")
            : (preset.defaultGoogleSearch || (preset == .custom && model.lowercased().contains("gemini")))

        let legacyRaw = defaults.string(forKey: legacyAPIKeyDefaultsKey)
        let legacyKey = legacyRaw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var resolvedKey = ""
        var warning: String? = nil

        var keychainKey: String? = nil
        var keychainReadError: Error? = nil
        do {
            keychainKey = try keychainRead()
        } catch {
            keychainReadError = error
        }

        if !legacyKey.isEmpty {
            if let existingKC = keychainKey?.trimmingCharacters(in: .whitespacesAndNewlines), !existingKC.isEmpty {
                resolvedKey = existingKC
                defaults.removeObject(forKey: legacyAPIKeyDefaultsKey)
            } else {
                do {
                    try keychainSave(legacyKey)
                    let verified = try keychainRead()
                    guard verified == legacyKey else {
                        throw KeychainStoreError.verificationMismatch
                    }
                    defaults.removeObject(forKey: legacyAPIKeyDefaultsKey)
                    resolvedKey = legacyKey
                } catch {
                    resolvedKey = legacyKey
                    warning = L10n.t(
                        "API Key 迁移至钥匙串失败（\(error.localizedDescription)），已临时保留旧配置以确保可用",
                        "Failed to migrate API key to Keychain (\(error.localizedDescription)). Kept legacy value so AI remains usable."
                    )
                }
            }
        } else {
            if legacyRaw != nil {
                defaults.removeObject(forKey: legacyAPIKeyDefaultsKey)
            }
            if let existingKC = keychainKey {
                resolvedKey = existingKC
            } else if let readErr = keychainReadError {
                warning = L10n.t(
                    "读取钥匙串中的 API Key 失败：\(readErr.localizedDescription)",
                    "Failed to read API key from Keychain: \(readErr.localizedDescription)"
                )
            }
        }

        let cfg = AIConfig(
            enabled: enabled,
            preset: preset,
            baseURL: baseURL,
            model: model,
            apiKey: resolvedKey,
            enableWebSearch: webSearch,
            enableGoogleSearch: googleSearch
        )
        return (cfg, warning)
    }

    func saveNonSensitiveToUserDefaults(defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "WetShaveJournal.AI.Enabled")
        defaults.set(preset.rawValue, forKey: "WetShaveJournal.AI.Preset")
        defaults.set(baseURL, forKey: "WetShaveJournal.AI.BaseURL")
        defaults.set(model, forKey: "WetShaveJournal.AI.Model")
        defaults.set(enableWebSearch, forKey: "WetShaveJournal.AI.EnableWebSearch")
        defaults.set(enableGoogleSearch, forKey: "WetShaveJournal.AI.EnableGoogleSearch")
    }

    func saveAPIKeyToKeychain() throws {
        try KeychainStore.save(apiKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyAPIKeyDefaultsKey)
    }
}

extension AIConfig: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String {
        "AIConfig(enabled: \(enabled), preset: \(preset.rawValue), baseURL: \(baseURL), model: \(model), apiKey: \(apiKey.isEmpty ? "<empty>" : "<redacted>"), enableWebSearch: \(enableWebSearch), enableGoogleSearch: \(enableGoogleSearch))"
    }

    var debugDescription: String { description }
}

// MARK: - AI 结构化输出与体检报告模型

struct SOTDDraft: Identifiable, Hashable {
    var id = UUID()
    var razor: String = ""
    var blade: String = ""
    var brush: String = ""
    var soap: String = ""
    var preShave: String = ""
    var afterShave: String = ""
    var bowl: String = ""
}

struct AINaturalSOTDResult: Hashable {
    var razor: String?
    var blade: String?
    var bladeUseCount: Int?
    var brush: String?
    var soap: String?
    var bowl: String?
    var preShave: String?
    var afterShave: String?
    var loadingMethod: SoapLoadingMethod?
    var latheringMethod: LatheringMethod?
    var hotTowel: Bool?
    var afterShower: Bool?
    var useAlum: Bool?
    var passes: [PassStep]
    var result: ShaveResult?
    var irritation: IrritationLevel?
    var note: String?
}

struct AIPhotoSOTDResult: Hashable {
    var razor: String?
    var blade: String?
    var brush: String?
    var soap: String?
    var bowl: String?
    var preShave: String?
    var afterShave: String?
    var uncertainNote: String?

    var recognizedFieldCount: Int {
        [razor, blade, brush, soap, bowl, preShave, afterShave]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .count
    }
}

struct AISetupRecommendation: Hashable {
    var razorName: String?
    var bladeName: String?
    var brushName: String?
    var soapName: String?
    var bowlName: String?
    var preShaveName: String?
    var afterShaveName: String?
    var reason: String
}

struct WebRecognitionResult: Hashable {
    var suggestedBrand: String?
    var suggestedHandleBrand: String?
    var suggestedName: String?
    var suggestedModel: String?
    var razorType: RazorType?
    var isAdjustable: Bool?
    var isSlant: Bool?
    var material: String?
    var plateType: PlateType?
    var gapOrSpec: String?
    var notes: String? = nil
    var bladeType: BladeType?
    var brushMaterial: BrushMaterial?
    var badgerTreatment: BadgerTreatment?
    var badgerBand: BadgerBand?
    var knotSize: String?
    var knotShape: BrushKnotShape?
    var confidence: Double
    var sourceSummary: String
    var sourceURL: String?
    var isCorrection: Bool
    var webSearchVerified: Bool = false
}

enum GearAuditItemStatus: String, Hashable, Sendable {
    case unchanged
    case suggestedUpdate
    case undetermined
    case failed
    case skippedManual
}

struct GearAuditUpdateProposal: Identifiable, Hashable, Codable {
    var id: String { item.id }
    var item: GearItem
    var proposed: GearOverride
    var changesSummary: [String]
    var reason: String
    var confidence: Double
    var selected: Bool = true
    var sourceSnapshotFingerprint: String = ""
}

struct GearAuditMergeProposal: Identifiable, Hashable, Codable {
    var id: String { "\(source.id)->\(target.id)" }
    var source: GearItem
    var target: GearItem
    var reason: String
    var selected: Bool = true
    var sourceSnapshotFingerprint: String = ""
    var targetSnapshotFingerprint: String = ""
}

struct GearAuditBatchFailure: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var batchIndex: Int
    var items: [GearItem]
    var reason: String
}

/// AI 体检会话轻量持久化模型（存储于数据目录 ai_health_check_session.json，支持关闭弹窗或重启后断点续做）
struct AIHealthCheckSession: Codable, Equatable {
    var schemaVersion: Int = 1
    var savedAt: String
    var scopeRawValue: String
    var category: GearCategory?
    var modelUsed: String?
    var plannedCount: Int
    var verifiedCount: Int
    var skippedCount: Int
    var unknownOrDuplicateIDCount: Int
    var retryRound: Int
    var updates: [GearAuditUpdateProposal]
    var merges: [GearAuditMergeProposal]
    var undeterminedItems: [GearItem]
    var failedItems: [GearItem]
    var batchFailures: [GearAuditBatchFailure]

    var hasActionableRemainder: Bool {
        !updates.isEmpty || !merges.isEmpty || !failedItems.isEmpty || !undeterminedItems.isEmpty || !batchFailures.isEmpty
    }
}

struct GearAuditProgress: Sendable {
    var currentBatch: Int
    var totalBatches: Int
    var plannedCount: Int
    var verifiedCount: Int
    var undeterminedCount: Int
    var failedCount: Int
    var skippedCount: Int
}

struct GearAuditReport {
    var updates: [GearAuditUpdateProposal]
    var merges: [GearAuditMergeProposal]
    var modelUsed: String
    var plannedCount: Int = 0
    /// 完整核查数（AI 明确返回结果：无需修改 + 建议修改）
    var verifiedCount: Int = 0
    /// AI 未给出明确状态（遗漏/截断/无法判断）的条目
    var undeterminedItems: [GearItem] = []
    /// 请求或解析失败的条目
    var failedItems: [GearItem] = []
    /// 跳过条目（已人工确认无需改、规格冲突拦截的合并等）
    var skippedCount: Int = 0
    /// 响应中忽略的未知 ID 或重复 ID 数
    var unknownOrDuplicateIDCount: Int = 0
    var itemStatuses: [String: GearAuditItemStatus] = [:]
    var failures: [GearAuditBatchFailure] = []

    /// 待复核/未完成条目（供「仅重试未完成项」使用）
    var retryableItems: [GearItem] {
        var seen: Set<String> = []
        var result: [GearItem] = []
        for it in failedItems + undeterminedItems {
            if seen.insert(it.id).inserted {
                result.append(it)
            }
        }
        return result
    }
}
