import Foundation

enum GearMutationError: LocalizedError, Equatable {
    case mergeConflict(String)

    var errorDescription: String? {
        switch self {
        case .mergeConflict(let reason):
            return L10n.t(
                "已阻止合并：\(reason)",
                "Merge blocked: \(reason)"
            )
        }
    }
}

struct GearMutationPlan {
    var database: JournalDatabase
    var shouldBackup: Bool
    var toastMessage: String
    var didMutate: Bool
}

/// 纯函数器材变更规划器（R03 / S06 / S10）：
/// 统一所有合并、拆分、更新、删除与完整撤销的候选数据库变换，不直接执行磁盘写入，完全可独立单元测试
enum GearMutationService {
    private static let maxHistoryDepth = 30

    static func pushHistory(
        into candidate: inout JournalDatabase,
        overrides: [String: GearOverride]? = nil,
        pending: [String]? = nil,
        entrySnapshots: [GearEntryFieldSnapshot]? = nil
    ) {
        candidate.history.append(
            GearHistorySnapshot(
                overrides: overrides ?? candidate.overrides,
                pending: pending ?? candidate.pending,
                entrySnapshots: entrySnapshots
            )
        )
        if candidate.history.count > maxHistoryDepth {
            candidate.history.removeFirst()
        }
    }

    static func planUpdateGearItem(
        rawKeys: [String],
        category: GearCategory,
        newOverride: GearOverride,
        clearPending: Bool = true,
        in db: JournalDatabase
    ) -> GearMutationPlan {
        var candidate = db
        pushHistory(into: &candidate)
        var normalizedOverride = GearSanitizer.sanitizeOverride(newOverride, category: category)
        normalizedOverride.updatedAt = SyncTimestamp.nowISO8601()
        let newNormKey = "\(category.rawValue)|\(GearKnowledgeBase.normalizeKey(normalizedOverride.name))"
        let targetKeys = rawKeys.isEmpty ? [newNormKey] : rawKeys
        for key in targetKeys {
            candidate.overrides[key] = normalizedOverride
            if clearPending {
                candidate.pending.removeAll { $0 == key }
            } else if !candidate.pending.contains(key) {
                candidate.pending.append(key)
            }
        }
        candidate.overrides[newNormKey] = normalizedOverride
        if clearPending {
            candidate.pending.removeAll { $0 == newNormKey }
        } else if rawKeys.isEmpty && !candidate.pending.contains(newNormKey) {
            candidate.pending.append(newNormKey)
        }

        return GearMutationPlan(
            database: candidate,
            shouldBackup: false,
            toastMessage: L10n.t("已保存器材修改", "Saved gear changes"),
            didMutate: true
        )
    }

    /// 手动合并与 AI 合并共用底层安全规则（R03 / S10）：
    /// - 强制走 GearMergeGuard 校验材质/底板/刀隙/Slant/结径/毛型/刷毛/手柄/小样冲突
    /// - 统一经 GearOverride.from(item:) 构造目标规则，避免多处 20 字段拷贝漂移
    static func planMergeGearItem(
        source: GearItem,
        into target: GearItem,
        in db: JournalDatabase
    ) -> Result<GearMutationPlan, GearMutationError> {
        guard source.id != target.id, source.category == target.category else {
            return .success(GearMutationPlan(database: db, shouldBackup: false, toastMessage: "", didMutate: false))
        }

        if let conflict = GearMergeGuard.conflictReason(source: source, target: target) {
            return .failure(.mergeConflict(conflict))
        }

        var candidate = db
        pushHistory(into: &candidate)

        applyMergeMapping(source: source, into: target, candidate: &candidate)

        return .success(GearMutationPlan(
            database: candidate,
            shouldBackup: true,
            toastMessage: L10n.t("已合并「\(source.name)」至「\(target.name)」", "Merged \"\(source.name)\" into \"\(target.name)\""),
            didMutate: true
        ))
    }

