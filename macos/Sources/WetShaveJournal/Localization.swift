import Foundation

// MARK: - 多语言支持（跟随系统 + 手动切换，底层 journal.json 持久化键不变）

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.t("跟随系统", "System")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

enum L10n {
    static var currentLanguage: AppLanguage = .system

    static var isEnglish: Bool {
        switch currentLanguage {
        case .en: return true
        case .zhHans: return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return !preferred.hasPrefix("zh")
        }
    }

    static func t(_ zh: String, _ en: String) -> String {
        isEnglish ? en : zh
    }

    static func brandDisplay(_ raw: String) -> String {
        guard isEnglish else { return raw }
        switch raw {
        case "仿刀": return "Clone"
        case "品牌未注明", "无品牌": return "Unknown Brand"
        default: return raw
        }
    }

    static func materialDisplay(_ raw: String) -> String {
        guard isEnglish else { return raw }
        switch raw {
        case "不锈钢": return "Stainless Steel"
        case "钛合金": return "Titanium"
        case "黄铜": return "Brass"
        case "红铜": return "Copper"
        case "青铜": return "Bronze"
        case "磷青铜": return "Phosphor Bronze"
        case "铝合金": return "Aluminum"
        case "锌合金": return "Zamak"
        default: return raw
        }
    }

    static func handleTag(_ handleBrand: String) -> String {
        isEnglish ? "\(handleBrand) Handle" : "\(handleBrand) 柄"
    }

    static func latheringDisplay(_ raw: String) -> String {
        switch raw {
        case "碗起": return t("碗起", "Bowl Lather")
        case "脸起": return t("脸起", "Face Lather")
        case "手起": return t("手起", "Hand Lather")
        default: return raw
        }
    }

    static func loadingDisplay(_ raw: String) -> String {
        switch raw {
        case "挖取": return t("挖取", "Scoop")
        case "刷取": return t("刷取", "Brush Load")
        case "涂抹", "涂取": return t("涂抹", "Apply")
        default: return raw
        }
    }

    static func ordinal(_ n: Int) -> String {
        switch n % 100 {
        case 11, 12, 13: return "\(n)th"
        default:
            switch n % 10 {
            case 1: return "\(n)st"
            case 2: return "\(n)nd"
            case 3: return "\(n)rd"
            default: return "\(n)th"
            }
        }
    }
}
