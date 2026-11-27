import Foundation
import SwiftUI

/// 应用主状态协调器（R01）：
/// - 负责 SwiftUI 可观察状态、统一事务提交、版本号驱动缓存失效（R02 / R04）
/// - 持久化、备忘录同步、器材聚合、器材变更规划与统计计算已全部下沉至可独立测试的服务模块
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var database: JournalDatabase = JournalDatabase()
    private(set) var revision: UInt64 = 1

    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            guard persistPreferences else { return }
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "WetShaveJournal.AppearanceMode")
        }
    }

    @Published var language: AppLanguage = .system {
        didSet {
            L10n.currentLanguage = language
            cachedStatisticsSnapshot = nil
            guard persistPreferences else { return }
            UserDefaults.standard.set(language.rawValue, forKey: "WetShaveJournal.Language")
        }
    }

    private var isBootstrappingAIConfig: Bool = false
    private let persistPreferences: Bool

    @Published var aiConfig: AIConfig = AIConfig() {
        didSet {
            guard !isBootstrappingAIConfig, persistPreferences else { return }
            aiConfig.saveNonSensitiveToUserDefaults()
            if aiConfig.apiKey != oldValue.apiKey {
                do {
                    try aiConfig.saveAPIKeyToLocalStore()
                    keychainWarningMessage = nil
                } catch {
                    keychainWarningMessage = error.localizedDescription
                    showToast(error.localizedDescription, isLoading: false)
                }
            }
        }
    }

    @Published var keychainWarningMessage: String? = nil
    /// 解码失败只读保护
    @Published var isReadOnlyProtected: Bool = false
    @Published var loadErrorMessage: String? = nil

    @Published var isSyncing: Bool = false
    @Published var isRecognizingBatch: Bool = false
    @Published var toast: ToastState? = nil

    // 云盘双端同步状态（默认关闭，用户选择同步目录后自动启用）
    private static let cloudSyncDirDefaultsKey = "WetShaveJournal.CloudSyncDirectoryPath"
    private static let lastCloudSyncAtDefaultsKey = "WetShaveJournal.LastCloudSyncAt"

    @Published var cloudSyncDirectoryPath: String = ""
    @Published var isCloudSyncing: Bool = false
    @Published var lastCloudSyncAt: String? = nil
    @Published var lastCloudSyncResult: CloudSyncResult? = nil

    private var hasPerformedStartupCloudSync: Bool = false
    private var pendingFollowUpCloudSync: Bool = false
    private var cloudSyncDebounceTask: Task<Void, Never>? = nil
    private var customLogoObserver: NSObjectProtocol? = nil

    private var toastDismissTask: Task<Void, Never>? = nil
    private var cachedCatalogSnapshot: GearCatalogSnapshot? = nil
    private var cachedStatisticsSnapshot: StatisticsSnapshot? = nil

    let repository: JournalRepository
    var dataDirectoryURL: URL { repository.dataDirectoryURL }
    var journalFileURL: URL { repository.journalFileURL }
    var backupsDirectoryURL: URL { repository.backupsDirectoryURL }

    var deletedSourceIDs: [String] { database.deletedSourceIDs ?? [] }

    init(
        dataDirectoryURL: URL = JournalRepository.defaultAppSupportDirectory(),
        loadUserPreferences: Bool = true
    ) {
        self.repository = JournalRepository(dataDirectoryURL: dataDirectoryURL)
        self.persistPreferences = loadUserPreferences

        var migrationWarning: String? = nil
        if loadUserPreferences {
            if let saved = UserDefaults.standard.string(forKey: "WetShaveJournal.AppearanceMode"),
               let mode = AppearanceMode(rawValue: saved) {
                self.appearanceMode = mode
            }
            if let savedLang = UserDefaults.standard.string(forKey: "WetShaveJournal.Language"),
               let lang = AppLanguage(rawValue: savedLang) {
                self.language = lang
                L10n.currentLanguage = lang
            } else {
                L10n.currentLanguage = .system
            }

            isBootstrappingAIConfig = true
            let migrated = AIConfig.loadWithLocalSecretMigration()
            self.aiConfig = migrated.config
            self.keychainWarningMessage = migrated.warning
            migrationWarning = migrated.warning
            isBootstrappingAIConfig = false

            self.cloudSyncDirectoryPath = UserDefaults.standard.string(forKey: Self.cloudSyncDirDefaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.lastCloudSyncAt = UserDefaults.standard.string(forKey: Self.lastCloudSyncAtDefaultsKey)

            self.customLogoObserver = NotificationCenter.default.addObserver(
                forName: BrandLogoCache.customLogoDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedCloudSync()
                }
            }
        }

        load()
        if let warning = migrationWarning, !isReadOnlyProtected {
            showToast(warning, isLoading: false)
        }
    }

    deinit {
        if let observer = customLogoObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 修订号驱动的只读衍生快照（R02 / R04）

    var catalogSnapshot: GearCatalogSnapshot {
        if let cached = cachedCatalogSnapshot, cached.revision == revision {
            return cached
        }
        let built = GearCatalogService.buildSnapshot(from: database, revision: revision)
        cachedCatalogSnapshot = built
        return built
    }

    var statisticsSnapshot: StatisticsSnapshot {
        let isEn = L10n.isEnglish
        if let cached = cachedStatisticsSnapshot, cached.revision == revision, cached.isEnglish == isEn {
            return cached
        }
        let built = StatisticsEngine.buildSnapshot(database: database, revision: revision, isEnglish: isEn)
        cachedStatisticsSnapshot = built
        return built
    }

    private func invalidateDerivedCaches() {
        revision &+= 1
        cachedCatalogSnapshot = nil
        cachedStatisticsSnapshot = nil
    }

    func parsedProcess(for entry: JournalEntry) -> ParsedProcess {
        if let hit = statisticsSnapshot.parsedProcessByEntryID[entry.id] {
            return hit
        }
        return ProcessParser.parse(entry.processText)
    }

    static func parseProcess(_ text: String) -> ParsedProcess {
        ProcessParser.parse(text)
    }

    // MARK: - 本机私有凭据存储与 Toast

    func clearAIAPIKey() {
        do {
            try LocalSecretStore.delete()
            UserDefaults.standard.removeObject(forKey: AIConfig.legacyAPIKeyDefaultsKey)
            isBootstrappingAIConfig = true
            aiConfig.apiKey = ""
            isBootstrappingAIConfig = false
            keychainWarningMessage = nil
            showToast(L10n.t("已清除本机保存的 API Key", "Cleared saved API key"), isLoading: false)
        } catch {
            keychainWarningMessage = error.localizedDescription
            showToast(error.localizedDescription, isLoading: false)
        }
    }

    func showToast(_ message: String, isLoading: Bool = false) {
        toastDismissTask?.cancel()
        toastDismissTask = nil

        let newToast = ToastState(id: UUID(), message: message, isLoading: isLoading)
        toast = newToast

        guard !isLoading else { return }
        let targetID = newToast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self = self, self.toast?.id == targetID else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    self.toast = nil
                }
            }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        withAnimation(.easeOut(duration: 0.18)) {
            toast = nil
        }
    }

    // MARK: - 统一加载与事务提交

    func load() {
        do {
            if let decoded = try repository.load() {
                self.database = decoded
            } else {
                self.database = JournalDatabase()
            }
            self.isReadOnlyProtected = false
            self.loadErrorMessage = nil
            invalidateDerivedCaches()
        } catch {
            print("读取 journal.json 失败: \(error)")
            self.isReadOnlyProtected = true
            self.loadErrorMessage = error.localizedDescription
            self.showToast(
                L10n.t("读取 journal.json 失败，已启用只读保护防止覆盖原数据", "Failed to read journal.json. Read-only protection enabled."),
                isLoading: false
            )
        }
    }

    /// 唯一事务提交入口：先通过仓储原子写入（高风险操作前先创建并校验独立备份），写入成功后才更新内存与刷新缓存版本
    private func commit(_ candidate: JournalDatabase, createBackup: Bool = false, triggerCloudSync: Bool = true) throws {
        try repository.persist(candidate, createBackup: createBackup, isReadOnlyProtected: isReadOnlyProtected)
        self.database = candidate
        invalidateDerivedCaches()
        if triggerCloudSync {
            scheduleDebouncedCloudSync()
        }
    }

    func save(createBackup: Bool = false) throws {
        try repository.persist(self.database, createBackup: createBackup, isReadOnlyProtected: isReadOnlyProtected)
    }

    // MARK: - 日记增删改（含 S05 删除墓碑保护与云盘双端删除墓碑）

    @discardableResult
    func upsertEntry(
        _ entry: JournalEntry,
        selectedGearBindings: [(category: GearCategory, insertedText: String, item: GearItem)] = []
    ) -> Result<Void, Error> {
        var candidate = database
        var updated = entry
        updated.locallyModified = true
        updated.hasSyncConflict = nil
        updated.suspectedDuplicate = nil
        updated.updatedAt = SyncTimestamp.nowISO8601()

        // 若用户在新建/编辑 SOTD 时通过联想菜单点选了某件器材的规范显示名，
        // 为该规范名持久化一条同源 override 映射，确保与历史别名 100% 归为同一器材绝不分裂
        for binding in selectedGearBindings {
            let trimmed = binding.insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let effectiveRaw = binding.category == .blade
                ? GearKnowledgeBase.parseBladeUsage(trimmed).baseName
                : trimmed
            let normKey = "\(binding.category.rawValue)|\(GearKnowledgeBase.normalizeKey(effectiveRaw))"
            if candidate.overrides[normKey] == nil {
                var targetOv = GearSanitizer.sanitizeOverride(
                    GearOverride.from(item: binding.item),
                    category: binding.category
                )
                targetOv.updatedAt = updated.updatedAt
                candidate.overrides[normKey] = targetOv
                candidate.pending.removeAll { $0 == normKey }
            }
        }

        if var tombstones = candidate.deletedEntryIds {
            tombstones.removeValue(forKey: updated.id)
            candidate.deletedEntryIds = tombstones.isEmpty ? nil : tombstones
        }

        if let idx = candidate.entries.firstIndex(where: { $0.id == updated.id }) {
            if updated.sourceFingerprint == nil {
                updated.sourceFingerprint = candidate.entries[idx].sourceFingerprint
            }
            candidate.entries[idx] = updated
        } else {
            candidate.entries.append(updated)
        }
        candidate.entries.sort { $0.date > $1.date }

        do {
            try commit(candidate, createBackup: false)
            return .success(())
        } catch {
            showToast(error.localizedDescription, isLoading: false)
            return .failure(error)
        }
    }

    @discardableResult
    func deleteEntry(_ entry: JournalEntry) -> Result<Void, Error> {
        var candidate = database
        candidate.entries.removeAll { $0.id == entry.id }

        // S05：对非本地创建的导入记录（来源备忘录）记录最小 tombstone，防止下次正常同步复活
        let isImportedNote = !entry.id.hasPrefix("local-")
        if isImportedNote {
            var deleted = candidate.deletedSourceIDs ?? []
            if !deleted.contains(entry.id) {
                deleted.append(entry.id)
                deleted.sort()
            }
            candidate.deletedSourceIDs = deleted
        }

        // 云盘双端同步删除墓碑（带 ISO8601 删除时间），避免一端删除后在另一端同步复活
        var entryTombstones = candidate.deletedEntryIds ?? [:]
        entryTombstones[entry.id] = SyncTimestamp.nowISO8601()
        candidate.deletedEntryIds = entryTombstones

        do {
            try commit(candidate, createBackup: false)
            return .success(())
        } catch {
            showToast(error.localizedDescription, isLoading: false)
            return .failure(error)
        }
    }

    // MARK: - 器材查询与统计代理（全部复用 revision 绑定缓存）

    func resolveGear(category: GearCategory, rawValue: String) -> (key: String, override: GearOverride) {
        GearCatalogService.resolveGear(category: category, rawValue: rawValue, in: database)
    }

    func gearItems(for category: GearCategory) -> [GearItem] {
        catalogSnapshot.items(for: category)
    }

    func allPendingItems() -> [GearItem] {
        catalogSnapshot.pendingItems
    }

    func catalogNamesByCategory() -> [GearCategory: [String]] {
        catalogSnapshot.catalogNamesByCategory
    }

    func brandGroups(for category: GearCategory) -> [BrandGroup] {
        catalogSnapshot.brandGroups(for: category)
    }

    func brandGroups(for items: [GearItem]) -> [BrandGroup] {
        GearCatalogService.brandGroups(for: items)
    }

    func searchCandidates(for category: GearCategory, query: String) -> [GearItem] {
        GearCatalogService.searchCandidates(in: gearItems(for: category), query: query)
    }

    func eligibleDrawItems(for category: GearCategory, matchingRazor razor: GearItem? = nil) -> [GearItem] {
        GearCatalogService.eligibleDrawItems(in: gearItems(for: category), category: category, matchingRazor: razor)
    }

    func rawEntrySamples(forRawKey rawKey: String, category: GearCategory) -> (display: String, count: Int) {
        GearCatalogService.rawEntrySamples(forRawKey: rawKey, category: category, in: database)
    }

    func isRazorAdjustable(_ razorText: String) -> Bool {
        GearCatalogService.isRazorAdjustable(razorText, in: database)
    }

    func suggestedNextUseCount(forBlade baseBladeName: String) -> Int {
        GearCatalogService.suggestedNextUseCount(forBlade: baseBladeName, in: database)
    }

    func referencedEntryCount(for item: GearItem) -> Int {
        GearCatalogService.referencedEntryCount(for: item, in: database)
    }

    func razorBladeComboStats() -> [RazorBladeComboStat] {
        statisticsSnapshot.comboStats
    }

    func bladeLongevityStats() -> [BladeLongevityStat] {
        statisticsSnapshot.bladeLongevityStats
    }

    func exportGearLibraryCSV() -> String {
        GearCatalogService.exportGearLibraryCSV(catalog: catalogSnapshot)
    }

    func buildDiagnosisStatsSummary() -> String {
        StatisticsEngine.buildDiagnosisStatsSummary(
            database: database,
            catalog: catalogSnapshot,
            snapshot: statisticsSnapshot
        )
    }

    // MARK: - 器材变更（全部经 GearMutationService 规划后走统一事务提交）

    private func executePlan(_ plan: GearMutationPlan) -> Result<Void, Error> {
        guard plan.didMutate else {
            if !plan.toastMessage.isEmpty {
                showToast(plan.toastMessage, isLoading: false)
            }
            return .success(())
        }
        do {
            try commit(plan.database, createBackup: plan.shouldBackup)
            if !plan.toastMessage.isEmpty {
                showToast(plan.toastMessage, isLoading: false)
            }
            return .success(())
        } catch {
            showToast(error.localizedDescription, isLoading: false)
            return .failure(error)
        }
    }

    @discardableResult
    func updateGearItem(rawKeys: [String], category: GearCategory, newOverride: GearOverride, clearPending: Bool = true) -> Result<Void, Error> {
        let plan = GearMutationService.planUpdateGearItem(
            rawKeys: rawKeys,
            category: category,
            newOverride: newOverride,
            clearPending: clearPending,
            in: database
        )
        return executePlan(plan)
    }

    @discardableResult
    func applyAuditProposals(updates: [GearAuditUpdateProposal], merges: [GearAuditMergeProposal]) -> Result<Void, Error> {
        let plan = GearMutationService.planApplyAuditProposals(updates: updates, merges: merges, in: database)
        return executePlan(plan)
    }

    @discardableResult
    func mergeGearItem(source: GearItem, into target: GearItem) -> Result<Void, Error> {
        switch GearMutationService.planMergeGearItem(source: source, into: target, in: database) {
        case .success(let plan):
            return executePlan(plan)
        case .failure(let error):
            showToast(error.localizedDescription, isLoading: false)
            return .failure(error)
        }
    }

    @discardableResult
    func splitRawKey(_ rawKey: String, from item: GearItem) -> Result<Void, Error> {
        let plan = GearMutationService.planSplitRawKey(rawKey, from: item, in: database)
        return executePlan(plan)
    }

    func createQuickGear(category: GearCategory, name: String, brand: String? = nil) -> Result<GearOverride, Error> {
        let (plan, created) = GearMutationService.planCreateQuickGear(category: category, name: name, brand: brand, in: database)
        switch executePlan(plan) {
        case .success: return .success(created)
        case .failure(let err): return .failure(err)
        }
    }

    @discardableResult
    func markPending(_ rawKeys: [String], isPending: Bool) -> Result<Void, Error> {
        let plan = GearMutationService.planMarkPending(rawKeys, isPending: isPending, in: database)
        return executePlan(plan)
    }

    @discardableResult
    func deleteGearItem(_ item: GearItem, removeFromEntries: Bool) -> Result<Void, Error> {
        let plan = GearMutationService.planDeleteGearItem(item, removeFromEntries: removeFromEntries, in: database)
        return executePlan(plan)
    }

    @discardableResult
    func undoLastOverrideChange() -> Result<Void, Error> {
        let plan = GearMutationService.planUndoLastOverrideChange(in: database)
        return executePlan(plan)
    }

    // MARK: - 复制 SOTD 文本

    func formatSOTDForSharing(_ entry: JournalEntry) -> String {
        let isEn = L10n.isEnglish
        var lines: [String] = []
        lines.append(isEn ? "**SOTD · \(entry.date)**" : "SOTD · \(entry.date)")
        lines.append("")

        func formatGearLine(category: GearCategory, raw: String) -> String {
            let (_, ov) = resolveGear(category: category, rawValue: raw)
            let brand = L10n.brandDisplay(ov.brand)
            let model = ov.displayModel
            let baseName = (brand == "Unknown Brand" || brand == "品牌未注明" || brand == "Clone" || brand == "仿刀")
                ? model
                : (model.lowercased().hasPrefix(brand.lowercased()) ? model : "\(brand) \(model)")

            var extras: [String] = []
            switch category {
            case .razor:
                extras.append(contentsOf: GearSpecFormatter.specTags(category: .razor, override: ov))
            case .blade:
                let parsed = GearKnowledgeBase.parseBladeUsage(raw)
                if let u = parsed.useCount {
                    extras.append(isEn ? L10n.ordinal(u) : "第 \(u) 次")
                }
            case .brush:
                if let hb = ov.handleBrand, !hb.isEmpty { extras.append(L10n.handleTag(hb)) }
                extras.append(contentsOf: GearSpecFormatter.specTags(category: .brush, override: ov))
                if let ks = ov.knotSize, !ks.isEmpty { extras.append(ks) }
            case .soap, .afterShave:
                if ov.isSample == true { extras.append(L10n.t("小样", "Sample")) }
            default:
                break
            }

            let detail = extras.isEmpty ? "" : (isEn ? " (\(extras.joined(separator: " · ")))" : "（\(extras.joined(separator: " · "))）")
            return isEn
                ? "* **\(category.singularName):** \(baseName)\(detail)"
                : "• \(category.singularName)：\(baseName)\(detail)"
        }

        for r in entry.fieldValues(matching: ["剃须刀"]) { lines.append(formatGearLine(category: .razor, raw: r)) }
        for b in entry.fieldValues(matching: ["刀片"]) { lines.append(formatGearLine(category: .blade, raw: b)) }
        if !entry.brush.isEmpty { lines.append(formatGearLine(category: .brush, raw: entry.brush)) }
        if !entry.soap.isEmpty { lines.append(formatGearLine(category: .soap, raw: entry.soap)) }
        if !entry.bowl.isEmpty { lines.append(formatGearLine(category: .bowl, raw: entry.bowl)) }
        if !entry.preShave.isEmpty && entry.preShave != "无" { lines.append(formatGearLine(category: .preShave, raw: entry.preShave)) }
        if !entry.afterShave.isEmpty && entry.afterShave != "无" { lines.append(formatGearLine(category: .afterShave, raw: entry.afterShave)) }

        var prepParts: [String] = []
        if !entry.loadingMethod.isEmpty { prepParts.append(L10n.loadingDisplay(entry.loadingMethod)) }
        if !entry.pureLatheringMethod.isEmpty { prepParts.append(L10n.latheringDisplay(entry.pureLatheringMethod)) }
        if entry.hotTowel { prepParts.append(L10n.t("热敷", "Hot Towel")) }
        if entry.afterShower.hasPrefix("是") { prepParts.append(L10n.t("浴后", "Post-Shower")) }
        if entry.alum.hasPrefix("是") { prepParts.append(L10n.t("明矾", "Alum")) }
        if !prepParts.isEmpty {
            lines.append(isEn ? "* **Prep & Lather:** \(prepParts.joined(separator: " · "))" : "• 流程：\(prepParts.joined(separator: " · "))")
        }

        let proc = parsedProcess(for: entry)
        var passParts: [String] = []
        if !proc.passes.isEmpty {
            let passStr = proc.passes.map { step in
                if step.setting.isEmpty { return step.pass.displayName }
                return isEn ? "\(step.pass.displayName) (#\(step.setting))" : "\(step.pass.displayName)(\(step.setting)档)"
            }.joined(separator: isEn ? ", " : " / ")
            passParts.append(passStr)
        }
        if let irr = proc.irritation { passParts.append(irr.displayName) }
        if let res = proc.result { passParts.append(res.displayName) }
        if !proc.note.isEmpty { passParts.append(proc.note) }

        if !passParts.isEmpty {
            lines.append(isEn ? "* **Result:** \(passParts.joined(separator: " · "))" : "• 过程：\(passParts.joined(separator: " · "))")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - 批量识别待确认器材

    func recognizeAllPending() async {
        guard !isReadOnlyProtected else {
            showToast(JournalPersistenceError.readOnlyProtected.localizedDescription, isLoading: false)
            return
        }
        guard !isRecognizingBatch else { return }
        isRecognizingBatch = true
        defer { isRecognizingBatch = false }

        let keys = database.pending
        guard !keys.isEmpty else {
            showToast(L10n.t("当前没有待确认器材", "No pending items to review"), isLoading: false)
            return
        }

        var preSnapshotByKey: [String: (fingerprint: String?, isManual: Bool)] = [:]
        for key in keys {
            let ov = database.overrides[key]
            preSnapshotByKey[key] = (ov?.fingerprint, ov?.isManuallyConfirmed == true)
        }

        let currentAI = aiConfig
        var collectedUpdates: [(key: String, override: GearOverride)] = []
        var skippedManualCount = 0
        var lowConfidenceCount = 0

        for (idx, key) in keys.enumerated() {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let cat = GearCategory(rawValue: parts[0]) else { continue }
            let existing = database.overrides[key]

            if existing?.isManuallyConfirmed == true {
                skippedManualCount += 1
                continue
            }

            let queryName = existing?.name ?? parts[1]
            showToast(
                L10n.t("正在识别 (\(idx + 1)/\(keys.count))：\(queryName)", "Recognizing (\(idx + 1)/\(keys.count)): \(queryName)"),
                isLoading: true
            )

            let res = await WebGearRecognizer.shared.recognize(name: queryName, category: cat, aiConfig: currentAI)
            guard res.confidence >= 0.72 else {
                lowConfidenceCount += 1
                continue
            }

            var updated = existing ?? GearOverride(
                brand: res.suggestedBrand ?? "品牌未注明",
                name: res.suggestedName ?? queryName,
                status: cat == .blade ? .inStock : .active
            )
            if let b = res.suggestedBrand, !b.isEmpty { updated.brand = b }
            if let hb = res.suggestedHandleBrand, !hb.isEmpty { updated.handleBrand = hb }
            if let n = res.suggestedName, !n.isEmpty { updated.name = n }
            if let m = res.suggestedModel { updated.model = m }
            if let rt = res.razorType { updated.razorType = rt }
            if let adj = res.isAdjustable { updated.isAdjustable = adj }
            if let sl = res.isSlant { updated.isSlant = sl }
            if let mat = res.material { updated.material = mat }
            if let pt = res.plateType { updated.plateType = pt }
            if let gap = res.gapOrSpec { updated.gapOrSpec = gap }
            if let blt = res.bladeType { updated.bladeType = blt }
            if let bm = res.brushMaterial { updated.brushMaterial = bm }
            if let bt = res.badgerTreatment { updated.badgerTreatment = bt }
            if let bb = res.badgerBand { updated.badgerBand = bb }
            if let ks = res.knotSize { updated.knotSize = ks }
            if let sh = res.knotShape { updated.knotShape = sh }
            updated.recognizedSource = res.sourceSummary
            updated = GearSanitizer.sanitizeOverride(updated, category: cat, extraNotes: res.notes)

            collectedUpdates.append((key: key, override: updated))
        }

        var candidate = database
        var updatedCount = 0
        var skippedConcurrentCount = 0
        var validUpdates: [(key: String, override: GearOverride)] = []

        for item in collectedUpdates {
            let liveOv = candidate.overrides[item.key]
            let pre = preSnapshotByKey[item.key]
            if liveOv?.isManuallyConfirmed == true || liveOv?.fingerprint != pre?.fingerprint {
                skippedConcurrentCount += 1
                continue
            }
            validUpdates.append(item)
        }

        let totalSkipped = skippedManualCount + skippedConcurrentCount
        guard !validUpdates.isEmpty else {
            showToast(
                L10n.t(
                    "识别完成：未自动写入（低置信度保留待确认 \(lowConfidenceCount) 件，跳过人工/并发修改 \(totalSkipped) 件）",
                    "Done: no auto-writes (\(lowConfidenceCount) low-confidence kept pending, \(totalSkipped) manual/modified skipped)"
                ),
                isLoading: false
            )
            return
        }

        GearMutationService.pushHistory(into: &candidate)
        let batchNowISO = SyncTimestamp.nowISO8601()
        for item in validUpdates {
            var stamped = item.override
            stamped.updatedAt = batchNowISO
            candidate.overrides[item.key] = stamped
            candidate.pending.removeAll { $0 == item.key }
            updatedCount += 1
        }

        do {
            try commit(candidate, createBackup: true)
            let pendingCount = database.pending.count
            if totalSkipped > 0 {
                showToast(
                    L10n.t(
                        "识别完成：已自动确认 \(updatedCount) 件，跳过人工/已修改 \(totalSkipped) 件，剩余 \(pendingCount) 件待核对",
                        "Done: \(updatedCount) confirmed, \(totalSkipped) manual/modified skipped, \(pendingCount) still pending"
                    ),
                    isLoading: false
                )
            } else {
                showToast(
                    L10n.t(
                        "识别完成：已自动确认 \(updatedCount) 件，剩余 \(pendingCount) 件待核对",
                        "Done: \(updatedCount) confirmed, \(pendingCount) still pending"
                    ),
                    isLoading: false
                )
            }
        } catch {
            showToast(error.localizedDescription, isLoading: false)
        }
    }

    // MARK: - Apple 备忘录同步（S01 / S04 / S05）

    @discardableResult
    func applySyncedNotes(_ notes: [RawAppleNote], allowReimportDeleted: Bool = false) -> Result<NotesSyncPlan, Error> {
        let plan = NotesSyncService.planSync(notes: notes, into: database, allowReimportDeleted: allowReimportDeleted)
        do {
            try commit(plan.database, createBackup: plan.shouldBackup)
            showToast(plan.summaryToast(totalCount: database.entries.count), isLoading: false)
            return .success(plan)
        } catch {
            showToast(error.localizedDescription, isLoading: false)
            return .failure(error)
        }
    }

    func syncFromAppleNotes(allowReimportDeleted: Bool = false) async {
        guard !isReadOnlyProtected else {
            showToast(JournalPersistenceError.readOnlyProtected.localizedDescription, isLoading: false)
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        showToast(
            allowReimportDeleted
                ? L10n.t("正在从 Apple 备忘录恢复已删记录...", "Restoring deleted entries from Apple Notes...")
                : L10n.t("正在读取 Apple 备忘录...", "Syncing from Apple Notes..."),
            isLoading: true
        )
        defer { isSyncing = false }

        let candidatePaths: [String] = [
            Bundle.main.path(forResource: "read-notes", ofType: "js"),
            "/Applications/WetShaveJournal.app/Contents/Resources/read-notes.js",
            "/Users/EthanAn/Applications/WetShaveJournal.app/Contents/Resources/read-notes.js",
            "/Applications/湿剃日记.app/Contents/Resources/read-notes.js"
        ].compactMap { $0 }

        guard let scriptPath = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            showToast(NotesSyncError.scriptNotFound.localizedDescription, isLoading: false)
            return
        }

        let outputResult = await NotesSyncService.runAppleNotesScript(scriptPath: scriptPath, timeoutSeconds: 30)
        switch outputResult {
        case .failure(let error):
            showToast(
                L10n.t("备忘录同步失败：\(error.localizedDescription)", "Notes sync failed: \(error.localizedDescription)"),
                isLoading: false
            )
        case .success(let jsonString):
            guard let data = jsonString.data(using: .utf8),
                  let notes = try? JSONDecoder().decode([RawAppleNote].self, from: data) else {
                showToast(NotesSyncError.invalidJSON.localizedDescription, isLoading: false)
                return
            }
            _ = applySyncedNotes(notes, allowReimportDeleted: allowReimportDeleted)
        }
    }

    // MARK: - 云盘双端自动同步（journal.json + CustomLogos/）

    var hasCloudSyncDirectory: Bool {
        !cloudSyncDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setCloudSyncDirectory(_ url: URL) {
        let trimmed = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cloudSyncDirectoryPath = trimmed
        if persistPreferences {
            UserDefaults.standard.set(trimmed, forKey: Self.cloudSyncDirDefaultsKey)
        }
        Task {
            await syncWithCloudDirectory(manual: true)
        }
    }

    func clearCloudSyncDirectory() {
        cloudSyncDebounceTask?.cancel()
        cloudSyncDebounceTask = nil
        pendingFollowUpCloudSync = false
        cloudSyncDirectoryPath = ""
        lastCloudSyncResult = nil
        if persistPreferences {
            UserDefaults.standard.removeObject(forKey: Self.cloudSyncDirDefaultsKey)
        }
        showToast(
            L10n.t("已关闭云盘同步（本地与云端文件均保持不变）", "Cloud sync disabled (local and cloud files kept intact)"),
            isLoading: false
        )
    }

    func performStartupCloudSyncIfConfigured() async {
        guard !hasPerformedStartupCloudSync else { return }
        hasPerformedStartupCloudSync = true
        guard hasCloudSyncDirectory, !isReadOnlyProtected else { return }
        await syncWithCloudDirectory(manual: false)
    }

    func scheduleDebouncedCloudSync() {
        guard hasCloudSyncDirectory, !isReadOnlyProtected else { return }
        cloudSyncDebounceTask?.cancel()
        cloudSyncDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncWithCloudDirectory(manual: false)
        }
    }

    @discardableResult
    func syncWithCloudDirectory(manual: Bool) async -> CloudSyncResult {
        let trimmedPath = cloudSyncDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            let disabled = CloudSyncResult(status: .disabled, syncedAt: SyncTimestamp.nowISO8601())
            lastCloudSyncResult = disabled
            return disabled
        }
        guard !isReadOnlyProtected else {
            let err = CloudSyncResult(
                status: .error,
                syncedAt: SyncTimestamp.nowISO8601(),
                errorMessage: JournalPersistenceError.readOnlyProtected.localizedDescription
            )
            lastCloudSyncResult = err
            if manual {
                showToast(err.summaryText(isEnglish: L10n.isEnglish), isLoading: false)
            }
            return err
        }
        if isCloudSyncing {
            pendingFollowUpCloudSync = true
            return lastCloudSyncResult ?? CloudSyncResult(status: .upToDate, syncedAt: SyncTimestamp.nowISO8601())
        }

        cloudSyncDebounceTask?.cancel()
        cloudSyncDebounceTask = nil
        isCloudSyncing = true

        let repo = self.repository
        let cloudURL = URL(fileURLWithPath: trimmedPath, isDirectory: true)
        let result = await Task.detached(priority: .utility) {
            CloudSyncService.performBidirectionalSync(
                localRepository: repo,
                cloudSyncDirectory: cloudURL
            )
        }.value

        isCloudSyncing = false
        lastCloudSyncResult = result

        if result.status == .synced || result.status == .upToDate {
            lastCloudSyncAt = result.syncedAt
            if persistPreferences {
                UserDefaults.standard.set(result.syncedAt, forKey: Self.lastCloudSyncAtDefaultsKey)
            }
        }

        if result.localDidChange {
            // 重新从本地磁盘加载合并后的 journal.json，不触发二次防抖同步
            load()
        }
        if result.logosPulled > 0 {
            BrandLogoCache.shared.reloadCustomLogos()
        }

        if manual {
            showToast(result.summaryText(isEnglish: L10n.isEnglish), isLoading: false)
        }

        if pendingFollowUpCloudSync {
            pendingFollowUpCloudSync = false
            scheduleDebouncedCloudSync()
        }

        return result
    }
}
