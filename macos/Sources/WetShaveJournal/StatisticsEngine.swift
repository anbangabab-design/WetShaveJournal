import Foundation

/// 预编译正则的过程文本解析器（R04）：消除高频调用时的 NSRegularExpression 重复编译开销
enum ProcessParser {
    private static let globalSettingRegex = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d+)?)\s*档"#)

    private struct PassMatcher {
        let type: ShavePassType
        let char: String
        let beforeRegex: NSRegularExpression
        let afterRegex: NSRegularExpression
    }

    private static let passMatchers: [PassMatcher] = [
        (.wtg, "顺"), (.xtg, "横"), (.atg, "逆"), (.pickup, "补")
    ].map { type, ch in
        PassMatcher(
            type: type,
            char: ch,
            beforeRegex: try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*档?\s*"# + ch),
            afterRegex: try! NSRegularExpression(pattern: ch + #"\s*(\d+(?:\.\d+)?)"#)
        )
    }

    private static let stripRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)\b(?:BBS|DFS|CCS|SAS)\b"#),
        try! NSRegularExpression(pattern: #"(?i)(?:BBS|DFS|CCS|SAS)"#),
        try! NSRegularExpression(pattern: #"微微痛|无痛|微痛|刺痛"#),
        try! NSRegularExpression(pattern: #"[一二三四五六七八九十\d]+(?:\.\d+)?\s*档?"#),
        try! NSRegularExpression(pattern: #"顺刮|横刮|逆刮|补刀|[顺横逆补]"#)
    ]
    private static let whitespaceCollapseRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let noteTrimChars = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "，,。.;；/+-·"))

    private static let cnNumPairs: [(String, String)] = [
        ("一", "1"), ("二", "2"), ("三", "3"), ("四", "4"), ("五", "5"),
        ("六", "6"), ("七", "7"), ("八", "8"), ("九", "9"), ("十", "10")
    ]

    static func parse(_ text: String) -> ParsedProcess {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedProcess(passes: [], result: nil, irritation: nil, note: "")
        }

        var normalizedForPass = trimmed
        for (cn, num) in cnNumPairs where normalizedForPass.contains(cn) {
            normalizedForPass = normalizedForPass.replacingOccurrences(of: cn, with: num)
        }

        var result: ShaveResult? = nil
        let upper = trimmed.uppercased()
        if upper.contains("BBS") { result = .bbs }
        else if upper.contains("DFS") { result = .dfs }
        else if upper.contains("CCS") { result = .ccs }
        else if upper.contains("SAS") { result = .sas }

        var irritation: IrritationLevel? = nil
        if trimmed.contains("刺痛") { irritation = .stinging }
        else if trimmed.contains("微痛") { irritation = .mild }
        else if trimmed.contains("无痛") { irritation = .painless }

        let normRange = NSRange(normalizedForPass.startIndex..., in: normalizedForPass)
        var globalSetting = ""
        if let m = globalSettingRegex.firstMatch(in: normalizedForPass, range: normRange),
           let r = Range(m.range(at: 1), in: normalizedForPass) {
            globalSetting = String(normalizedForPass[r])
        }

        var passes: [PassStep] = []
        passes.reserveCapacity(4)
        for matcher in passMatchers where normalizedForPass.contains(matcher.char) {
            var setting = globalSetting
            if let m = matcher.beforeRegex.firstMatch(in: normalizedForPass, range: normRange),
               let r = Range(m.range(at: 1), in: normalizedForPass) {
                setting = String(normalizedForPass[r])
            } else if let m = matcher.afterRegex.firstMatch(in: normalizedForPass, range: normRange),
                      let r = Range(m.range(at: 1), in: normalizedForPass) {
                setting = String(normalizedForPass[r])
            }
            passes.append(PassStep(pass: matcher.type, setting: setting))
        }

        var leftover = trimmed
        for regex in stripRegexes {
            let range = NSRange(leftover.startIndex..., in: leftover)
            leftover = regex.stringByReplacingMatches(in: leftover, range: range, withTemplate: " ")
        }
        let trimmedLeftover = leftover.trimmingCharacters(in: noteTrimChars)
        let note: String
        if trimmedLeftover.isEmpty {
            note = ""
        } else {
            let r = NSRange(trimmedLeftover.startIndex..., in: trimmedLeftover)
            note = whitespaceCollapseRegex.stringByReplacingMatches(in: trimmedLeftover, range: r, withTemplate: " ")
        }

        return ParsedProcess(passes: passes, result: result, irritation: irritation, note: note)
    }
}

