import Foundation

// MARK: - 剃须流程与过程枚举

enum SoapLoadingMethod: String, Codable, CaseIterable, Identifiable {
    case scoop = "挖取"
    case brushLoad = "刷取"
    case apply = "涂抹"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scoop: return L10n.t("挖取", "Scoop")
        case .brushLoad: return L10n.t("刷取", "Brush Load")
        case .apply: return L10n.t("涂抹", "Apply")
        }
    }
}

enum LatheringMethod: String, Codable, CaseIterable, Identifiable {
    case bowl = "碗起"
    case face = "脸起"
    case hand = "手起"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bowl: return L10n.t("碗起", "Bowl Lather")
        case .face: return L10n.t("脸起", "Face Lather")
        case .hand: return L10n.t("手起", "Hand Lather")
        }
    }

    var shortDisplayName: String {
        switch self {
        case .bowl: return L10n.t("碗起", "Bowl")
        case .face: return L10n.t("脸起", "Face")
        case .hand: return L10n.t("手起", "Hand")
        }
    }
}

enum ShaveResult: String, Codable, CaseIterable, Identifiable {
    case bbs = "BBS"
    case dfs = "DFS"
    case ccs = "CCS"
    case sas = "SAS"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var fullDescription: String {
        switch self {
        case .bbs: return L10n.t("BBS 婴儿肌", "BBS")
        case .dfs: return L10n.t("DFS 极净", "DFS")
        case .ccs: return L10n.t("CCS 贴面净", "CCS")
        case .sas: return L10n.t("SAS 日常净", "SAS")
        }
    }
}

enum IrritationLevel: String, Codable, CaseIterable, Identifiable {
    case painless = "无痛"
    case mild = "微痛"
    case stinging = "刺痛"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .painless: return L10n.t("无痛", "Painless")
        case .mild: return L10n.t("微痛", "Mild")
        case .stinging: return L10n.t("刺痛", "Stinging")
        }
    }
}

enum ShavePassType: String, Codable, CaseIterable, Identifiable {
    case wtg = "顺刮"
    case xtg = "横刮"
    case atg = "逆刮"
    case pickup = "补刀"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wtg: return L10n.t("顺刮", "WTG")
        case .xtg: return L10n.t("横刮", "XTG")
        case .atg: return L10n.t("逆刮", "ATG")
        case .pickup: return L10n.t("补刀", "Pickup")
        }
    }

    var shortChar: String {
        switch self {
        case .wtg: return "顺"
        case .xtg: return "横"
        case .atg: return "逆"
        case .pickup: return "补"
        }
    }
}

struct PassStep: Codable, Hashable, Identifiable {
    var pass: ShavePassType
    var setting: String = ""

    var id: String { pass.rawValue }
}

struct ParsedProcess: Hashable {
    var passes: [PassStep]
    var result: ShaveResult?
    var irritation: IrritationLevel?
    var note: String

    func formattedString(isAdjustable: Bool) -> String {
        var parts: [String] = []
        for step in passes {
            if isAdjustable && !step.setting.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("\(step.setting)\(step.pass.shortChar)")
            } else {
                parts.append(step.pass.shortChar)
            }
        }
        var text = parts.joined()
        if let irr = irritation {
            text += irr.rawValue
        }
        if let res = result {
            text += res.rawValue
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            text += (text.isEmpty ? "" : " ") + trimmedNote
        }
        return text
    }
}

// MARK: - 核心持久化数据结构（100% 向后兼容旧版 journal.json）

struct JournalField: Codable, Hashable, Identifiable {
    var id: String { "\(label)|\(value)" }
    var label: String
    var value: String

    enum CodingKeys: String, CodingKey {
        case label, value
    }
}

