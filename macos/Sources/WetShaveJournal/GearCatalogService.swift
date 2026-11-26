import Foundation

/// 器材聚合衍生快照（与 JournalStore.revision 绑定，单次扫描构建全部分类与品牌分组，消除 SwiftUI 渲染期重复全量扫描）
struct GearCatalogSnapshot {
    var revision: UInt64
    var itemsByCategory: [GearCategory: [GearItem]]
    var brandGroupsByCategory: [GearCategory: [BrandGroup]]
    var pendingItems: [GearItem]
    var catalogNamesByCategory: [GearCategory: [String]]

    func items(for category: GearCategory) -> [GearItem] {
        itemsByCategory[category] ?? []
    }

    func brandGroups(for category: GearCategory) -> [BrandGroup] {
        brandGroupsByCategory[category] ?? []
    }

    static let empty = GearCatalogSnapshot(
        revision: 0,
        itemsByCategory: [:],
        brandGroupsByCategory: [:],
        pendingItems: [],
        catalogNamesByCategory: [:]
    )
}

/// 纯函数器材解析、索引聚合、检索与 CSV 导出服务
enum GearCatalogService {
    private struct Agg {
        var brand: String
        var name: String
        var model: String
        var count: Int = 0
        var lastDate: String = ""
        var rawKeys: Set<String> = []
        var override: GearOverride
        var isPending: Bool = false
    }

