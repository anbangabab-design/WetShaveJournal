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
}