struct JournalEntry: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var fields: [JournalField]
    /// Apple 备忘录同步源内容指纹（可选，100% 向后兼容旧版 journal.json）
    var sourceFingerprint: String? = nil
    /// 是否已在 App 内本地修改
    var locallyModified: Bool? = nil
    /// 同步三方合并冲突标记：当源备忘录和本地记录同时改动时保留本地并提示冲突（S04）
    var hasSyncConflict: Bool? = nil
    /// 疑似重复标记：不同来源 ID 但全字段业务指纹一致时保留两条并标记提示，绝不静默删记录（S01）
    var suspectedDuplicate: Bool? = nil
    /// 云盘双端同步最后修改时间（ISO8601 UTC 字符串，可选，100% 向后兼容旧版 journal.json）
    var updatedAt: String? = nil

    static func contentFingerprint(date: String, fields: [JournalField]) -> String {
        let canonical = ([date] + fields.map { "\($0.label)=\($0.value)" }).joined(separator: "\n")
        return StableHash.fnv1a64Hex(canonical)
    }

    var contentFingerprint: String {
        Self.contentFingerprint(date: date, fields: fields)
    }

    /// 全字段精确业务指纹（S01）：涵盖日期及全部字段（含热敷、浴后、明矾、取皂、起泡与自定义字段），
    /// 仅做首尾空白裁剪，不过度折叠有效语义；用于识别完全一致的疑似重复，但绝不凭此自动删除不同 ID 记录。
    var fullBusinessFingerprint: String {
        let normalizedDate = date.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFields = fields
            .map { (
                $0.label.trimmingCharacters(in: .whitespacesAndNewlines),
                $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
            ) }
            .filter { !$0.0.isEmpty || !$0.1.isEmpty }
            .map { "\($0.0)=\($0.1)" }
        return StableHash.fnv1a64Hex(([normalizedDate] + normalizedFields).joined(separator: "\u{1E}"))
    }

    /// 编辑已有日记时按字段级就地更新/合并，完整保留编辑器未展示的字段（如 剃须刀1/2、刀片1/2 及自定义字段）
    static func buildMergedFields(
        existingEntry: JournalEntry?,
        dateStr: String,
        razor: String,
        blade: String,
        brush: String,
        soap: String,
        bowl: String,
        preShave: String,
        afterShave: String,
        afterShower: Bool,
        hotTowel: Bool,
        useAlum: Bool,
        processText: String,
        loadingMethod: String,
        latheringMethod: String
    ) -> [JournalField] {
        guard let existing = existingEntry else {
            return [
                JournalField(label: "日期", value: dateStr),
                JournalField(label: "剃须刀", value: razor),
                JournalField(label: "刀片", value: blade),
                JournalField(label: "剃须刷", value: brush),
                JournalField(label: "剃须皂", value: soap),
                JournalField(label: "剃须碗", value: bowl.isEmpty ? "无" : bowl),
                JournalField(label: "须前", value: preShave.isEmpty ? "无" : preShave),
                JournalField(label: "须后", value: afterShave.isEmpty ? "无" : afterShave),
                JournalField(label: "是否浴后", value: afterShower ? "是" : "否"),
                JournalField(label: "是否热敷", value: hotTowel ? "是" : "否"),
                JournalField(label: "是否明矾", value: useAlum ? "是" : "否"),
                JournalField(label: "过程", value: processText),
                JournalField(label: "取皂", value: loadingMethod),
                JournalField(label: "起泡", value: latheringMethod)
            ]
        }

        var merged = existing.fields

        func upsertField(label: String, value: String, appendIfMissing: Bool = true) {
            if let idx = merged.firstIndex(where: { $0.label == label }) {
                merged[idx].value = value
            } else if appendIfMissing {
                merged.append(JournalField(label: label, value: value))
            }
        }

        upsertField(label: "日期", value: dateStr)

        if merged.contains(where: { $0.label == "剃须刀" }) {
            upsertField(label: "剃须刀", value: razor)
        } else if merged.contains(where: { $0.label == "剃须刀1" }) {
            upsertField(label: "剃须刀1", value: razor)
        } else if !razor.isEmpty {
            merged.append(JournalField(label: "剃须刀", value: razor))
        }

        if merged.contains(where: { $0.label == "刀片" }) {
            upsertField(label: "刀片", value: blade)
        } else if merged.contains(where: { $0.label == "刀片1" }) {
            upsertField(label: "刀片1", value: blade)
        } else if !blade.isEmpty {
            merged.append(JournalField(label: "刀片", value: blade))
        }

        upsertField(label: "剃须刷", value: brush, appendIfMissing: !brush.isEmpty)
        upsertField(label: "剃须皂", value: soap, appendIfMissing: !soap.isEmpty)
        upsertField(label: "剃须碗", value: bowl.isEmpty ? "无" : bowl, appendIfMissing: !bowl.isEmpty)
        upsertField(label: "须前", value: preShave.isEmpty ? "无" : preShave, appendIfMissing: !preShave.isEmpty)
        upsertField(label: "须后", value: afterShave.isEmpty ? "无" : afterShave, appendIfMissing: !afterShave.isEmpty)
        upsertField(label: "是否浴后", value: afterShower ? "是" : "否")
        upsertField(label: "是否热敷", value: hotTowel ? "是" : "否", appendIfMissing: hotTowel || existing.hotTowel)
        upsertField(label: "是否明矾", value: useAlum ? "是" : "否")
        upsertField(label: "过程", value: processText)
        upsertField(label: "取皂", value: loadingMethod)
        upsertField(label: "起泡", value: latheringMethod)

        return merged
    }

    func fieldValue(for label: String) -> String {
        fields.first(where: { $0.label == label })?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func fieldValues(matching prefixes: [String]) -> [String] {
        fields.compactMap { field in
            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "无", trimmed != "-" else { return nil }
            for prefix in prefixes {
                if field.label == prefix || (field.label.hasPrefix(prefix) && field.label.dropFirst(prefix.count).allSatisfy({ $0.isNumber })) {
                    return trimmed
                }
            }
            return nil
        }
    }

    /// 返回带编号槽位的字段列表（如 剃须刀/剃须刀1/剃须刀2 -> (slot: "", "1", "2")），用于精确配对刀架与刀片（S09）
    func slottedFieldValues(prefix: String) -> [(slot: String, value: String)] {
        fields.compactMap { field in
            let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "无", trimmed != "-" else { return nil }
            if field.label == prefix {
                return ("", trimmed)
            }
            if field.label.hasPrefix(prefix) {
                let suffix = String(field.label.dropFirst(prefix.count))
                if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) {
                    return (suffix, trimmed)
                }
            }
            return nil
        }
    }

    var primaryRazor: String { fieldValue(for: "剃须刀").isEmpty ? fieldValue(for: "剃须刀1") : fieldValue(for: "剃须刀") }
    var primaryBlade: String { fieldValue(for: "刀片").isEmpty ? fieldValue(for: "刀片1") : fieldValue(for: "刀片") }
    var brush: String { fieldValue(for: "剃须刷") }
    var soap: String { fieldValue(for: "剃须皂") }
    var preShave: String { fieldValue(for: "须前") }
    var afterShave: String { fieldValue(for: "须后") }
    var processText: String { fieldValue(for: "过程") }
    var loadingMethod: String { fieldValue(for: "取皂") }
    var lathering: String { fieldValue(for: "起泡") }
    var afterShower: String { fieldValue(for: "是否浴后") }
    var alum: String { fieldValue(for: "是否明矾") }

    var bowl: String {
        let explicit = fieldValue(for: "剃须碗")
        if !explicit.isEmpty && explicit != "无" && explicit != "-" {
            return explicit
        }
        return GearKnowledgeBase.extractBowlName(from: lathering) ?? ""
    }

    var pureLatheringMethod: String {
        let raw = lathering.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return bowl.isEmpty ? "" : LatheringMethod.bowl.rawValue
        }
        if raw == "脸起" || raw == "手起" || raw == "碗起" {
            return raw
        }
        if raw.hasSuffix("碗起") || !bowl.isEmpty {
            return LatheringMethod.bowl.rawValue
        }
        return raw
    }

    var hotTowel: Bool {
        let explicit = fieldValue(for: "是否热敷")
        if explicit == "是" { return true }
        if explicit == "否" { return false }
        return afterShower.contains("热敷") || preShave.contains("热敷") || processText.contains("热敷")
    }

    var parsedDate: Date? {
        JournalDateFormatter.isoDay.date(from: date)
    }
}