    static func resolveGear(category: GearCategory, rawValue: String, in db: JournalDatabase) -> (key: String, override: GearOverride) {
        let effectiveRaw: String
        switch category {
        case .blade:
            effectiveRaw = GearKnowledgeBase.parseBladeUsage(rawValue).baseName
        case .bowl:
            effectiveRaw = GearKnowledgeBase.extractBowlName(from: rawValue) ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            effectiveRaw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let norm = GearKnowledgeBase.normalizeKey(effectiveRaw)
        let fullKey = "\(category.rawValue)|\(norm)"

        if var existing = db.overrides[fullKey] {
            existing.status = GearStatus.normalized(existing.status, for: category)
            if category == .blade, existing.bladeType == nil {
                existing.bladeType = GearKnowledgeBase.inferBladeType(from: existing.name)
            }
            return (fullKey, existing)
        }

        // 若输入为某件已有器材的规范显示名（如点选「Feather New Hi-Stainless」而旧规则键为「刀片|featherde」），
        // 反向映射至唯一匹配的既有 override，避免器材库与统计引擎分裂出重复条目
        let prefix = "\(category.rawValue)|"
        var matchedIdentity: String? = nil
        var matchedOverride: GearOverride? = nil
        var isAmbiguous = false
        for (k, ov) in db.overrides where k.hasPrefix(prefix) {
            let nameNorm = GearKnowledgeBase.normalizeKey(ov.name)
            let canonicalNorm = GearKnowledgeBase.normalizeKey(ov.canonicalDisplayName)
            guard nameNorm == norm || canonicalNorm == norm else { continue }
            var hydrated = ov
            hydrated.status = GearStatus.normalized(hydrated.status, for: category)
            if category == .blade, hydrated.bladeType == nil {
                hydrated.bladeType = GearKnowledgeBase.inferBladeType(from: hydrated.name)
            }
            let sig = variantSignature(category: category, override: hydrated)
            let identity = "\(category.rawValue)|\(hydrated.brand.lowercased())|\(hydrated.name.lowercased())|\(sig)"
            if let prevId = matchedIdentity {
                if prevId != identity {
                    isAmbiguous = true
                    break
                }
            } else {
                matchedIdentity = identity
                matchedOverride = hydrated
            }
        }
        if !isAmbiguous, let resolvedExisting = matchedOverride {
            return (fullKey, resolvedExisting)
        }

        let inferred = GearKnowledgeBase.inferDefaultOverride(rawName: effectiveRaw, category: category)
        return (fullKey, inferred)
    }

    /// 联想菜单点选后填入输入框的规范显示名（所见即所得；同品牌同型号存在多规格变体时自动附加区分规格）
    static func autocompleteInsertText(for item: GearItem, in allItems: [GearItem]) -> String {
        let base = item.canonicalDisplayName
        let baseNorm = GearKnowledgeBase.normalizeKey(base)
        let hasCollision = allItems.contains { other in
            other.id != item.id && GearKnowledgeBase.normalizeKey(other.canonicalDisplayName) == baseNorm
        }
        guard hasCollision else { return base }

        var extras: [String] = []
        switch item.category {
        case .razor:
            if let mat = item.material?.trimmingCharacters(in: .whitespacesAndNewlines), !mat.isEmpty,
               !base.lowercased().contains(mat.lowercased()) {
                extras.append(mat)
            }
            if let pt = item.plateType, !base.uppercased().contains(pt.rawValue) {
                extras.append(pt.rawValue)
            }
            if let gap = GearSpecFormatter.shortSpecTag(item.gapOrSpec), !base.lowercased().contains(gap.lowercased()) {
                extras.append(gap)
            }
        case .brush:
            if let hb = item.handleBrand?.trimmingCharacters(in: .whitespacesAndNewlines), !hb.isEmpty,
               !base.lowercased().contains(hb.lowercased()) {
                extras.append(hb)
            }
            if let ks = item.knotSize?.trimmingCharacters(in: .whitespacesAndNewlines), !ks.isEmpty,
               !base.lowercased().contains(ks.lowercased()) {
                extras.append(ks)
            }
        case .soap, .afterShave:
            if item.isSample {
                extras.append("小样")
            }
        default:
            break
        }
        return extras.isEmpty ? base : "\(base) (\(extras.joined(separator: " ")))"
    }

    static func variantSignature(category: GearCategory, override ov: GearOverride) -> String {
        switch category {
        case .razor:
            return [
                ov.material?.lowercased() ?? "",
                ov.plateType?.rawValue ?? "",
                (ov.isSlant == true) ? "slant" : "",
                ov.gapOrSpec?.lowercased() ?? ""
            ].joined(separator: "#")
        case .brush:
            return [
                ov.handleBrand?.lowercased() ?? "",
                ov.knotSize?.lowercased() ?? "",
                ov.knotShape?.rawValue ?? "",
                ov.badgerBand?.rawValue ?? "",
                ov.badgerTreatment?.rawValue ?? ""
            ].joined(separator: "#")
        default:
            return ""
        }
    }

    /// 单次遍历 entries + overrides 构建全部 7 个分类的统一快照（R02）
    static func buildSnapshot(from db: JournalDatabase, revision: UInt64) -> GearCatalogSnapshot {
        var buckets: [GearCategory: [String: Agg]] = [:]
        for cat in GearCategory.allCases {
            buckets[cat] = [:]
        }
        let pendingSet = Set(db.pending)
        // 本地临时缓存：避免同一次快照构建中对同一原始名称重复执行品牌/材质启发式推断
        var resolveCache: [String: (key: String, override: GearOverride)] = [:]
        resolveCache.reserveCapacity(max(64, db.overrides.count * 2))

        func cachedResolve(category: GearCategory, rawValue: String) -> (key: String, override: GearOverride) {
            let cacheKey = "\(category.rawValue)\u{1F}\(rawValue)"
            if let hit = resolveCache[cacheKey] {
                return hit
            }
            let res = resolveGear(category: category, rawValue: rawValue, in: db)
            resolveCache[cacheKey] = res
            return res
        }

        func merge(category: GearCategory, rawKey: String, override rawOv: GearOverride, date: String?, countDelta: Int) {
            var override = rawOv
            override.status = GearStatus.normalized(override.status, for: category)
            let sig = variantSignature(category: category, override: override)
            let identity = "\(category.rawValue)|\(override.brand.lowercased())|\(override.name.lowercased())|\(sig)"
            let pending = pendingSet.contains(rawKey)
            if var agg = buckets[category]?[identity] {
                agg.count += countDelta
                if let d = date, d > agg.lastDate { agg.lastDate = d }
                agg.rawKeys.insert(rawKey)
                agg.isPending = agg.isPending || pending
                mergeMissingFields(into: &agg.override, from: override)
                buckets[category]?[identity] = agg
            } else {
                buckets[category]?[identity] = Agg(
                    brand: override.brand.isEmpty ? "品牌未注明" : override.brand,
                    name: override.name,
                    model: override.displayModel,
                    count: countDelta,
                    lastDate: date ?? "",
                    rawKeys: [rawKey],
                    override: override,
                    isPending: pending
                )
            }
        }

        for entry in db.entries {
            var hasExplicitBowl = false
            var latheringRaw: String? = nil

            for field in entry.fields {
                let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if field.label == "起泡" {
                    latheringRaw = trimmed
                    continue
                }
                guard !trimmed.isEmpty, trimmed != "无", trimmed != "-" else { continue }
                guard let category = categoryForFieldLabel(field.label) else { continue }
                if category == .bowl {
                    hasExplicitBowl = true
                }
                let (key, ov) = cachedResolve(category: category, rawValue: trimmed)
                merge(category: category, rawKey: key, override: ov, date: entry.date, countDelta: 1)
            }

            if !hasExplicitBowl,
               let lath = latheringRaw,
               let inferredBowl = GearKnowledgeBase.extractBowlName(from: lath),
               !inferredBowl.isEmpty {
                let (key, ov) = cachedResolve(category: .bowl, rawValue: inferredBowl)
                merge(category: .bowl, rawKey: key, override: ov, date: entry.date, countDelta: 1)
            }
        }

        for (k, ov) in db.overrides {
            guard let sepIdx = k.firstIndex(of: "|"),
                  let cat = GearCategory(rawValue: String(k[..<sepIdx])) else {
                continue
            }
            var adjusted = ov
            if cat == .blade, adjusted.bladeType == nil {
                adjusted.bladeType = GearKnowledgeBase.inferBladeType(from: adjusted.name)
            }
            merge(category: cat, rawKey: k, override: adjusted, date: nil, countDelta: 0)
        }

        var itemsByCategory: [GearCategory: [GearItem]] = [:]
        var brandGroupsByCategory: [GearCategory: [BrandGroup]] = [:]
        var pendingItems: [GearItem] = []
        var catalogNamesByCategory: [GearCategory: [String]] = [:]

        for cat in GearCategory.allCases {
            let items = finalizeItems(from: buckets[cat] ?? [:], category: cat)
            itemsByCategory[cat] = items
            brandGroupsByCategory[cat] = brandGroups(for: items)
            catalogNamesByCategory[cat] = items.map(\.name)
            pendingItems.append(contentsOf: items.filter(\.isPending))
        }

        return GearCatalogSnapshot(
            revision: revision,
            itemsByCategory: itemsByCategory,
            brandGroupsByCategory: brandGroupsByCategory,
            pendingItems: pendingItems,
            catalogNamesByCategory: catalogNamesByCategory
        )
    }

    /// 无缓存即时聚合单分类（专供候选数据库校验与合并验证使用，绝不读旧缓存）
    static func gearItems(for category: GearCategory, in db: JournalDatabase) -> [GearItem] {
        var byMergedIdentity: [String: Agg] = [:]
        let pendingSet = Set(db.pending)
        var resolveCache: [String: (key: String, override: GearOverride)] = [:]

        func merge(rawKey: String, override rawOv: GearOverride, date: String?, countDelta: Int) {
            var override = rawOv
            override.status = GearStatus.normalized(override.status, for: category)
            let sig = variantSignature(category: category, override: override)
            let identity = "\(category.rawValue)|\(override.brand.lowercased())|\(override.name.lowercased())|\(sig)"
            let pending = pendingSet.contains(rawKey)
            if var agg = byMergedIdentity[identity] {
                agg.count += countDelta
                if let d = date, d > agg.lastDate { agg.lastDate = d }
                agg.rawKeys.insert(rawKey)
                agg.isPending = agg.isPending || pending
                mergeMissingFields(into: &agg.override, from: override)
                byMergedIdentity[identity] = agg
            } else {
                byMergedIdentity[identity] = Agg(
                    brand: override.brand.isEmpty ? "品牌未注明" : override.brand,
                    name: override.name,
                    model: override.displayModel,
                    count: countDelta,
                    lastDate: date ?? "",
                    rawKeys: [rawKey],
                    override: override,
                    isPending: pending
                )
            }
        }

        for entry in db.entries {
            let values: [String]
            switch category {
            case .razor: values = entry.fieldValues(matching: ["剃须刀"])
            case .blade: values = entry.fieldValues(matching: ["刀片"])
            case .brush: values = entry.fieldValues(matching: ["剃须刷"])
            case .soap: values = entry.fieldValues(matching: ["剃须皂"])
            case .preShave: values = entry.fieldValues(matching: ["须前"])
            case .afterShave: values = entry.fieldValues(matching: ["须后"])
            case .bowl:
                let b = entry.bowl
                values = b.isEmpty ? [] : [b]
            }

            for v in values {
                let resolved: (key: String, override: GearOverride)
                if let hit = resolveCache[v] {
                    resolved = hit
                } else {
                    resolved = resolveGear(category: category, rawValue: v, in: db)
                    resolveCache[v] = resolved
                }
                merge(rawKey: resolved.key, override: resolved.override, date: entry.date, countDelta: 1)
            }
        }

        let prefix = "\(category.rawValue)|"
        for (k, ov) in db.overrides where k.hasPrefix(prefix) {
            var adjusted = ov
            if category == .blade, adjusted.bladeType == nil {
                adjusted.bladeType = GearKnowledgeBase.inferBladeType(from: adjusted.name)
            }
            merge(rawKey: k, override: adjusted, date: nil, countDelta: 0)
        }

        return finalizeItems(from: byMergedIdentity, category: category)
    }

    private static func categoryForFieldLabel(_ label: String) -> GearCategory? {
        for cat in GearCategory.allCases {
            let prefix = cat.rawValue
            if label == prefix || (label.hasPrefix(prefix) && label.dropFirst(prefix.count).allSatisfy({ $0.isNumber })) {
                return cat
            }
        }
        return nil
    }

    private static func mergeMissingFields(into dst: inout GearOverride, from src: GearOverride) {
        if dst.material == nil, let m = src.material { dst.material = m }
        if dst.plateType == nil, let p = src.plateType { dst.plateType = p }
        if dst.gapOrSpec == nil, let g = src.gapOrSpec { dst.gapOrSpec = g }
        if dst.razorType == nil, let rt = src.razorType { dst.razorType = rt }
        if dst.isAdjustable != true, src.isAdjustable == true { dst.isAdjustable = true }
        if dst.isSlant != true, src.isSlant == true { dst.isSlant = true }
        if dst.bladeType == nil, let bt = src.bladeType { dst.bladeType = bt }
        if dst.handleBrand == nil, let hb = src.handleBrand { dst.handleBrand = hb }
        if dst.brushMaterial == nil, let bm = src.brushMaterial { dst.brushMaterial = bm }
        if dst.badgerTreatment == nil, let tr = src.badgerTreatment { dst.badgerTreatment = tr }
        if dst.badgerBand == nil, let bb = src.badgerBand { dst.badgerBand = bb }
        if dst.knotSize == nil, let ks = src.knotSize { dst.knotSize = ks }
        if dst.knotShape == nil, let sh = src.knotShape { dst.knotShape = sh }
        if dst.isSample != true, src.isSample == true { dst.isSample = true }
        if dst.status == nil, let st = src.status { dst.status = st }
        if dst.isManuallyConfirmed != true, src.isManuallyConfirmed == true {
            dst.isManuallyConfirmed = true
        }
    }

    private static func finalizeItems(from map: [String: Agg], category: GearCategory) -> [GearItem] {
        map.map { (_, agg) in
            let primaryKey = agg.rawKeys.sorted().first ?? "\(category.rawValue)|\(GearKnowledgeBase.normalizeKey(agg.name))"
            let normalizedStatus = GearStatus.normalized(agg.override.status, for: category)
            return GearItem(
                id: primaryKey,
                category: category,
                canonicalKey: primaryKey,
                brand: agg.brand,
                name: agg.name,
                model: agg.override.displayModel,
                count: agg.count,
                lastUsedDate: agg.lastDate,
                rawKeys: Array(agg.rawKeys).sorted(),
                isPending: agg.isPending,
                razorType: agg.override.razorType,
                isAdjustable: agg.override.isAdjustable ?? false,
                isSlant: agg.override.isSlant ?? false,
                material: agg.override.material,
                plateType: agg.override.plateType,
                gapOrSpec: agg.override.gapOrSpec,
                bladeType: agg.override.bladeType,
                handleBrand: agg.override.handleBrand,
                brushMaterial: agg.override.brushMaterial,
                badgerTreatment: agg.override.badgerTreatment,
                badgerBand: agg.override.badgerBand,
                knotSize: agg.override.knotSize,
                knotShape: agg.override.knotShape,
                isSample: agg.override.isSample ?? false,
                status: normalizedStatus,
                notes: agg.override.notes,
                recognizedSource: agg.override.recognizedSource,
                isManuallyConfirmed: agg.override.isManuallyConfirmed == true
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.lastUsedDate > rhs.lastUsedDate
        }
    }

    static func brandGroups(for items: [GearItem]) -> [BrandGroup] {
        let grouped = Dictionary(grouping: items, by: { $0.brand })
        return grouped.map { brand, list in
            let sorted = list.sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.name < b.name
            }
            return BrandGroup(
                brand: brand,
                items: sorted,
                totalUses: sorted.reduce(0) { $0 + $1.count },
                latestDate: sorted.map(\.lastUsedDate).max() ?? ""
            )
        }
        .sorted { a, b in
            if a.totalUses != b.totalUses { return a.totalUses > b.totalUses }
            return a.brand < b.brand
        }
    }

    static func searchCandidates(in all: [GearItem], query: String) -> [GearItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [GearItem]
        if q.isEmpty {
            filtered = all
        } else {
            filtered = all.filter { item in
                item.name.lowercased().contains(q) ||
                item.brand.lowercased().contains(q) ||
                item.model.lowercased().contains(q) ||
                item.canonicalDisplayName.lowercased().contains(q) ||
                item.rawKeys.contains(where: { $0.lowercased().contains(q) }) ||
                (item.handleBrand?.lowercased().contains(q) ?? false) ||
                (item.gapOrSpec?.lowercased().contains(q) ?? false) ||
                (item.material?.lowercased().contains(q) ?? false)
            }
        }
        return filtered.sorted { a, b in
            if a.status.searchPriority != b.status.searchPriority {
                return a.status.searchPriority < b.status.searchPriority
            }
            if a.count != b.count { return a.count > b.count }
            return a.lastUsedDate > b.lastUsedDate
        }
    }

    static func eligibleDrawItems(in all: [GearItem], category: GearCategory, matchingRazor razor: GearItem? = nil) -> [GearItem] {
        if category == .blade {
            let inStock = all.filter { $0.status == .inStock }
            guard let razor = razor, let rType = razor.razorType else { return inStock }
            if !rType.requiresBlade { return [] }
            if let requiredBladeType = rType.matchingBladeType {
                return inStock.filter { $0.bladeType == requiredBladeType }
            }
            return inStock
        } else {
            return all.filter { $0.status == .active }
        }
    }

    static func rawEntrySamples(forRawKey rawKey: String, category: GearCategory, in db: JournalDatabase) -> (display: String, count: Int) {
        var counts: [String: Int] = [:]
        for entry in db.entries {
            let values: [String]
            switch category {
            case .razor: values = entry.fieldValues(matching: ["剃须刀"])
            case .blade: values = entry.fieldValues(matching: ["刀片"]).map { GearKnowledgeBase.parseBladeUsage($0).baseName }
            case .brush: values = entry.fieldValues(matching: ["剃须刷"])
            case .soap: values = entry.fieldValues(matching: ["剃须皂"])
            case .preShave: values = entry.fieldValues(matching: ["须前"])
            case .afterShave: values = entry.fieldValues(matching: ["须后"])
            case .bowl:
                let b = entry.bowl
                values = b.isEmpty ? [] : [b]
            }
            for v in values {
                let k = "\(category.rawValue)|\(GearKnowledgeBase.normalizeKey(v))"
                if k == rawKey { counts[v, default: 0] += 1 }
            }
        }
        let total = counts.values.reduce(0, +)
        if let best = counts.max(by: { $0.value < $1.value })?.key {
            return (best, total)
        }
        let suffix = rawKey.split(separator: "|", maxSplits: 1).last.map(String.init) ?? rawKey
        return (suffix, 0)
    }

    static func isRazorAdjustable(_ razorText: String, in db: JournalDatabase) -> Bool {
        let trimmed = razorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let (_, ov) = resolveGear(category: .razor, rawValue: trimmed, in: db)
        if let adj = ov.isAdjustable { return adj }
        let lower = trimmed.lowercased()
        return GearKnowledgeBase.knownAdjustableKeywords.contains(where: { lower.contains($0) })
    }

    static func suggestedNextUseCount(forBlade baseBladeName: String, in db: JournalDatabase) -> Int {
        let baseRaw = GearKnowledgeBase.parseBladeUsage(baseBladeName).baseName
        let targetNorm = GearKnowledgeBase.normalizeKey(baseRaw)
        guard !targetNorm.isEmpty else { return 1 }
        let (_, targetOv) = resolveGear(category: .blade, rawValue: baseRaw, in: db)
        let targetOvNameNorm = GearKnowledgeBase.normalizeKey(targetOv.name)
        let targetCanonicalNorm = GearKnowledgeBase.normalizeKey(targetOv.canonicalDisplayName)
        for entry in db.entries {
            for raw in entry.fieldValues(matching: ["刀片"]) {
                let parsed = GearKnowledgeBase.parseBladeUsage(raw)
                let (_, ov) = resolveGear(category: .blade, rawValue: raw, in: db)
                let entryBaseNorm = GearKnowledgeBase.normalizeKey(parsed.baseName)
                let entryOvNameNorm = GearKnowledgeBase.normalizeKey(ov.name)
                let entryCanonicalNorm = GearKnowledgeBase.normalizeKey(ov.canonicalDisplayName)
                if entryBaseNorm == targetNorm ||
                   entryOvNameNorm == targetNorm ||
                   entryOvNameNorm == targetOvNameNorm ||
                   entryCanonicalNorm == targetNorm ||
                   entryCanonicalNorm == targetCanonicalNorm {
                    return (parsed.useCount ?? 1) + 1
                }
            }
        }
        return 1
    }

    // MARK: - 器材引用检测与键工具

    static func removalKeys(for item: GearItem) -> Set<String> {
        var keys = Set(item.rawKeys)
        keys.insert(item.canonicalKey)
        let normKey = "\(item.category.rawValue)|\(GearKnowledgeBase.normalizeKey(item.name))"
        keys.insert(normKey)
        let canonicalDisplayKey = "\(item.category.rawValue)|\(GearKnowledgeBase.normalizeKey(item.canonicalDisplayName))"
        keys.insert(canonicalDisplayKey)
        return keys
    }

    static func fieldLabelPrefixes(for category: GearCategory) -> [String] {
        [category.rawValue]
    }

    static func labelMatchesCategory(_ label: String, prefixes: [String]) -> Bool {
        for prefix in prefixes {
            if label == prefix || (label.hasPrefix(prefix) && label.dropFirst(prefix.count).allSatisfy({ $0.isNumber })) {
                return true
            }
        }
        return false
    }

    static func normalizedKeyForFieldValue(_ rawValue: String, category: GearCategory) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "无", trimmed != "-" else { return nil }
        let effective: String
        switch category {
        case .blade:
            effective = GearKnowledgeBase.parseBladeUsage(trimmed).baseName
        case .bowl:
            effective = GearKnowledgeBase.extractBowlName(from: trimmed) ?? trimmed
        default:
            effective = trimmed
        }
        guard !effective.isEmpty else { return nil }
        return "\(category.rawValue)|\(GearKnowledgeBase.normalizeKey(effective))"
    }

