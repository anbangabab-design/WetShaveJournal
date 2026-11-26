import Foundation

// MARK: - 统计分析与衍生快照模型

struct RazorBladeComboStat: Identifiable, Hashable {
    var id: String { "\(razorName)||\(bladeName)" }
    var razorBrand: String
    var razorName: String
    var bladeBrand: String
    var bladeName: String
    var uses: Int
    var bbsCount: Int
    var painlessCount: Int
    var mildCount: Int
    var stingingCount: Int

    var bbsRate: Double { uses > 0 ? Double(bbsCount) / Double(uses) : 0 }
    var painlessRate: Double { uses > 0 ? Double(painlessCount) / Double(uses) : 0 }
    var stingingRate: Double { uses > 0 ? Double(stingingCount) / Double(uses) : 0 }
    var comfortScore: Double {
        guard uses > 0 else { return 0 }
        let score = (Double(painlessCount) * 1.0 + Double(mildCount) * 0.45 - Double(stingingCount) * 0.9 + Double(bbsCount) * 0.4) / Double(uses)
        return max(0, min(1.4, score))
    }
}

struct BladeLongevityStat: Identifiable, Hashable {
    var id: String { bladeName }
    var brand: String
    var bladeName: String
    var totalShaves: Int
    var maxUseCount: Int
    var avgCycleUses: Double
    /// 刀片平均寿命基于日记中记录的序号分段推算，不含物理刀片编号，UI 必须标注估算说明（S09）
    var isEstimated: Bool = true
}

struct MonthlyShavePoint: Identifiable, Hashable {
    var id: String { month }
    var month: String
    var count: Int
}

struct DistributionSlice: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var count: Int
}

enum DayCalendarSeverity: Int, Hashable, Comparable {
    case painless = 0
    case mild = 1
    case stinging = 2

    static func < (lhs: DayCalendarSeverity, rhs: DayCalendarSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DayCalendarStatus: Hashable {
    var date: String
    var entryIDs: [String]
    var worstSeverity: DayCalendarSeverity

    var count: Int { entryIDs.count }
}

/// 统计与解析衍生快照（与 JournalStore.revision 绑定，单次扫描 entries 构建，彻底避免视图渲染重复全量重算）
struct StatisticsSnapshot {
    var revision: UInt64
    var isEnglish: Bool
    var totalEntries: Int
    var validResultCount: Int
    var validIrritationCount: Int
    var bbsCount: Int
    var painlessCount: Int
    var hotTowelCount: Int
    var afterShowerCount: Int
    var alumCount: Int
    var avgIntervalDays: Double
    var latheringDistribution: [DistributionSlice]
    var loadingDistribution: [DistributionSlice]
    var resultDistribution: [DistributionSlice]
    var irritationDistribution: [DistributionSlice]
    var irritationCountsByLevel: [IrritationLevel: Int]
    var monthlyTrend: [MonthlyShavePoint]
    var comboStats: [RazorBladeComboStat]
    var bladeLongevityStats: [BladeLongevityStat]
    var parsedProcessByEntryID: [String: ParsedProcess]
    var entriesByDate: [String: [JournalEntry]]
    var calendarStatusByDate: [String: DayCalendarStatus]

    var bbsRate: Double {
        validResultCount > 0 ? Double(bbsCount) / Double(validResultCount) : 0
    }

    var painlessRate: Double {
        validIrritationCount > 0 ? Double(painlessCount) / Double(validIrritationCount) : 0
    }

    var hotTowelRate: Double {
        totalEntries > 0 ? Double(hotTowelCount) / Double(totalEntries) : 0
    }

    var afterShowerRate: Double {
        totalEntries > 0 ? Double(afterShowerCount) / Double(totalEntries) : 0
    }

    var alumRate: Double {
        totalEntries > 0 ? Double(alumCount) / Double(totalEntries) : 0
    }

    static let empty = StatisticsSnapshot(
        revision: 0,
        isEnglish: false,
        totalEntries: 0,
        validResultCount: 0,
        validIrritationCount: 0,
        bbsCount: 0,
        painlessCount: 0,
        hotTowelCount: 0,
        afterShowerCount: 0,
        alumCount: 0,
        avgIntervalDays: 0,
        latheringDistribution: [],
        loadingDistribution: [],
        resultDistribution: [],
        irritationDistribution: [],
        irritationCountsByLevel: [:],
        monthlyTrend: [],
        comboStats: [],
        bladeLongevityStats: [],
        parsedProcessByEntryID: [:],
        entriesByDate: [:],
        calendarStatusByDate: [:]
    )
}
