import XCTest
@testable import WetShaveJournal

@MainActor
final class GearCatalogAndMutationTests: XCTestCase {

    private func makeTempStore() throws -> (JournalStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_gear_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (JournalStore(dataDirectoryURL: dir, loadUserPreferences: false), dir)
    }

    func testS10AndR03SameNameDifferentSpecProtectedFromMerge() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = store.upsertEntry(JournalEntry(
            id: "local-1",
            date: "2026-04-01",
            fields: [JournalField(label: "剃须刀", value: "Blackland Blackbird Ti")]
        ))
        _ = store.upsertEntry(JournalEntry(
            id: "local-2",
            date: "2026-04-02",
            fields: [JournalField(label: "剃须刀", value: "Blackland Blackbird Brass")]
        ))

        let razors = store.gearItems(for: .razor)
        XCTAssertEqual(razors.count, 2)
        let ti = try XCTUnwrap(razors.first(where: { $0.material == "钛合金" }))
        let brass = try XCTUnwrap(razors.first(where: { $0.material == "黄铜" }))

        // 手动合并也必须经过 GearMergeGuard 阻止材质冲突的误合并
        let mergeResult = store.mergeGearItem(source: ti, into: brass)
        if case .success = mergeResult {
            XCTFail("Expected GearMergeGuard to block merging Titanium into Brass razor")
        }
        XCTAssertEqual(store.gearItems(for: .razor).count, 2)