/// 纯函数单次遍历统计分析引擎（R04 / S09）
enum StatisticsEngine {
    static func buildSnapshot(
        database: JournalDatabase,
        revision: UInt64,
        isEnglish: Bool
    ) -> StatisticsSnapshot {
        let entries = database.entries
        guard !entries.isEmpty else {
            return StatisticsSnapshot(
                revision: revision,
                isEnglish: isEnglish,
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

        var parsedByTextCache: [String: ParsedProcess] = [:]
        parsedByTextCache.reserveCapacity(min(entries.count, 512))
        var parsedByEntryID: [String: ParsedProcess] = [:]
        parsedByEntryID.reserveCapacity(entries.count)

        var resolveRazorCache: [String: GearOverride] = [:]
        var resolveBladeCache: [String: GearOverride] = [:]

        func resolvedRazor(_ raw: String) -> GearOverride {
            if let hit = resolveRazorCache[raw] { return hit }
            let ov = GearCatalogService.resolveGear(category: .razor, rawValue: raw, in: database).override
            resolveRazorCache[raw] = ov
            return ov
        }

        func resolvedBlade(_ raw: String) -> GearOverride {
            if let hit = resolveBladeCache[raw] { return hit }
            let ov = GearCatalogService.resolveGear(category: .blade, rawValue: raw, in: database).override
            resolveBladeCache[raw] = ov
            return ov
        }

        var validResultCount = 0
        var validIrritationCount = 0
        var bbsCount = 0
        var painlessCount = 0
        var hotTowelCount = 0
        var afterShowerCount = 0
        var alumCount = 0
        var minDate: Date? = nil
        var maxDate: Date? = nil
        var parsedDateCount = 0

        var latheringCounts: [String: Int] = [:]
        var loadingCounts: [String: Int] = [:]
        var resultCounts: [ShaveResult: Int] = [:]
        var irritationCounts: [IrritationLevel: Int] = [:]
        var monthCounts: [String: Int] = [:]
        var comboMap: [String: RazorBladeComboStat] = [:]
        var bladeMap: [String: (brand: String, name: String, uses: [Int], total: Int)] = [:]

        var entriesByDate: [String: [JournalEntry]] = [:]
        var calendarSeverityByDate: [String: DayCalendarSeverity] = [:]

        for entry in entries {
            let procText = entry.processText
            let proc: ParsedProcess
            if let hit = parsedByTextCache[procText] {
                proc = hit
            } else {
                proc = ProcessParser.parse(procText)
                parsedByTextCache[procText] = proc
            }
            parsedByEntryID[entry.id] = proc

            if let res = proc.result {
                validResultCount += 1
                resultCounts[res, default: 0] += 1
                if res == .bbs { bbsCount += 1 }
            }
            if let irr = proc.irritation {
                validIrritationCount += 1
                irritationCounts[irr, default: 0] += 1
                if irr == .painless { painlessCount += 1 }
            }
            if entry.hotTowel { hotTowelCount += 1 }
            if entry.afterShower.hasPrefix("是") { afterShowerCount += 1 }
            if entry.alum.hasPrefix("是") { alumCount += 1 }

            if let d = entry.parsedDate {
                parsedDateCount += 1
                if minDate == nil || d < minDate! { minDate = d }
                if maxDate == nil || d > maxDate! { maxDate = d }
            }

            let lath = entry.pureLatheringMethod
            if !lath.isEmpty { latheringCounts[lath, default: 0] += 1 }
            let load = entry.loadingMethod
            if !load.isEmpty { loadingCounts[load, default: 0] += 1 }

            if entry.date.count >= 7 {
                let ym = String(entry.date.prefix(7))
                monthCounts[ym, default: 0] += 1
            }

            // 日历按日期分组与最严重肤感状态聚合
            entriesByDate[entry.date, default: []].append(entry)
            let sev = calendarSeverity(for: proc, rawProcess: procText)
            if let prev = calendarSeverityByDate[entry.date] {
                if sev > prev { calendarSeverityByDate[entry.date] = sev }
            } else {
                calendarSeverityByDate[entry.date] = sev
            }

            // S09：优先按编号槽位精确配对（剃须刀1↔刀片1、剃须刀2↔刀片2），若无对齐编号再按位置配对
            let slottedRazors = entry.slottedFieldValues(prefix: "剃须刀")
            let slottedBlades = entry.slottedFieldValues(prefix: "刀片")
            let pairs = pairRazorsAndBlades(razors: slottedRazors, blades: slottedBlades)

            for (rawRazor, rawBlade) in pairs {
                let rOv = resolvedRazor(rawRazor)
                let bOv = resolvedBlade(rawBlade)
                let key = "\(rOv.name)||\(bOv.name)"
                var stat = comboMap[key] ?? RazorBladeComboStat(
                    razorBrand: rOv.brand,
                    razorName: rOv.name,
                    bladeBrand: bOv.brand,
                    bladeName: bOv.name,
                    uses: 0,
                    bbsCount: 0,
                    painlessCount: 0,
                    mildCount: 0,
                    stingingCount: 0
                )
                stat.uses += 1
                if proc.result == .bbs { stat.bbsCount += 1 }
                if proc.irritation == .painless { stat.painlessCount += 1 }
                if proc.irritation == .mild { stat.mildCount += 1 }
                if proc.irritation == .stinging { stat.stingingCount += 1 }
                comboMap[key] = stat
            }

            for (_, rawBlade) in slottedBlades {
                let parsed = GearKnowledgeBase.parseBladeUsage(rawBlade)
                let ov = resolvedBlade(rawBlade)
                var rec = bladeMap[ov.name] ?? (ov.brand, ov.name, [], 0)
                rec.total += 1
                if let u = parsed.useCount { rec.uses.append(u) }
                bladeMap[ov.name] = rec
            }
        }

        let latheringDist = latheringCounts
            .map { DistributionSlice(name: L10n.latheringDisplay($0.key), count: $0.value) }
            .sorted { $0.count > $1.count }

        let loadingDist = loadingCounts
            .map { DistributionSlice(name: L10n.loadingDisplay($0.key), count: $0.value) }
            .sorted { $0.count > $1.count }

        let resultDist = ShaveResult.allCases.compactMap { r -> DistributionSlice? in
            guard let c = resultCounts[r], c > 0 else { return nil }
            return DistributionSlice(name: r.displayName, count: c)
        }

        let irritationDist = IrritationLevel.allCases.compactMap { irr -> DistributionSlice? in
            guard let c = irritationCounts[irr], c > 0 else { return nil }
            return DistributionSlice(name: irr.displayName, count: c)
        }

        let monthlyTrend = monthCounts
            .sorted { $0.key < $1.key }
            .suffix(12)
            .map { MonthlyShavePoint(month: $0.key, count: $0.value) }

        let comboStats = Array(comboMap.values).sorted { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            return a.comfortScore > b.comfortScore
        }

        let bladeLongevityStats: [BladeLongevityStat] = bladeMap.values.compactMap { rec in
            guard rec.total >= 2 else { return nil }
            let maxU = rec.uses.max() ?? 1
            let ones = max(1, rec.uses.filter { $0 == 1 }.count)
            let avg = rec.uses.isEmpty ? 1.0 : Double(rec.uses.count) / Double(ones)
            return BladeLongevityStat(
                brand: rec.brand,
                bladeName: rec.name,
                totalShaves: rec.total,
                maxUseCount: maxU,
                avgCycleUses: min(Double(maxU), max(1.0, avg)),
                isEstimated: true
            )
        }
        .sorted { $0.totalShaves > $1.totalShaves }

        var calendarStatusByDate: [String: DayCalendarStatus] = [:]
        calendarStatusByDate.reserveCapacity(entriesByDate.count)
        for (date, list) in entriesByDate {
            calendarStatusByDate[date] = DayCalendarStatus(
                date: date,
                entryIDs: list.map(\.id),
                worstSeverity: calendarSeverityByDate[date] ?? .painless
            )
        }

        let avgIntervalDays: Double = {
            guard parsedDateCount >= 2, let first = minDate, let last = maxDate else { return 0 }
            return (last.timeIntervalSince(first) / 86400.0) / Double(parsedDateCount - 1)
        }()

        return StatisticsSnapshot(
            revision: revision,
            isEnglish: isEnglish,
            totalEntries: entries.count,
            validResultCount: validResultCount,
            validIrritationCount: validIrritationCount,
            bbsCount: bbsCount,
            painlessCount: painlessCount,
            hotTowelCount: hotTowelCount,
            afterShowerCount: afterShowerCount,
            alumCount: alumCount,
            avgIntervalDays: avgIntervalDays,
            latheringDistribution: latheringDist,
            loadingDistribution: loadingDist,
            resultDistribution: resultDist,
            irritationDistribution: irritationDist,
            irritationCountsByLevel: irritationCounts,
            monthlyTrend: monthlyTrend,
            comboStats: comboStats,
            bladeLongevityStats: bladeLongevityStats,
            parsedProcessByEntryID: parsedByEntryID,
            entriesByDate: entriesByDate,
            calendarStatusByDate: calendarStatusByDate
        )
    }

    static func pairRazorsAndBlades(
        razors: [(slot: String, value: String)],
        blades: [(slot: String, value: String)]
    ) -> [(razor: String, blade: String)] {
        guard !razors.isEmpty, !blades.isEmpty else { return [] }

        // 若存在显式编号槽位（如 剃须刀1/剃须刀2 与 刀片1/刀片2），优先按相同槽位精确匹配（S09）
        let bladeBySlot: [String: String] = Dictionary(
            blades.map { ($0.slot, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
        let hasNumberedSlots = razors.contains { !$0.slot.isEmpty } && blades.contains { !$0.slot.isEmpty }
        if hasNumberedSlots {
            let matched = razors.compactMap { r -> (String, String)? in
                guard let b = bladeBySlot[r.slot] else { return nil }
                return (r.value, b)
            }
            if !matched.isEmpty {
                return matched
            }
        }

        let pairCount = min(razors.count, blades.count)
        return (0..<pairCount).map { (razors[$0].value, blades[$0].value) }
    }

    private static func calendarSeverity(for parsed: ParsedProcess, rawProcess: String) -> DayCalendarSeverity {
        if parsed.irritation == .stinging || rawProcess.contains("刮伤") || rawProcess.contains("出血") || rawProcess.contains("血点") {
            return .stinging
        }
        if parsed.irritation == .mild {
            return .mild
        }
        return .painless
    }

    /// 复用已构建的 StatisticsSnapshot 与 GearCatalogSnapshot 生成 AI 复盘摘要（消除重复全量解析）
    static func buildDiagnosisStatsSummary(
        database: JournalDatabase,
        catalog: GearCatalogSnapshot,
        snapshot: StatisticsSnapshot
    ) -> String {
        let entries = database.entries
        let parsedList = entries.compactMap { snapshot.parsedProcessByEntryID[$0.id] }
        let bbsValid = parsedList.filter { $0.result != nil }
        let bbsPct = bbsValid.isEmpty ? 0 : Int(Double(bbsValid.filter { $0.result == .bbs }.count) / Double(bbsValid.count) * 100)
        let irrValid = parsedList.filter { $0.irritation != nil }
        let painlessPct = irrValid.isEmpty ? 0 : Int(Double(irrValid.filter { $0.irritation == .painless }.count) / Double(irrValid.count) * 100)
        let mildPct = irrValid.isEmpty ? 0 : Int(Double(irrValid.filter { $0.irritation == .mild }.count) / Double(irrValid.count) * 100)
        let stingPct = irrValid.isEmpty ? 0 : Int(Double(irrValid.filter { $0.irritation == .stinging }.count) / Double(irrValid.count) * 100)

        func comfortRate(for subset: [JournalEntry]) -> String {
            let p = subset.compactMap { snapshot.parsedProcessByEntryID[$0.id] }.filter { $0.irritation != nil }
            guard !p.isEmpty else { return "n/a" }
            let ok = p.filter { $0.irritation == .painless }.count
            return "\(Int(Double(ok) / Double(p.count) * 100))% painless (n=\(p.count))"
        }

        let hotYes = entries.filter(\.hotTowel)
        let hotNo = entries.filter { !$0.hotTowel }
        let showerYes = entries.filter { $0.afterShower.hasPrefix("是") }
        let showerNo = entries.filter { !$0.afterShower.hasPrefix("是") }
        let bowlLather = entries.filter { $0.pureLatheringMethod == "碗起" }
        let faceLather = entries.filter { $0.pureLatheringMethod == "脸起" }

        let topRazors = catalog.items(for: .razor).prefix(6).map { "\($0.name)(\($0.count))" }.joined(separator: ", ")
        let topBlades = catalog.items(for: .blade).prefix(6).map { "\($0.name)(\($0.count))" }.joined(separator: ", ")
        let topBrushes = catalog.items(for: .brush).prefix(5).map { "\($0.name)(\($0.count))" }.joined(separator: ", ")
        let topSoaps = catalog.items(for: .soap).prefix(5).map { "\($0.name)(\($0.count))" }.joined(separator: ", ")

        let combos = snapshot.comboStats
        let golden = combos.filter { $0.uses >= 2 }.sorted { $0.comfortScore > $1.comfortScore }.prefix(6)
            .map { "\($0.razorName) + \($0.bladeName) (\(Int($0.painlessRate * 100))% painless, \(Int($0.bbsRate * 100))% BBS, n=\($0.uses))" }
            .joined(separator: "; ")
        let stinging = combos.filter { $0.stingingCount > 0 || ($0.mildCount > 0 && $0.painlessCount == 0) }
            .sorted { $0.stingingCount > $1.stingingCount }.prefix(6)
            .map { "\($0.razorName) + \($0.bladeName) (stinging:\($0.stingingCount), mild:\($0.mildCount), n=\($0.uses))" }
            .joined(separator: "; ")

        return """
        Total SOTD entries: \(entries.count)
        BBS rate: \(bbsPct)%
        Comfort breakdown: Painless \(painlessPct)%, Mild \(mildPct)%, Stinging \(stingPct)%
        Hot towel: YES = \(comfortRate(for: hotYes)) | NO = \(comfortRate(for: hotNo))
        Post-shower: YES = \(comfortRate(for: showerYes)) | NO = \(comfortRate(for: showerNo))
        Lather method: Bowl = \(comfortRate(for: bowlLather)) | Face = \(comfortRate(for: faceLather))
        Top Razors: \(topRazors)
        Top Blades: \(topBlades)
        Top Brushes: \(topBrushes)
        Top Soaps: \(topSoaps)
        Golden Combos: \(golden.isEmpty ? "none" : golden)
        High-Irritation Combos: \(stinging.isEmpty ? "none" : stinging)
        """
    }
}
