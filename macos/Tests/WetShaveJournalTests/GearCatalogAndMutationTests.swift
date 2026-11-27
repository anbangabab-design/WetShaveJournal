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
        XCTAssertEqual(dsc?.domain, "http://dscosmetic.com")

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

        // v1.4.2 全部 50+ 实测正确品牌、全部刀片与增量补齐品牌 100% 命中准确域名映射
        let mustResolveBrands: [(String, String)] = [
            ("Martin de Candre", "martin-de-candre.com"),
            ("MdC", "martin-de-candre.com"),
            ("Ethos Grooming", "ethosgroomingessentials.com"),
            ("Ethos Grooming Essentials", "ethosgroomingessentials.com"),
            ("Saponificio Varesino", "saponificiovaresino.com"),
            ("SV", "saponificiovaresino.com"),
            ("MacDuffs Soap Company", "macduffssoapcompany.com"),
            ("MacDuff's Soap Company", "macduffssoapcompany.com"),
            ("PantaRei", "pantareibrushes.it"),
            ("Elysian Soap Shop", "elysiansoapshop.com"),
            ("RazoRock", "italianbarber.com"),
            ("RR", "italianbarber.com"),
            ("HAGS", "hagsartisan.com"),
            ("HLS", "homelikeshaving.ru"),
            ("HomeLikeShaving", "homelikeshaving.ru"),
            ("Cella", "cellamilano.it"),
            ("Fine Accoutrements", "fineaccoutrements.com"),
            ("Gentleman's Nod", "gentlemansnod.com"),
            ("NOD", "gentlemansnod.com"),
            ("Le Père Lucien", "leperelucien.com"),
            ("LPL", "leperelucien.com"),
            ("Noble Otter", "nobleotter.com"),
            ("Nomad Theory", "nomadtheory.co.uk"),
            ("The Razor Company", "therazorcompany.com"),
            ("TRC", "therazorcompany.com"),
            ("Zingari Man", "zingariman.com"),
            ("ZM", "zingariman.com"),
            ("Frank Shaving", "frankshaving.com"),
            ("FS", "frankshaving.com"),
            ("Shavemac", "shavemac.com"),
            ("Oumo", "oumoshavingbrush.com"),
            ("Boti", "botibrush.com"),
            ("Longshaving", "longshaving.com"),
            ("Wald", "waldshaving.com"),
            ("Simpson", "simpsonshavingbrushes.com"),
            ("Maggard Razors", "maggardrazors.com"),
            ("Omega", "omegabrush.com"),
            ("Tatara", "tatararazors.com"),
            ("Blutt", "bluttrasur.ch"),
            ("Gillette", "gillette.com"),
            ("Blackland", "blacklandrazors.com"),
            ("Above The Tie", "abovethetie.com"),
            ("ATT", "abovethetie.com"),
            ("Atelier Durdan", "atelierdurdan.com"),
            ("AD", "atelierdurdan.com"),
            ("Rex Supply Co.", "rexsupplyco.com"),
            ("Colonial", "colonialrazors.com"),
            ("Alpha", "alphashaving.com"),
            ("Maxwell June", "maxwelljune.com"),
            ("MJ", "maxwelljune.com"),
            ("Mühle", "muehle-shaving.com"),
            ("Nord Razors", "nordrazors.com"),
            ("Proraso", "proraso.com"),
            ("Thayers", "thayers.com"),
            ("Old Spice", "oldspice.com"),
            ("Clubman Pinaud", "clubman.com"),
            ("CeraVe", "cerave.com"),
            ("Arno", "arnoshavingbrush.com"),
            ("Amonatura", "amonaturastore.com"),
            ("AKA", "akabrushworx.com"),
            ("LAXO", "aura-craft.com/laxo/"),
            // 全部刀片（Astra 与 Wizamet 指向独立内置 PNG，不再共享 gillette.com）
            ("Personna", "personna.com"),
            ("Feather", "feather.co.jp"),
            ("Kai", "kai-group.com"),
            ("Schick", "schick.com"),
            ("Dorco", "dorcousa.com"),
            // 增量补齐
            ("Wolfman", "wolfmanrazors.com"),
            ("Karve", "karveshaving.com"),
            ("Stirling", "stirlingsoap.com"),
            ("DG", "declarationgrooming.com"),
            ("House of Mammoth", "houseofmammoth.com"),
            ("PAA", "phoenixartisanaccoutrements.com"),
            ("Moon Soaps", "moonsoaps.com"),
            ("A&E", "aegrooming.com"),
            ("C&H", "chiselandhound.com"),
            ("Paladin", "paladinshaving.com"),
            ("TNS", "turnnshave.com"),
            ("Brad Sears", "bradsearsshaveworks.com"),
            ("Yaqi", "yaqibrush.com"),
            ("Aylsworth", "aylsworthrazors.com"),
            ("Rocnel", "rocnel.com"),
            ("Lambda", "lambda-razors.com"),
            ("WestMan", "westmanshaving.com"),
            ("Semogue", "portuguesefactory.com"),
            ("The CaYuen Workshop", "cayuenworkshop.com")
        ]
        for (input, expectedDomain) in mustResolveBrands {
            let hit = BrandLogoCache.resolveWhitelistedBrand(input)
            XCTAssertEqual(hit?.domain, expectedDomain, "Expected \(input) -> \(expectedDomain)")
        }

        // 反 Etsy/平台黑名单保持拦截，同时放行品牌官网静态图 CDN (cdn.shopify.com)
        XCTAssertTrue(BrandLogoCache.isBlacklistedHost("www.etsy.com"))
        XCTAssertTrue(BrandLogoCache.isBlacklistedHost("i.etsystatic.com"))
        XCTAssertTrue(BrandLogoCache.isBlacklistedHost("shopify.com"))
        XCTAssertFalse(BrandLogoCache.isBlacklistedHost("cdn.shopify.com"))
    }

    func testBrandLogoPriorityOrderCustomOverBundledOverCacheAndClearKeepsBundled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_logo_prio_\(UUID().uuidString)", isDirectory: true)
        let bundled = root.appendingPathComponent("BundledLogos", isDirectory: true)
        let customDir = root.appendingPathComponent("CustomLogos", isDirectory: true)
        let cacheDir = root.appendingPathComponent("LogoCache", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeSolidPNG(size: Int, color: NSColor) -> Data {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: size,
                pixelsHigh: size,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill()
            NSRect(x: 0, y: 0, width: size, height: size).fill()
            NSGraphicsContext.restoreGraphicsState()
            return rep.representation(using: .png, properties: [:])!
        }

        // 写入不同尺寸的图片区分来源：Custom(48) > Bundled(独立尺寸) > LogoCache(24)
        try makeSolidPNG(size: 48, color: .systemRed).write(to: customDir.appendingPathComponent("blackland.png"))
        try makeSolidPNG(size: 36, color: .systemGreen).write(to: bundled.appendingPathComponent("blackland.png"))
        try makeSolidPNG(size: 36, color: .systemGreen).write(to: bundled.appendingPathComponent("gillette.png"))
        try makeSolidPNG(size: 36, color: .systemGreen).write(to: bundled.appendingPathComponent("le_pere_lucien.png"))
        try makeSolidPNG(size: 32, color: .systemBlue).write(to: bundled.appendingPathComponent("astra.png"))
        try makeSolidPNG(size: 34, color: .systemIndigo).write(to: bundled.appendingPathComponent("wizamet.png"))
        try makeSolidPNG(size: 38, color: .systemOrange).write(to: bundled.appendingPathComponent("dg.png"))
        try makeSolidPNG(size: 40, color: .systemTeal).write(to: bundled.appendingPathComponent("ethos.png"))
        try makeSolidPNG(size: 42, color: .systemPurple).write(to: bundled.appendingPathComponent("tns.png"))
        try makeSolidPNG(size: 44, color: .systemPink).write(to: bundled.appendingPathComponent("twoface.png"))
        try makeSolidPNG(size: 24, color: .systemBlue).write(to: cacheDir.appendingPathComponent("blackland.png"))
        try makeSolidPNG(size: 24, color: .systemBlue).write(to: cacheDir.appendingPathComponent("wolfman.png"))

        let logoCache = BrandLogoCache(appSupportRoot: root, bundledLogosDirectory: bundled)

        // 1. CustomLogos/ 优先于 BrandLogos/ 与 LogoCache/
        let blacklandImg = try XCTUnwrap(logoCache.logoImage(for: "Blackland"))
        XCTAssertEqual(blacklandImg.representations.first?.pixelsWide, 48)

        // 2. BrandLogos/ 支持重音品牌、简称别名及独立刀片（Astra/Wizamet 各自指向独立 PNG，绝不回落 gillette.png）
        let lplImg = try XCTUnwrap(logoCache.logoImage(for: "Le Père Lucien"))
        XCTAssertEqual(lplImg.representations.first?.pixelsWide, 36)
        XCTAssertEqual(logoCache.logoImage(for: "Astra")?.representations.first?.pixelsWide, 32)
        XCTAssertEqual(logoCache.logoImage(for: "Wizamet")?.representations.first?.pixelsWide, 34)
        XCTAssertEqual(logoCache.logoImage(for: "Declaration Grooming")?.representations.first?.pixelsWide, 38)
        XCTAssertEqual(logoCache.logoImage(for: "Ethos Grooming Essentials")?.representations.first?.pixelsWide, 40)
        XCTAssertEqual(logoCache.logoImage(for: "Turn-N-Shave")?.representations.first?.pixelsWide, 42)
        XCTAssertEqual(logoCache.logoImage(for: "TwoFace Brothers")?.representations.first?.pixelsWide, 44)

        // 3. LogoCache/ 作为第 3 级兜底
        let wolfmanImg = try XCTUnwrap(logoCache.logoImage(for: "Wolfman"))
        XCTAssertEqual(wolfmanImg.representations.first?.pixelsWide, 24)

        // 4. 清理自动缓存后：LogoCache 被清空，CustomLogos 与内置 BrandLogos 完整保留
        logoCache.clearAutoCacheAndRefetch()
        XCTAssertEqual(logoCache.logoImage(for: "Blackland")?.representations.first?.pixelsWide, 48)
        XCTAssertEqual(logoCache.logoImage(for: "Le Père Lucien")?.representations.first?.pixelsWide, 36)
        XCTAssertNil(logoCache.logoImage(for: "Wolfman"))
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