        // 即使强行把两者改名一致，因材质不同，variantSignature 仍保持分离
        var sameNameTi = GearOverride.from(item: ti)
        sameNameTi.name = "Blackland Blackbird"
        var sameNameBrass = GearOverride.from(item: brass)
        sameNameBrass.name = "Blackland Blackbird"
        _ = store.updateGearItem(rawKeys: ti.rawKeys, category: .razor, newOverride: sameNameTi)
        _ = store.updateGearItem(rawKeys: brass.rawKeys, category: .razor, newOverride: sameNameBrass)
        XCTAssertEqual(store.gearItems(for: .razor).count, 2)
    }

    func testS06DeleteGearFromEntriesAndCompleteUndoWithConcurrentEditProtection() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let e1 = JournalEntry(
            id: "local-e1",
            date: "2026-04-05",
            fields: [
                JournalField(label: "日期", value: "2026-04-05"),
                JournalField(label: "剃须刀", value: "Lambda Athena"),
                JournalField(label: "剃须皂", value: "MDC Rose")
            ]
        )
        let e2 = JournalEntry(
            id: "local-e2",
            date: "2026-04-06",
            fields: [
                JournalField(label: "日期", value: "2026-04-06"),
                JournalField(label: "剃须刀", value: "Lambda Athena"),
                JournalField(label: "剃须皂", value: "MDC Absinthe")
            ]
        )
        _ = store.upsertEntry(e1)
        _ = store.upsertEntry(e2)

        let athena = try XCTUnwrap(store.gearItems(for: .razor).first(where: { $0.name.contains("Athena") }))
        _ = store.markPending(athena.rawKeys, isPending: true)
        XCTAssertEqual(store.referencedEntryCount(for: athena), 2)

        // 删除并从全部日记移除
        _ = store.deleteGearItem(athena, removeFromEntries: true)
        XCTAssertEqual(store.gearItems(for: .razor).count, 0)
        XCTAssertTrue(store.database.pending.isEmpty)
        XCTAssertEqual(store.database.entries.first(where: { $0.id == "local-e1" })?.primaryRazor, "")
        XCTAssertEqual(store.database.entries.first(where: { $0.id == "local-e2" })?.primaryRazor, "")

        // 在撤销之前，用户独立编辑了 e2（新增了备注）
        var editedE2 = try XCTUnwrap(store.database.entries.first(where: { $0.id == "local-e2" }))
        editedE2.fields.append(JournalField(label: "过程", value: "用户后续新编辑"))
        _ = store.upsertEntry(editedE2)

        // 执行完整撤销：e1 恢复原剃须刀字段；e2 因存在后续独立编辑而被保护不静默覆盖
        _ = store.undoLastOverrideChange()
        XCTAssertEqual(store.database.entries.first(where: { $0.id == "local-e1" })?.primaryRazor, "Lambda Athena")
        XCTAssertEqual(store.database.entries.first(where: { $0.id == "local-e2" })?.processText, "用户后续新编辑")
        XCTAssertEqual(store.database.entries.first(where: { $0.id == "local-e2" })?.primaryRazor, "")
        XCTAssertFalse(store.database.pending.isEmpty)
    }

    func testR02CatalogCacheMatchesUncachedAcrossAllMutations() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        func assertCacheMatchesUncached() {
            for cat in GearCategory.allCases {
                let cached = store.gearItems(for: cat)
                let fresh = GearCatalogService.gearItems(for: cat, in: store.database)
                XCTAssertEqual(cached, fresh, "Cache mismatch for category \(cat.rawValue)")
            }
        }

        let rev0 = store.revision
        assertCacheMatchesUncached()

        _ = store.upsertEntry(JournalEntry(
            id: "local-c1",
            date: "2026-04-08",
            fields: [
                JournalField(label: "剃须刀", value: "Wolfman WR1 0.74"),
                JournalField(label: "刀片", value: "Wizamet 1st"),
                JournalField(label: "起泡", value: "铜碗碗起")
            ]
        ))
        XCTAssertGreaterThan(store.revision, rev0)
        assertCacheMatchesUncached()

        let rev1 = store.revision
        _ = store.createQuickGear(category: .soap, name: "Stirling Executive Man", brand: "Stirling")
        XCTAssertGreaterThan(store.revision, rev1)
        assertCacheMatchesUncached()

        let rev2 = store.revision
        _ = store.undoLastOverrideChange()
        XCTAssertGreaterThan(store.revision, rev2)
        assertCacheMatchesUncached()
    }

    func testAuditProposalSkippedWhenItemConcurrentlyEdited() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = store.upsertEntry(JournalEntry(
            id: "local-a1",
            date: "2026-04-09",
            fields: [JournalField(label: "剃须刀", value: "Karve CB")]
        ))
        let original = try XCTUnwrap(store.gearItems(for: .razor).first)
        let staleFingerprint = original.snapshotFingerprint

        // 模拟异步 AI 体检期间用户手动修改并确认了该器材
        var manualOv = GearOverride.from(item: original, isManuallyConfirmed: true)
        manualOv.material = "黄铜"
        _ = store.updateGearItem(rawKeys: original.rawKeys, category: .razor, newOverride: manualOv)

        var proposed = GearOverride.from(item: original)
        proposed.material = "不锈钢"
        let proposal = GearAuditUpdateProposal(
            item: original,
            proposed: proposed,
            changesSummary: ["Material: — → 不锈钢"],
            reason: "AI guess",
            confidence: 0.9,
            selected: true,
            sourceSnapshotFingerprint: staleFingerprint
        )

        _ = store.applyAuditProposals(updates: [proposal], merges: [])
        // 并发修改保护必须跳过该条，保留人工设置的黄铜
        XCTAssertEqual(store.gearItems(for: .razor).first?.material, "黄铜")
    }

    func testBrandLogoWhitelistNormalizationAndNoBlindDomainGuessing() {
        let hwayeonZH = BrandLogoCache.resolveWhitelistedBrand("华研")
        XCTAssertEqual(hwayeonZH?.canonical, "Terry's Soap")
        XCTAssertEqual(hwayeonZH?.domain, "hwayeon.co.kr")

        let hwayeonEN = BrandLogoCache.resolveWhitelistedBrand("Hwayeon")
        XCTAssertEqual(hwayeonEN?.canonical, "Terry's Soap")
        XCTAssertEqual(hwayeonEN?.domain, "hwayeon.co.kr")

        let dsc = BrandLogoCache.resolveWhitelistedBrand("帝诗")
        XCTAssertEqual(dsc?.canonical, "DSCosmetic")
        XCTAssertEqual(dsc?.domain, "dscosmetic.com")

        let hybrid = BrandLogoCache.resolveWhitelistedBrand("Chisel & Hound × Turn-N-Shave")
        XCTAssertEqual(hybrid?.canonical, "Chisel & Hound")
        XCTAssertEqual(hybrid?.domain, "chiselandhound.com")

        let hybridFallback = BrandLogoCache.resolveWhitelistedBrand("不知名手工手柄 × Declaration Grooming")
        XCTAssertEqual(hybridFallback?.canonical, "Declaration Grooming")
        XCTAssertEqual(hybridFallback?.domain, "declarationgrooming.com")

        // 非白名单/仿刀/国内小众品牌严禁盲猜 .com
        XCTAssertNil(BrandLogoCache.resolveWhitelistedBrand("仿刀"))
        XCTAssertNil(BrandLogoCache.resolveWhitelistedBrand("未知手工小众牌"))
        XCTAssertNil(BrandLogoCache.resolveWhitelistedBrand("MyLocalArtisanSoap"))
    }

    func testAutocompleteCanonicalDisplayNameUnifiesWithLegacyAliasWithoutSplitting() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 历史日记记录了旧别名 "Feather DE 1st"
        _ = store.upsertEntry(JournalEntry(
            id: "local-b1",
            date: "2026-04-10",
            fields: [
                JournalField(label: "剃须刀", value: "Blackland Blackbird"),
                JournalField(label: "刀片", value: "Feather DE 1st")
            ]
        ))

        let initialBlade = try XCTUnwrap(store.gearItems(for: .blade).first)
        var updatedOv = GearOverride.from(item: initialBlade)
        updatedOv.brand = "Feather"
        updatedOv.name = "Feather DE"
        updatedOv.model = "New Hi-Stainless"
        updatedOv.bladeType = .de
        _ = store.updateGearItem(rawKeys: initialBlade.rawKeys, category: .blade, newOverride: updatedOv)

        let bladesAfterEdit = store.gearItems(for: .blade)
        XCTAssertEqual(bladesAfterEdit.count, 1)
        let bladeItem = try XCTUnwrap(bladesAfterEdit.first)

        // 联想点选必须插入规范显示名 "Feather New Hi-Stainless"，而非旧别名 "Feather DE"
        let inserted = GearCatalogService.autocompleteInsertText(for: bladeItem, in: bladesAfterEdit)
        XCTAssertEqual(inserted, "Feather New Hi-Stainless")

        // 随后新日记写入规范显示名，器材库与统计必须仍映射为同一件器材（count == 2，绝不裂出重复条目）
        _ = store.upsertEntry(JournalEntry(
            id: "local-b2",
            date: "2026-04-11",
            fields: [
                JournalField(label: "剃须刀", value: "Blackland Blackbird"),
                JournalField(label: "刀片", value: "\(inserted) 2nd")
            ]
        ))

        let unifiedBlades = store.gearItems(for: .blade)
        XCTAssertEqual(unifiedBlades.count, 1)
        XCTAssertEqual(unifiedBlades.first?.count, 2)

        // 刀片下次使用次数建议应兼容规范名并连续计数
        XCTAssertEqual(store.suggestedNextUseCount(forBlade: inserted), 3)

        // 统计快照同样将旧别名与规范名合并为 1 组刀片组合与 1 款刀片寿命统计（累计 2 次）
        let stats = StatisticsEngine.buildSnapshot(database: store.database, revision: store.revision, isEnglish: false)
        XCTAssertEqual(stats.comboStats.count, 1)
        XCTAssertEqual(stats.comboStats.first?.uses, 2)
        XCTAssertEqual(stats.bladeLongevityStats.count, 1)
        XCTAssertEqual(stats.bladeLongevityStats.first?.totalShaves, 2)
    }

    func testAIHealthCheckSessionPersistenceRoundTripAndAutoClear() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_ai_session_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = JournalRepository(dataDirectoryURL: dir)
        XCTAssertNil(repo.loadAIHealthCheckSession())

        let sampleItem = GearItem(
            id: "剃须刀|karvecb",
            category: .razor,
            canonicalKey: "剃须刀|karvecb",
            brand: "Karve",
            name: "Karve CB",
            model: "Christopher Bradley",
            count: 5,
            lastUsedDate: "2026-04-10",
            rawKeys: ["剃须刀|karvecb"],
            isPending: false,
            razorType: .de,
            isAdjustable: false,
            isSlant: false,
            material: nil,
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
            isManuallyConfirmed: false
        )
        let proposal = GearAuditUpdateProposal(
            item: sampleItem,
            proposed: GearOverride(brand: "Karve", name: "Karve CB", model: "Christopher Bradley", material: "黄铜"),
            changesSummary: ["材质: — → 黄铜"],
            reason: "Verified spec",
            confidence: 0.95,
            selected: true,
            sourceSnapshotFingerprint: sampleItem.snapshotFingerprint
        )
        let failure = GearAuditBatchFailure(
            batchIndex: 2,
            items: [sampleItem],
            reason: "HTTP 429 rate limited"
        )
        let session = AIHealthCheckSession(
            savedAt: "2026-04-10T12:00:00Z",
            scopeRawValue: "all",
            category: nil,
            modelUsed: "deepseek-flash",
            plannedCount: 12,
            verifiedCount: 10,
            skippedCount: 1,
            unknownOrDuplicateIDCount: 0,
            retryRound: 1,
            updates: [proposal],
            merges: [],
            undeterminedItems: [],
            failedItems: [sampleItem],
            batchFailures: [failure]
        )

        repo.saveAIHealthCheckSession(session)
        let loaded = try XCTUnwrap(repo.loadAIHealthCheckSession())
        XCTAssertEqual(loaded.plannedCount, 12)
        XCTAssertEqual(loaded.verifiedCount, 10)
        XCTAssertEqual(loaded.updates.count, 1)
        XCTAssertEqual(loaded.updates.first?.item.id, "剃须刀|karvecb")
        XCTAssertEqual(loaded.failedItems.count, 1)
        XCTAssertEqual(loaded.batchFailures.count, 1)
        XCTAssertEqual(loaded.batchFailures.first?.reason, "HTTP 429 rate limited")

        // 保存空待处理会话时自动清理持久化文件
        let emptySession = AIHealthCheckSession(
            savedAt: "2026-04-10T12:05:00Z",
            scopeRawValue: "all",
            category: nil,
            modelUsed: "deepseek-flash",
            plannedCount: 12,
            verifiedCount: 12,
            skippedCount: 0,
            unknownOrDuplicateIDCount: 0,
            retryRound: 1,
            updates: [],
            merges: [],
            undeterminedItems: [],
            failedItems: [],
            batchFailures: []
        )
        repo.saveAIHealthCheckSession(emptySession)
        XCTAssertNil(repo.loadAIHealthCheckSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.aiHealthCheckSessionFileURL.path))
    }
}