    static func entryReferencesGear(_ entry: JournalEntry, category: GearCategory, targetKeys: Set<String>) -> Bool {
        let prefixes = fieldLabelPrefixes(for: category)
        for field in entry.fields {
            if labelMatchesCategory(field.label, prefixes: prefixes) {
                if let key = normalizedKeyForFieldValue(field.value, category: category),
                   targetKeys.contains(key) {
                    return true
                }
            } else if category == .bowl, field.label == "起泡" {
                let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let bowlName = GearKnowledgeBase.extractBowlName(from: trimmed) {
                    let key = "\(GearCategory.bowl.rawValue)|\(GearKnowledgeBase.normalizeKey(bowlName))"
                    if targetKeys.contains(key) {
                        return true
                    }
                }
            }
        }
        return false
    }

    static func referencedEntryCount(for item: GearItem, in db: JournalDatabase) -> Int {
        let keys = removalKeys(for: item)
        return db.entries.reduce(0) { partial, entry in
            partial + (entryReferencesGear(entry, category: item.category, targetKeys: keys) ? 1 : 0)
        }
    }

    // MARK: - 导出装备资料库（CSV）

    static func exportGearLibraryCSV(catalog: GearCatalogSnapshot) -> String {
        let headers = [
            "分类", "品牌", "手柄品牌", "型号", "完整名称", "使用次数", "最近使用",
            "状态", "小样", "待确认", "刀型", "可调刀", "Slant斜头", "剃须刀材质", "底板形制",
            "刀隙/版本", "刀片类型", "刷毛材质", "獾毛处理", "獾毛段数", "结径", "毛型", "备注"
        ]
        var lines: [String] = [headers.map(csvEscape).joined(separator: ",")]
        for cat in GearCategory.allCases {
            for item in catalog.items(for: cat) {
                let row: [String] = [
                    cat.rawValue,
                    item.brand,
                    item.handleBrand ?? "",
                    item.model,
                    item.name,
                    "\(item.count)",
                    item.lastUsedDate,
                    item.status.rawValue,
                    item.isSample ? "是" : "",
                    item.isPending ? "待确认" : "",
                    item.razorType?.rawValue ?? "",
                    item.isAdjustable ? "是" : "",
                    item.isSlant ? "是" : "",
                    item.material ?? "",
                    item.plateType?.rawValue ?? "",
                    item.gapOrSpec ?? "",
                    item.bladeType?.rawValue ?? "",
                    item.brushMaterial?.rawValue ?? "",
                    item.badgerTreatment?.rawValue ?? "",
                    item.badgerBand?.rawValue ?? "",
                    item.knotSize ?? "",
                    item.knotShape?.rawValue ?? "",
                    item.notes ?? ""
                ]
                lines.append(row.map(csvEscape).joined(separator: ","))
            }
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }

    private static func csvEscape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }
}