    private static func applyMergeMapping(
        source: GearItem,
        into target: GearItem,
        candidate: inout JournalDatabase
    ) {
        var targetOverride = GearSanitizer.sanitizeOverride(
            GearOverride.from(item: target),
            category: target.category
        )
        targetOverride.updatedAt = SyncTimestamp.nowISO8601()
        for key in source.rawKeys {
            candidate.overrides[key] = targetOverride
            candidate.pending.removeAll { $0 == key }
        }
        let sourceNormKey = "\(source.category.rawValue)|\(GearKnowledgeBase.normalizeKey(source.name))"
        candidate.overrides[sourceNormKey] = targetOverride
        candidate.pending.removeAll { $0 == sourceNormKey }
    }

    static func planSplitRawKey(
        _ rawKey: String,
        from item: GearItem,
        in db: JournalDatabase
    ) -> GearMutationPlan {
        var candidate = db
        pushHistory(into: &candidate)
        let sample = GearCatalogService.rawEntrySamples(forRawKey: rawKey, category: item.category, in: db)
        let splitName = sample.display.isEmpty ? rawKey : sample.display
        var inferred = GearKnowledgeBase.inferDefaultOverride(rawName: splitName, category: item.category)
        if inferred.brand == "品牌未注明" && item.brand != "品牌未注明" {
            inferred.brand = item.brand
        }
        inferred.name = splitName
        if inferred.name.lowercased() == item.name.lowercased() {
            inferred.name = "\(splitName) (Split)"
        }
        inferred.updatedAt = SyncTimestamp.nowISO8601()
        candidate.overrides[rawKey] = inferred
        if !candidate.pending.contains(rawKey) {
            candidate.pending.append(rawKey)
        }

        return GearMutationPlan(
            database: candidate,
            shouldBackup: true,
            toastMessage: L10n.t("已将「\(splitName)」拆分为独立器材", "Split \"\(splitName)\" into a new item"),
            didMutate: true
        )
    }