struct JournalDatabase: Codable {
    static let currentSchemaVersion = 2
    static let knownTopLevelKeys: Set<String> = [
        "schemaVersion", "entries", "duplicates", "skipped", "lastSync",
        "overrides", "pending", "history", "deletedSourceIDs", "deletedEntryIds"
    ]

    /// 可选 schema 版本号（旧版 journal.json 缺省时视为 v1，向后兼容 S10）
    var schemaVersion: Int?
    var entries: [JournalEntry]
    var duplicates: Int
    var skipped: Int
    var lastSync: Double
    var overrides: [String: GearOverride]
    var pending: [String]
    var history: [GearHistorySnapshot]
    /// 已在 App 内主动删除的备忘录来源 ID 墓碑列表，避免下次同步时复活（S05）
    var deletedSourceIDs: [String]?
    /// 云盘双端同步删除墓碑（entryId -> ISO8601 UTC 删除时间），避免一端删除的日记被另一端复活
    var deletedEntryIds: [String: String]?

    init(
        schemaVersion: Int? = JournalDatabase.currentSchemaVersion,
        entries: [JournalEntry] = [],
        duplicates: Int = 0,
        skipped: Int = 0,
        lastSync: Double = Date().timeIntervalSinceReferenceDate,
        overrides: [String: GearOverride] = [:],
        pending: [String] = [],
        history: [GearHistorySnapshot] = [],
        deletedSourceIDs: [String]? = nil,
        deletedEntryIds: [String: String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.duplicates = duplicates
        self.skipped = skipped
        self.lastSync = lastSync
        self.overrides = overrides
        self.pending = pending
        self.history = history
        self.deletedSourceIDs = deletedSourceIDs
        self.deletedEntryIds = deletedEntryIds
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, entries, duplicates, skipped, lastSync, overrides, pending, history, deletedSourceIDs, deletedEntryIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        entries = try c.decodeIfPresent([JournalEntry].self, forKey: .entries) ?? []
        duplicates = try c.decodeIfPresent(Int.self, forKey: .duplicates) ?? 0
        skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        lastSync = try c.decodeIfPresent(Double.self, forKey: .lastSync) ?? Date().timeIntervalSinceReferenceDate
        overrides = try c.decodeIfPresent([String: GearOverride].self, forKey: .overrides) ?? [:]
        pending = try c.decodeIfPresent([String].self, forKey: .pending) ?? []
        history = try c.decodeIfPresent([GearHistorySnapshot].self, forKey: .history) ?? []
        deletedSourceIDs = try c.decodeIfPresent([String].self, forKey: .deletedSourceIDs)
        deletedEntryIds = try c.decodeIfPresent([String: String].self, forKey: .deletedEntryIds)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(schemaVersion ?? Self.currentSchemaVersion, forKey: .schemaVersion)
        try c.encode(entries, forKey: .entries)
        try c.encode(duplicates, forKey: .duplicates)
        try c.encode(skipped, forKey: .skipped)
        try c.encode(lastSync, forKey: .lastSync)
        try c.encode(overrides, forKey: .overrides)
        try c.encode(pending, forKey: .pending)
        try c.encode(history, forKey: .history)
        if let deleted = deletedSourceIDs, !deleted.isEmpty {
            try c.encode(deleted, forKey: .deletedSourceIDs)
        }
        if let deletedMap = deletedEntryIds, !deletedMap.isEmpty {
            try c.encode(deletedMap, forKey: .deletedEntryIds)
        }
    }
}

// MARK: - 云盘双端同步 ISO8601 时间戳工具

enum SyncTimestamp {
    private static let lock = NSLock()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let standardFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    static func nowISO8601() -> String {
        formatISO8601(Date())
    }

    static func formatISO8601(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractionalFormatter.string(from: date)
    }

    static func parseISO8601EpochMillis(_ raw: String?) -> Int64? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        if let d = fractionalFormatter.date(from: trimmed) {
            return Int64((d.timeIntervalSince1970 * 1000.0).rounded())
        }
        if let d = standardFormatter.date(from: trimmed) {
            return Int64((d.timeIntervalSince1970 * 1000.0).rounded())
        }
        return nil
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let ms = parseISO8601EpochMillis(raw) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}

// MARK: - 日期格式化辅助

enum JournalDateFormatter {
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let monthKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let shortMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}