    static func planCreateQuickGear(
        category: GearCategory,
        name: String,
        brand: String? = nil,
        in db: JournalDatabase
    ) -> (plan: GearMutationPlan, created: GearOverride) {
        var ov = GearKnowledgeBase.inferDefaultOverride(rawName: name, category: category)
        if let b = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            ov.brand = b
        }
        ov.updatedAt = SyncTimestamp.nowISO8601()
        var candidate = db
        pushHistory(into: &candidate)
        let key = "\(category.rawValue)|\(GearKnowledgeBase.normalizeKey(ov.name))"
        candidate.overrides[key] = ov
        if ov.brand == "品牌未注明", !candidate.pending.contains(key) {
            candidate.pending.append(key)
        }
        let plan = GearMutationPlan(database: candidate, shouldBackup: false, toastMessage: "", didMutate: true)
        return (plan, ov)
    }

    static func planMarkPending(
        _ rawKeys: [String],
        isPending: Bool,
        in db: JournalDatabase
    ) -> GearMutationPlan {
        var candidate = db
        pushHistory(into: &candidate)
        for key in rawKeys {
            if isPending {
                if !candidate.pending.contains(key) { candidate.pending.append(key) }
            } else {
                candidate.pending.removeAll { $0 == key }
            }
        }
        return GearMutationPlan(database: candidate, shouldBackup: false, toastMessage: "", didMutate: true)
    }

    /// 删除器材并可选移除日记引用（S06）：
    /// 当 removeFromEntries == true 时，精确记录每条受影响日记的原始字段与删除后指纹，确保撤销可完整恢复
    static func planDeleteGearItem(
        _ item: GearItem,
        removeFromEntries: Bool,
        in db: JournalDatabase
    ) -> GearMutationPlan {
        var candidate = db
        let priorOverrides = candidate.overrides
        let priorPending = candidate.pending

        let keys = GearCatalogService.removalKeys(for: item)
        let referencedCount = GearCatalogService.referencedEntryCount(for: item, in: db)

        for key in keys {
            candidate.overrides.removeValue(forKey: key)
        }
        candidate.pending.removeAll { keys.contains($0) }

        var affectedEntryCount = 0
        var capturedEntrySnapshots: [GearEntryFieldSnapshot] = []

        if removeFromEntries {
            let prefixes = GearCatalogService.fieldLabelPrefixes(for: item.category)
            for idx in candidate.entries.indices {
                let originalEntry = candidate.entries[idx]
                var modified = false
                var newFields: [JournalField] = []
                newFields.reserveCapacity(originalEntry.fields.count)

                for var field in originalEntry.fields {
                    if GearCatalogService.labelMatchesCategory(field.label, prefixes: prefixes) {
                        if let key = GearCatalogService.normalizedKeyForFieldValue(field.value, category: item.category),
                           keys.contains(key) {
                            modified = true
                            continue
                        }
                    } else if item.category == .bowl, field.label == "起泡" {
                        let trimmed = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let bowlName = GearKnowledgeBase.extractBowlName(from: trimmed) {
                            let key = "\(GearCategory.bowl.rawValue)|\(GearKnowledgeBase.normalizeKey(bowlName))"
                            if keys.contains(key) {
                                modified = true
                                if trimmed.hasSuffix("碗起") {
                                    field.value = "碗起"
                                    newFields.append(field)
                                }
                                continue
                            }
                        }
                    }
                    newFields.append(field)
                }

                if modified {
                    candidate.entries[idx].fields = newFields
                    candidate.entries[idx].locallyModified = true
                    candidate.entries[idx].updatedAt = SyncTimestamp.nowISO8601()
                    let postFingerprint = candidate.entries[idx].contentFingerprint
                    capturedEntrySnapshots.append(
                        GearEntryFieldSnapshot(
                            entryID: originalEntry.id,
                            previousFields: originalEntry.fields,
                            previousLocallyModified: originalEntry.locallyModified,
                            postMutationFingerprint: postFingerprint
                        )
                    )
                    affectedEntryCount += 1
                }
            }
        }

        pushHistory(
            into: &candidate,
            overrides: priorOverrides,
            pending: priorPending,
            entrySnapshots: capturedEntrySnapshots.isEmpty ? nil : capturedEntrySnapshots
        )

        let toast: String
        if removeFromEntries && affectedEntryCount > 0 {
            toast = L10n.t(
                "已彻底删除「\(item.name)」，并从 \(affectedEntryCount) 篇日记移除",
                "Deleted \"\(item.name)\" and removed it from \(affectedEntryCount) entries"
            )
        } else if referencedCount == 0 {
            toast = L10n.t("已删除「\(item.name)」", "Deleted \"\(item.name)\"")
        } else {
            toast = L10n.t("已移除「\(item.name)」的器材档案规则", "Removed profile rules for \"\(item.name)\"")
        }

        return GearMutationPlan(
            database: candidate,
            shouldBackup: removeFromEntries,
            toastMessage: toast,
            didMutate: true
        )
    }

    /// 完整撤销上一次器材修改（S06）：
    /// 同时恢复 overrides、pending 与删除时捕获的受影响日记字段；若期间用户独立编辑过某日记则保留新编辑并明确提示
    static func planUndoLastOverrideChange(in db: JournalDatabase) -> GearMutationPlan {
        var candidate = db
        guard let snapshot = candidate.history.popLast() else {
            return GearMutationPlan(
                database: db,
                shouldBackup: false,
                toastMessage: L10n.t("当前没有可撤销的器材修改记录", "No gear changes to undo"),
                didMutate: false
            )
        }

        let nowISO = SyncTimestamp.nowISO8601()
        var stampedOverrides = snapshot.overrides
        for key in stampedOverrides.keys {
            if stampedOverrides[key]?.fingerprint != candidate.overrides[key]?.fingerprint || candidate.overrides[key] == nil {
                stampedOverrides[key]?.updatedAt = nowISO
            }
        }
        candidate.overrides = stampedOverrides
        if let savedPending = snapshot.pending {
            candidate.pending = savedPending
        }

        var restoredEntries = 0
        var skippedEditedEntries = 0

        if let entrySnaps = snapshot.entrySnapshots, !entrySnaps.isEmpty {
            var indexByID: [String: Int] = Dictionary(
                candidate.entries.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            for snap in entrySnaps {
                guard let idx = indexByID[snap.entryID] else {
                    skippedEditedEntries += 1
                    continue
                }
                if candidate.entries[idx].contentFingerprint == snap.postMutationFingerprint {
                    candidate.entries[idx].fields = snap.previousFields
                    candidate.entries[idx].locallyModified = snap.previousLocallyModified
                    candidate.entries[idx].updatedAt = nowISO
                    restoredEntries += 1
                } else {
                    // 该日记在器材删除后又被用户独立编辑过，保留新编辑避免静默回滚
                    skippedEditedEntries += 1
                }
            }
            indexByID.removeAll()
        }

        let toast: String
        if restoredEntries > 0 && skippedEditedEntries > 0 {
            toast = L10n.t(
                "已撤销器材修改：恢复 \(restoredEntries) 篇日记引用，跳过 \(skippedEditedEntries) 篇后续已编辑日记（如需还原请从备份目录恢复）",
                "Undid gear change: restored \(restoredEntries) entry references, skipped \(skippedEditedEntries) subsequently edited entries"
            )
        } else if restoredEntries > 0 {
            toast = L10n.t(
                "已撤销器材修改，并完整恢复 \(restoredEntries) 篇日记引用",
                "Undid gear change and restored \(restoredEntries) entry references"
            )
        } else if skippedEditedEntries > 0 {
            toast = L10n.t(
                "已恢复器材档案，但 \(skippedEditedEntries) 篇关联日记已变动未能直接回滚（可从 Backups 目录恢复）",
                "Restored gear profile; \(skippedEditedEntries) linked entries changed since deletion and were kept intact"
            )
        } else {
            toast = L10n.t("已撤销上次器材修改", "Undid last gear change")
        }

        return GearMutationPlan(
            database: candidate,
            shouldBackup: restoredEntries > 0,
            toastMessage: toast,
            didMutate: true
        )
    }

    /// 批量应用 AI 体检建议（R02/R03/S08/S10）：
    /// 校验全过程基于候选数据库即时聚合，绝不读取旧缓存；强制核对快照指纹、人工确认和规格冲突
    static func planApplyAuditProposals(
        updates: [GearAuditUpdateProposal],
        merges: [GearAuditMergeProposal],
        in db: JournalDatabase
    ) -> GearMutationPlan {
        let chosenUpdates = updates.filter(\.selected)
        let chosenMerges = merges.filter(\.selected)
        guard !chosenUpdates.isEmpty || !chosenMerges.isEmpty else {
            return GearMutationPlan(database: db, shouldBackup: false, toastMessage: "", didMutate: false)
        }

        var candidate = db
        pushHistory(into: &candidate)

        let updateCategories = Set(chosenUpdates.map { $0.item.category })
        var liveBeforeUpdates: [GearCategory: [GearItem]] = [:]
        for cat in updateCategories {
            liveBeforeUpdates[cat] = GearCatalogService.gearItems(for: cat, in: candidate)
        }

        var appliedUpdates = 0
        var skippedStaleUpdates = 0
        var updatedRawKeySets: Set<String> = []

        for u in chosenUpdates {
            let liveList = liveBeforeUpdates[u.item.category] ?? []
            guard let liveItem = liveList.first(where: { $0.id == u.item.id }) else {
                skippedStaleUpdates += 1
                continue
            }
            if !u.sourceSnapshotFingerprint.isEmpty && liveItem.snapshotFingerprint != u.sourceSnapshotFingerprint {
                skippedStaleUpdates += 1
                continue
            }

            var ov = GearSanitizer.sanitizeOverride(u.proposed, category: u.item.category)
            ov.updatedAt = SyncTimestamp.nowISO8601()
            let targetKeys = liveItem.rawKeys.isEmpty ? [liveItem.canonicalKey] : liveItem.rawKeys
            for key in targetKeys {
                candidate.overrides[key] = ov
                updatedRawKeySets.insert(key)
                if u.confidence >= 0.72 { candidate.pending.removeAll { $0 == key } }
            }
            let newNormKey = "\(u.item.category.rawValue)|\(GearKnowledgeBase.normalizeKey(ov.name))"
            candidate.overrides[newNormKey] = ov
            updatedRawKeySets.insert(newNormKey)
            if u.confidence >= 0.72 { candidate.pending.removeAll { $0 == newNormKey } }
            appliedUpdates += 1
        }

        let mergeCategories = Set(chosenMerges.map { $0.source.category })
        var appliedMerges = 0
        var skippedMerges = 0
        var mergedAwayRawKeys: Set<String> = []

        func findLiveItem(matching oldItem: GearItem, in list: [GearItem]) -> GearItem? {
            if let exact = list.first(where: { $0.id == oldItem.id }) {
                return exact
            }
            let oldKeySet = Set(oldItem.rawKeys)
            return list.first(where: { !oldKeySet.isDisjoint(with: $0.rawKeys) })
        }

        if !chosenMerges.isEmpty {
            var latestByCategory: [GearCategory: [GearItem]] = [:]
            for cat in mergeCategories {
                latestByCategory[cat] = GearCatalogService.gearItems(for: cat, in: candidate)
            }

            for m in chosenMerges {
                let latestList = latestByCategory[m.source.category] ?? []
                guard let latestSource = findLiveItem(matching: m.source, in: latestList),
                      let latestTarget = findLiveItem(matching: m.target, in: latestList),
                      latestSource.id != latestTarget.id else {
                    skippedMerges += 1
                    continue
                }

                let srcKeys = Set(latestSource.rawKeys)
                let dstKeys = Set(latestTarget.rawKeys)
                if !srcKeys.isDisjoint(with: mergedAwayRawKeys) || !dstKeys.isDisjoint(with: mergedAwayRawKeys) {
                    skippedMerges += 1
                    continue
                }

                let srcUpdatedInPhase1 = !srcKeys.isDisjoint(with: updatedRawKeySets)
                let dstUpdatedInPhase1 = !dstKeys.isDisjoint(with: updatedRawKeySets)
                if !srcUpdatedInPhase1, !m.sourceSnapshotFingerprint.isEmpty,
                   latestSource.snapshotFingerprint != m.sourceSnapshotFingerprint {
                    skippedMerges += 1
                    continue
                }
                if !dstUpdatedInPhase1, !m.targetSnapshotFingerprint.isEmpty,
                   latestTarget.snapshotFingerprint != m.targetSnapshotFingerprint {
                    skippedMerges += 1
                    continue
                }

                if GearMergeGuard.conflictReason(source: latestSource, target: latestTarget) != nil {
                    skippedMerges += 1
                    continue
                }

                applyMergeMapping(source: latestSource, into: latestTarget, candidate: &candidate)
                mergedAwayRawKeys.formUnion(latestSource.rawKeys)
                mergedAwayRawKeys.insert("\(latestSource.category.rawValue)|\(GearKnowledgeBase.normalizeKey(latestSource.name))")
                appliedMerges += 1

                latestByCategory[m.source.category] = GearCatalogService.gearItems(for: m.source.category, in: candidate)
            }
        }

        let totalSkipped = skippedStaleUpdates + skippedMerges
        guard appliedUpdates > 0 || appliedMerges > 0 else {
            return GearMutationPlan(
                database: db,
                shouldBackup: false,
                toastMessage: L10n.t(
                    "未应用任何变更：已跳过 \(totalSkipped) 项（期间已被手动修改、目标过期或存在规格冲突）",
                    "No changes applied: skipped \(totalSkipped) item(s) due to concurrent edits, stale targets, or spec conflicts."
                ),
                didMutate: false
            )
        }

        let toast: String
        if totalSkipped > 0 {
            toast = L10n.t(
                "已应用 AI 体检：更新 \(appliedUpdates) 项，合并 \(appliedMerges) 组，跳过 \(totalSkipped) 项（已修改或存在冲突）",
                "Applied AI audit: \(appliedUpdates) updated, \(appliedMerges) merged, \(totalSkipped) skipped"
            )
        } else {
            toast = L10n.t(
                "已应用 AI 体检：更新 \(appliedUpdates) 项，合并 \(appliedMerges) 组",
                "Applied AI audit: \(appliedUpdates) updated, \(appliedMerges) merged"
            )
        }

        return GearMutationPlan(
            database: candidate,
            shouldBackup: true,
            toastMessage: toast,
            didMutate: true
        )
    }
}
