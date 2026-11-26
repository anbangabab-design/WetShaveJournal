import Foundation

// MARK: - 云盘双端同步状态与结果模型

enum CloudSyncStatus: String, Codable, Equatable, Sendable {
    case synced
    case upToDate
    case unavailable
    case sameDirectory
    case disabled
    case error
}

struct CloudSyncResult: Codable, Equatable, Sendable {
    var status: CloudSyncStatus
    var syncedAt: String
    var entriesAdded: Int = 0
    var entriesUpdated: Int = 0
    var entriesDeleted: Int = 0
    var entriesPushed: Int = 0
    var rulesAdded: Int = 0
    var rulesUpdated: Int = 0
    var rulesPushed: Int = 0
    var logosPulled: Int = 0
    var logosPushed: Int = 0
    var localDidChange: Bool = false
    var remoteDidChange: Bool = false
    var errorMessage: String? = nil

    var totalPulledEntries: Int { entriesAdded + entriesUpdated }
    var totalPulledRules: Int { rulesAdded + rulesUpdated }
    var totalSyncedLogos: Int { logosPulled + logosPushed }

    func summaryText(isEnglish: Bool) -> String {
        switch status {
        case .disabled:
            return isEnglish ? "Cloud sync disabled" : "云盘同步未开启"
        case .sameDirectory:
            return isEnglish
                ? "Sync folder matches active data folder; no duplicate sync needed"
                : "同步目录与当前数据目录相同，无需重复同步"
        case .unavailable:
            if let err = errorMessage, !err.isEmpty {
                return err
            }
            return isEnglish
                ? "Cloud sync folder is currently unavailable (drive may not be mounted)"
                : "云盘同步目录当前不可访问（云盘可能未挂载）"
        case .error:
            let detail = errorMessage ?? (isEnglish ? "Unknown error" : "未知错误")
            return isEnglish ? "Sync failed: \(detail)" : "同步失败：\(detail)"
        case .upToDate:
            return isEnglish ? "Both devices are up to date" : "双端数据已一致"
        case .synced:
            var pulledPartsZH: [String] = []
            var pulledPartsEN: [String] = []

            if entriesAdded > 0 {
                pulledPartsZH.append("+\(entriesAdded) 篇日记")
                pulledPartsEN.append("+\(entriesAdded) \(entriesAdded == 1 ? "entry" : "entries")")
            }
            if entriesUpdated > 0 {
                pulledPartsZH.append("更新 \(entriesUpdated) 篇日记")
                pulledPartsEN.append("\(entriesUpdated) updated")
            }
            if entriesDeleted > 0 {
                pulledPartsZH.append("同步删除 \(entriesDeleted) 篇")
                pulledPartsEN.append("\(entriesDeleted) deleted")
            }
            let rulesDelta = rulesAdded + rulesUpdated
            if rulesDelta > 0 {
                pulledPartsZH.append("+\(rulesDelta) 条规则")
                pulledPartsEN.append("+\(rulesDelta) \(rulesDelta == 1 ? "rule" : "rules")")
            }
            if totalSyncedLogos > 0 {
                pulledPartsZH.append("+\(totalSyncedLogos) 个图标")
                pulledPartsEN.append("+\(totalSyncedLogos) \(totalSyncedLogos == 1 ? "logo" : "logos")")
            }

            if !pulledPartsZH.isEmpty {
                return isEnglish
                    ? "Merged \(pulledPartsEN.joined(separator: " / "))"
                    : "已合并 \(pulledPartsZH.joined(separator: " / "))"
            }

            var pushedPartsZH: [String] = []
            var pushedPartsEN: [String] = []
            if entriesPushed > 0 {
                pushedPartsZH.append("+\(entriesPushed) 篇日记")
                pushedPartsEN.append("+\(entriesPushed) \(entriesPushed == 1 ? "entry" : "entries")")
            }
            if rulesPushed > 0 {
                pushedPartsZH.append("+\(rulesPushed) 条规则")
                pushedPartsEN.append("+\(rulesPushed) \(rulesPushed == 1 ? "rule" : "rules")")
            }
            if !pushedPartsZH.isEmpty {
                return isEnglish
                    ? "Pushed to cloud (\(pushedPartsEN.joined(separator: " / ")))"
                    : "已同步至云盘（\(pushedPartsZH.joined(separator: " / "))）"
            }

            return isEnglish ? "Sync completed" : "双向同步完成"
        }
    }
}

struct CloudMergeOutput {
    var mergedObject: [String: Any]
    var entriesAdded: Int = 0
    var entriesUpdated: Int = 0
    var entriesDeleted: Int = 0
    var entriesPushed: Int = 0
    var rulesAdded: Int = 0
    var rulesUpdated: Int = 0
    var rulesPushed: Int = 0
    var localDidChange: Bool = false
    var remoteDidChange: Bool = false
}

// MARK: - 云盘 journal.json + CustomLogos/ 智能双向合并引擎（与 Windows Rust 端算法完全对齐）

enum CloudSyncService {
    private static let maxHistoryDepth = 30
    private static let maxLogoBytes: UInt64 = 8 * 1024 * 1024
    private static let logoExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "ico", "bmp", "svg", "heic", "tiff"
    ]
    private static let coreTopLevelKeys: Set<String> = [
        "schemaVersion", "entries", "duplicates", "skipped", "lastSync",
        "overrides", "pending", "history", "deletedSourceIDs", "deletedEntryIds"
    ]

    // MARK: - 顶层入口：执行一次完整的双向同步

    static func performBidirectionalSync(
        localRepository: JournalRepository,
        cloudSyncDirectory: URL
    ) -> CloudSyncResult {
        let nowISO = SyncTimestamp.nowISO8601()
        let fm = FileManager.default

        // 1. 校验云盘同步目录是否可访问（不静默创建未挂载云盘根目录）
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cloudSyncDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return CloudSyncResult(
                status: .unavailable,
                syncedAt: nowISO,
                errorMessage: L10n.t(
                    "云盘同步目录当前不可访问（可能未挂载）",
                    "Cloud sync folder is currently unavailable (drive may not be mounted)"
                )
            )
        }

        // 2. 防止同步目录与当前数据目录指向同一路径
        let localCanon = localRepository.dataDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let cloudCanon = cloudSyncDirectory.standardizedFileURL.resolvingSymlinksInPath()
        if localCanon == cloudCanon {
            return CloudSyncResult(status: .sameDirectory, syncedAt: nowISO)
        }

        let localFileURL = localRepository.journalFileURL
        let remoteFileURL = cloudSyncDirectory.appendingPathComponent("journal.json")

        let localExists = fm.fileExists(atPath: localFileURL.path)
        let remoteExists = fm.fileExists(atPath: remoteFileURL.path)

        // 3. 读取本地与云端原始 JSON 对象（完整保留未知扩展字段）
        let localObj: [String: Any]
        let localMtimeMs: Int64?
        if localExists {
            do {
                let data = try Data(contentsOf: localFileURL)
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return CloudSyncResult(
                        status: .error,
                        syncedAt: nowISO,
                        errorMessage: L10n.t("本地 journal.json 根节点不是有效的 JSON 对象", "Local journal.json root is not a valid JSON object")
                    )
                }
                localObj = parsed
                localMtimeMs = fileModificationEpochMillis(localFileURL)
            } catch {
                return CloudSyncResult(
                    status: .error,
                    syncedAt: nowISO,
                    errorMessage: L10n.t("读取本地 journal.json 失败：\(error.localizedDescription)", "Failed to read local journal.json: \(error.localizedDescription)")
                )
            }
        } else {
            localObj = emptyDatabaseObject()
            localMtimeMs = nil
        }

        let remoteObj: [String: Any]
        let remoteMtimeMs: Int64?
        if remoteExists {
            do {
                let data = try Data(contentsOf: remoteFileURL)
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return CloudSyncResult(
                        status: .error,
                        syncedAt: nowISO,
                        errorMessage: L10n.t("云端 journal.json 根节点不是有效的 JSON 对象", "Cloud journal.json root is not a valid JSON object")
                    )
                }
                remoteObj = parsed
                remoteMtimeMs = fileModificationEpochMillis(remoteFileURL)
            } catch {
                return CloudSyncResult(
                    status: .error,
                    syncedAt: nowISO,
                    errorMessage: L10n.t("读取云端 journal.json 失败：\(error.localizedDescription)", "Failed to read cloud journal.json: \(error.localizedDescription)")
                )
            }
        } else {
            remoteObj = emptyDatabaseObject()
            remoteMtimeMs = nil
        }

        // 4. 智能双向合并
        var merge = mergeDatabases(
            local: localObj,
            localMtimeMs: localMtimeMs,
            remote: remoteObj,
            remoteMtimeMs: remoteMtimeMs,
            localExists: localExists,
            remoteExists: remoteExists
        )

        // 5. 若有任一侧需要写入，先落盘备份再原子替换
        let needWriteLocal = merge.localDidChange || (!localExists && remoteExists)
        let needWriteRemote = merge.remoteDidChange || !remoteExists

        if needWriteLocal || needWriteRemote {
            merge.mergedObject["lastSync"] = Date().timeIntervalSinceReferenceDate
            let mergedData: Data
            do {
                mergedData = try JSONSerialization.data(
                    withJSONObject: merge.mergedObject,
                    options: [.prettyPrinted, .sortedKeys]
                )
                // 回读校验确保生成的 JSON 可被本地 JournalDatabase 正常解码
                _ = try JSONDecoder().decode(JournalDatabase.self, from: mergedData)
            } catch {
                return CloudSyncResult(
                    status: .error,
                    syncedAt: nowISO,
                    errorMessage: L10n.t("合并数据校验失败：\(error.localizedDescription)", "Merged data validation failed: \(error.localizedDescription)")
                )
            }

            if needWriteLocal {
                do {
                    if localExists {
                        try localRepository.createVerifiedBackup(fallbackDatabase: JournalDatabase())
                    }
                    try JournalRepository.atomicWriteData(mergedData, to: localFileURL)
                } catch {
                    return CloudSyncResult(
                        status: .error,
                        syncedAt: nowISO,
                        errorMessage: L10n.t("写入本地 journal.json 失败：\(error.localizedDescription)", "Failed to write local journal.json: \(error.localizedDescription)")
                    )
                }
            }

            if needWriteRemote {
                do {
                    try JournalRepository.atomicWriteData(mergedData, to: remoteFileURL)
                } catch {
                    return CloudSyncResult(
                        status: .unavailable,
                        syncedAt: nowISO,
                        entriesAdded: merge.entriesAdded,
                        entriesUpdated: merge.entriesUpdated,
                        entriesDeleted: merge.entriesDeleted,
                        rulesAdded: merge.rulesAdded,
                        rulesUpdated: merge.rulesUpdated,
                        localDidChange: needWriteLocal,
                        errorMessage: L10n.t("写入云盘 journal.json 失败：\(error.localizedDescription)", "Failed to write cloud journal.json: \(error.localizedDescription)")
                    )
                }
            }
        }

        // 6. 双向增量同步 CustomLogos/
        let logoSync = syncCustomLogos(
            localDataDir: localRepository.dataDirectoryURL,
            cloudSyncDir: cloudSyncDirectory
        )

        let anyChange = needWriteLocal || needWriteRemote || logoSync.pulled > 0 || logoSync.pushed > 0
        return CloudSyncResult(
            status: anyChange ? .synced : .upToDate,
            syncedAt: nowISO,
            entriesAdded: merge.entriesAdded,
            entriesUpdated: merge.entriesUpdated,
            entriesDeleted: merge.entriesDeleted,
            entriesPushed: merge.entriesPushed,
            rulesAdded: merge.rulesAdded,
            rulesUpdated: merge.rulesUpdated,
            rulesPushed: merge.rulesPushed,
            logosPulled: logoSync.pulled,
            logosPushed: logoSync.pushed,
            localDidChange: needWriteLocal,
            remoteDidChange: needWriteRemote
        )
    }

    // MARK: - 纯函数双向 JSON 合并（可独立单元测试）

    static func mergeDatabases(
        local: [String: Any],
        localMtimeMs: Int64?,
        remote: [String: Any],
        remoteMtimeMs: Int64?,
        localExists: Bool = true,
        remoteExists: Bool = true
    ) -> CloudMergeOutput {
        var output = CloudMergeOutput(mergedObject: [:])

        // 1. 合并 deletedEntryIds（取各 id 较新的删除时间戳）
        var mergedDeletedEntries = mergeDeletedEntryMap(
            local: extractStringMap(local["deletedEntryIds"]),
            remote: extractStringMap(remote["deletedEntryIds"])
        )

        // 2. 合并 deletedSourceIDs（去重排序并集）
        let localDeletedSources = extractStringArray(local["deletedSourceIDs"])
        let remoteDeletedSources = extractStringArray(remote["deletedSourceIDs"])
        let mergedDeletedSources = Array(Set(localDeletedSources).union(remoteDeletedSources)).sorted()

        // 3. 合并 entries（删除墓碑过滤 + id 双向并集 + updatedAt 冲突消解 + 日期与核心器材指纹防重）
        let rawLocalEntries = extractObjectArray(local["entries"])
        let rawRemoteEntries = extractObjectArray(remote["entries"])

        let localMap = indexEntriesByID(rawLocalEntries, fallbackMtimeMs: localMtimeMs)
        let remoteMap = indexEntriesByID(rawRemoteEntries, fallbackMtimeMs: remoteMtimeMs)

        // 过滤墓碑：仅当条目有显式 updatedAt 且严格晚于 deletedAt 时允许复活（并移除墓碑）
        var survivingLocal: [String: [String: Any]] = [:]
        for (id, entry) in localMap {
            if let delISO = mergedDeletedEntries[id] {
                if shouldEntryReviveOverTombstone(entry: entry, deletedISO: delISO) {
                    mergedDeletedEntries.removeValue(forKey: id)
                    survivingLocal[id] = entry
                } else {
                    output.entriesDeleted += 1
                }
            } else {
                survivingLocal[id] = entry
            }
        }

        var survivingRemote: [String: [String: Any]] = [:]
        for (id, entry) in remoteMap {
            if let delISO = mergedDeletedEntries[id] {
                if shouldEntryReviveOverTombstone(entry: entry, deletedISO: delISO) {
                    mergedDeletedEntries.removeValue(forKey: id)
                    survivingRemote[id] = entry
                }
            } else {
                survivingRemote[id] = entry
            }
        }

        // 先合并所有共同 id 与仅本地 id，并建立核心器材指纹索引供跨端不同 id 防重
        var mergedEntriesByID: [String: [String: Any]] = [:]
        var fingerprintToLocalID: [String: String] = [:]

        for (id, localEntry) in survivingLocal {
            if let remoteEntry = survivingRemote[id] {
                let (chosen, remoteWon) = resolveEntryConflict(
                    local: localEntry,
                    localMtimeMs: localMtimeMs,
                    remote: remoteEntry,
                    remoteMtimeMs: remoteMtimeMs
                )
                mergedEntriesByID[id] = chosen
                if remoteWon && !jsonObjectsEqual(localEntry, chosen) {
                    output.entriesUpdated += 1
                } else if !remoteWon && !jsonObjectsEqual(remoteEntry, chosen) {
                    output.entriesPushed += 1
                }
            } else {
                mergedEntriesByID[id] = localEntry
                if remoteExists {
                    output.entriesPushed += 1
                }
            }
            if let fp = coreGearFingerprint(for: mergedEntriesByID[id]!) {
                if fingerprintToLocalID[fp] == nil {
                    fingerprintToLocalID[fp] = id
                }
            }
        }

        // 处理仅存在于云端的条目：检查是否与本地条目命中「日期 + 核心器材指纹」防重
        for (remoteID, remoteEntry) in survivingRemote where survivingLocal[remoteID] == nil {
            if let fp = coreGearFingerprint(for: remoteEntry),
               let matchedLocalID = fingerprintToLocalID[fp],
               let existingLocal = mergedEntriesByID[matchedLocalID],
               survivingRemote[matchedLocalID] == nil,
               areProcessTextsCompatible(existingLocal, remoteEntry) {
                // 跨端不同 ID 录入了同一场剃须：合并为较新/更完整的一条，并使用确定性主 ID（非 local- 优先，其次字典序较小）确保双端收敛不震荡
                let (chosen, remoteWon) = resolveEntryConflict(
                    local: existingLocal,
                    localMtimeMs: localMtimeMs,
                    remote: remoteEntry,
                    remoteMtimeMs: remoteMtimeMs
                )
                let canonicalID = pickCanonicalDuplicateID(matchedLocalID, remoteID)
                var mergedDup = chosen
                mergedDup["id"] = canonicalID
                if canonicalID != matchedLocalID {
                    mergedEntriesByID.removeValue(forKey: matchedLocalID)
                    fingerprintToLocalID[fp] = canonicalID
                }
                mergedEntriesByID[canonicalID] = mergedDup
                if (remoteWon || canonicalID != matchedLocalID) && !jsonObjectsEqual(existingLocal, mergedDup) {
                    output.entriesUpdated += 1
                }
                continue
            }

            mergedEntriesByID[remoteID] = remoteEntry
            output.entriesAdded += 1
        }

        let sortedEntries = Array(mergedEntriesByID.values).sorted { a, b in
            let da = (a["date"] as? String) ?? ""
            let db = (b["date"] as? String) ?? ""
            if da != db { return da > db }
            let ia = (a["id"] as? String) ?? ""
            let ib = (b["id"] as? String) ?? ""
            return ia < ib
        }

        // 4. 合并 overrides（按 key 双向合并 + updatedAt/人工确认优先 + 保留未知字段）
        let localOverrides = extractObjectMap(local["overrides"])
        let remoteOverrides = extractObjectMap(remote["overrides"])
        var mergedOverrides: [String: [String: Any]] = [:]
        var remoteWonOverrideKeys: Set<String> = []
        var localWonOverrideKeys: Set<String> = []

        let allOverrideKeys = Set(localOverrides.keys).union(remoteOverrides.keys)
        for key in allOverrideKeys {
            switch (localOverrides[key], remoteOverrides[key]) {
            case (let l?, nil):
                mergedOverrides[key] = l
                localWonOverrideKeys.insert(key)
                if remoteExists {
                    output.rulesPushed += 1
                }
            case (nil, let r?):
                mergedOverrides[key] = r
                remoteWonOverrideKeys.insert(key)
                output.rulesAdded += 1
            case (let l?, let r?):
                let (chosen, remoteWon) = resolveOverrideConflict(
                    local: l,
                    localMtimeMs: localMtimeMs,
                    remote: r,
                    remoteMtimeMs: remoteMtimeMs
                )
                mergedOverrides[key] = chosen
                if remoteWon {
                    remoteWonOverrideKeys.insert(key)
                    if !jsonObjectsEqual(l, chosen) {
                        output.rulesUpdated += 1
                    }
                } else {
                    localWonOverrideKeys.insert(key)
                    if !jsonObjectsEqual(r, chosen) {
                        output.rulesPushed += 1
                    }
                }
            case (nil, nil):
                break
            }
        }

        // 5. 合并 pending（双向并集，同时剔除已被另一端人工确认或较新修改解除待确认的 key）
        let localPending = extractStringArray(local["pending"])
        let remotePending = extractStringArray(remote["pending"])
        let localPendingSet = Set(localPending)
        let remotePendingSet = Set(remotePending)
        var mergedPending: [String] = []
        var seenPending: Set<String> = []

        for key in localPending + remotePending {
            guard seenPending.insert(key).inserted else { continue }
            let inLocal = localPendingSet.contains(key)
            let inRemote = remotePendingSet.contains(key)
            if inLocal && inRemote {
                mergedPending.append(key)
            } else if inLocal {
                // 仅本地待确认：若云端有该规则且已人工确认或云端版本胜出且未标 pending，则视为云端已确认
                let remoteResolved = (remoteOverrides[key]?["isManuallyConfirmed"] as? Bool == true)
                    || (remoteOverrides[key] != nil && remoteWonOverrideKeys.contains(key))
                if !remoteResolved {
                    mergedPending.append(key)
                }
            } else {
                // 仅云端待确认：若本地有该规则且已人工确认或本地版本胜出且未标 pending，则视为本地已确认
                let localResolved = (localOverrides[key]?["isManuallyConfirmed"] as? Bool == true)
                    || (localOverrides[key] != nil && localWonOverrideKeys.contains(key))
                if !localResolved {
                    mergedPending.append(key)
                }
            }
        }

        // 6. 合并 history（去重合并，保留本地最近撤销栈在末尾，上限 30）
        let localHistory = extractAnyArray(local["history"])
        let remoteHistory = extractAnyArray(remote["history"])
        let mergedHistory = mergeHistoryArrays(local: localHistory, remote: remoteHistory)

        // 7. 标量与未知顶层扩展字段无损合并
        let localSchema = (local["schemaVersion"] as? Int) ?? 2
        let remoteSchema = (remote["schemaVersion"] as? Int) ?? 2
        let schemaVersion = max(max(localSchema, remoteSchema), JournalDatabase.currentSchemaVersion)

        let localDup = (local["duplicates"] as? Int) ?? 0
        let remoteDup = (remote["duplicates"] as? Int) ?? 0
        let localSkip = (local["skipped"] as? Int) ?? 0
        let remoteSkip = (remote["skipped"] as? Int) ?? 0
        let localLastSync = (local["lastSync"] as? Double) ?? 0
        let remoteLastSync = (remote["lastSync"] as? Double) ?? 0

        var mergedRoot: [String: Any] = [
            "schemaVersion": schemaVersion,
            "entries": sortedEntries,
            "duplicates": max(localDup, remoteDup),
            "skipped": max(localSkip, remoteSkip),
            "lastSync": max(localLastSync, remoteLastSync),
            "overrides": mergedOverrides,
            "pending": mergedPending,
            "history": mergedHistory
        ]
        if !mergedDeletedSources.isEmpty {
            mergedRoot["deletedSourceIDs"] = mergedDeletedSources
        }
        if !mergedDeletedEntries.isEmpty {
            mergedRoot["deletedEntryIds"] = mergedDeletedEntries
        }

        // 保留并双向合并所有未知顶层扩展字段（绝不丢弃任何一端特有字段）
        let unknownKeys = Set(local.keys).union(remote.keys).subtracting(coreTopLevelKeys)
        let remoteIsNewerFile = (remoteMtimeMs ?? 0) > (localMtimeMs ?? 0)
        for key in unknownKeys {
            switch (local[key], remote[key]) {
            case (let lv?, nil):
                mergedRoot[key] = lv
            case (nil, let rv?):
                mergedRoot[key] = rv
            case (let lv?, let rv?):
                if let lDict = lv as? [String: Any], let rDict = rv as? [String: Any] {
                    mergedRoot[key] = mergeUnknownDictionaries(
                        local: lDict,
                        remote: rDict,
                        remoteIsNewer: remoteIsNewerFile
                    )
                } else {
                    mergedRoot[key] = remoteIsNewerFile ? rv : lv
                }
            case (nil, nil):
                break
            }
        }

        output.mergedObject = mergedRoot
        output.localDidChange = !localExists || !databasesSemanticallyEqual(local, mergedRoot)
        output.remoteDidChange = !remoteExists || !databasesSemanticallyEqual(remote, mergedRoot)
        if !remoteExists && localExists {
            output.entriesPushed = sortedEntries.count
            output.rulesPushed = mergedOverrides.count
        }
        return output
    }

    // MARK: - CustomLogos/ 双向增量同步

    static func syncCustomLogos(
        localDataDir: URL,
        cloudSyncDir: URL
    ) -> (pulled: Int, pushed: Int) {
        let localLogosDir = localDataDir.appendingPathComponent("CustomLogos", isDirectory: true)
        let remoteLogosDir = cloudSyncDir.appendingPathComponent("CustomLogos", isDirectory: true)

        let localFiles = scanLogoFilesByStem(in: localLogosDir)
        let remoteFiles = scanLogoFilesByStem(in: remoteLogosDir)

        guard !localFiles.isEmpty || !remoteFiles.isEmpty else {
            return (0, 0)
        }

        var pulled = 0
        var pushed = 0
        let allStems = Set(localFiles.keys).union(remoteFiles.keys)

        for stem in allStems {
            switch (localFiles[stem], remoteFiles[stem]) {
            case (let localFile?, nil):
                if copyLogoAtomically(from: localFile.url, toDir: remoteLogosDir, replacingStem: stem) {
                    pushed += 1
                }
            case (nil, let remoteFile?):
                if copyLogoAtomically(from: remoteFile.url, toDir: localLogosDir, replacingStem: stem) {
                    pulled += 1
                }
            case (let localFile?, let remoteFile?):
                guard let localData = try? Data(contentsOf: localFile.url),
                      let remoteData = try? Data(contentsOf: remoteFile.url) else {
                    continue
                }
                if localData == remoteData {
                    continue
                }
                // 仅当修改时间差超过 1 秒时覆盖较旧一侧，避免云盘文件系统时间戳精度误差导致来回同步
                if remoteFile.mtimeMs > localFile.mtimeMs + 1000 {
                    if copyLogoAtomically(from: remoteFile.url, toDir: localLogosDir, replacingStem: stem) {
                        pulled += 1
                    }
                } else if localFile.mtimeMs > remoteFile.mtimeMs + 1000 {
                    if copyLogoAtomically(from: localFile.url, toDir: remoteLogosDir, replacingStem: stem) {
                        pushed += 1
                    }
                }
            case (nil, nil):
                break
            }
        }

        return (pulled, pushed)
    }

    private struct LogoFileRecord {
        let url: URL
        let mtimeMs: Int64
    }

    private static func scanLogoFilesByStem(in dir: URL) -> [String: LogoFileRecord] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return [:]
        }

        var map: [String: LogoFileRecord] = [:]
        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || name.hasSuffix(".tmp") { continue }
            let ext = url.pathExtension.lowercased()
            guard logoExtensions.contains(ext) else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  vals.isRegularFile == true,
                  let size = vals.fileSize, size > 0, UInt64(size) <= maxLogoBytes else {
                continue
            }
            let stem = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !stem.isEmpty else { continue }
            let mtimeMs = Int64(((vals.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000.0).rounded())
            if let existing = map[stem], existing.mtimeMs >= mtimeMs {
                continue
            }
            map[stem] = LogoFileRecord(url: url, mtimeMs: mtimeMs)
        }
        return map
    }

    private static func copyLogoAtomically(from sourceURL: URL, toDir targetDir: URL, replacingStem stem: String) -> Bool {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else { return false }
        let targetURL = targetDir.appendingPathComponent(sourceURL.lastPathComponent)
        do {
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
            try JournalRepository.atomicWriteData(data, to: targetURL)
            // 清理同 stem 不同扩展名的旧图标，避免双端扩展名不同导致冲突
            if let existing = try? fm.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for file in existing {
                    let s = file.deletingPathExtension().lastPathComponent.lowercased()
                    if s == stem && file.standardizedFileURL != targetURL.standardizedFileURL {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - 合并算法辅助函数

    private static func emptyDatabaseObject() -> [String: Any] {
        [
            "schemaVersion": JournalDatabase.currentSchemaVersion,
            "entries": [],
            "duplicates": 0,
            "skipped": 0,
            "lastSync": Date().timeIntervalSinceReferenceDate,
            "overrides": [:],
            "pending": [],
            "history": []
        ]
    }

    private static func fileModificationEpochMillis(_ url: URL) -> Int64? {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            return nil
        }
        return Int64((date.timeIntervalSince1970 * 1000.0).rounded())
    }

    private static func extractStringMap(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out[k] = s
            }
        }
        return out
    }

    private static func extractStringArray(_ raw: Any?) -> [String] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    private static func extractObjectArray(_ raw: Any?) -> [[String: Any]] {
        guard let arr = raw as? [Any] else { return [] }
        return arr.compactMap { $0 as? [String: Any] }
    }

    private static func extractObjectMap(_ raw: Any?) -> [String: [String: Any]] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (k, v) in dict {
            if let obj = v as? [String: Any] {
                out[k] = obj
            }
        }
        return out
    }

    private static func extractAnyArray(_ raw: Any?) -> [Any] {
        (raw as? [Any]) ?? []
    }

    private static func mergeDeletedEntryMap(local: [String: String], remote: [String: String]) -> [String: String] {
        var merged = local
        for (id, remoteTS) in remote {
            if let localTS = merged[id] {
                let lMs = SyncTimestamp.parseISO8601EpochMillis(localTS) ?? 0
                let rMs = SyncTimestamp.parseISO8601EpochMillis(remoteTS) ?? 0
                if rMs > lMs || (rMs == lMs && remoteTS > localTS) {
                    merged[id] = remoteTS
                }
            } else {
                merged[id] = remoteTS
            }
        }
        return merged
    }

    private static func shouldEntryReviveOverTombstone(entry: [String: Any], deletedISO: String) -> Bool {
        guard let updatedStr = entry["updatedAt"] as? String,
              let updatedMs = SyncTimestamp.parseISO8601EpochMillis(updatedStr),
              let deletedMs = SyncTimestamp.parseISO8601EpochMillis(deletedISO) else {
            return false
        }
        return updatedMs > deletedMs
    }

    private static func indexEntriesByID(_ entries: [[String: Any]], fallbackMtimeMs: Int64?) -> [String: [String: Any]] {
        var map: [String: [String: Any]] = [:]
        for entry in entries {
            guard let id = entry["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if let existing = map[id] {
                let (chosen, _) = resolveEntryConflict(
                    local: existing,
                    localMtimeMs: fallbackMtimeMs,
                    remote: entry,
                    remoteMtimeMs: fallbackMtimeMs
                )
                map[id] = chosen
            } else {
                map[id] = entry
            }
        }
        return map
    }

    private static func resolveEntryConflict(
        local: [String: Any],
        localMtimeMs: Int64?,
        remote: [String: Any],
        remoteMtimeMs: Int64?
    ) -> (merged: [String: Any], remoteWon: Bool) {
        let lExplicit = SyncTimestamp.parseISO8601EpochMillis(local["updatedAt"] as? String)
        let rExplicit = SyncTimestamp.parseISO8601EpochMillis(remote["updatedAt"] as? String)

        let remoteWins: Bool
        switch (lExplicit, rExplicit) {
        case (let l?, let r?):
            if l != r {
                remoteWins = r > l
            } else {
                remoteWins = entryNonEmptyScore(remote) > entryNonEmptyScore(local)
            }
        case (nil, .some):
            remoteWins = true
        case (.some, nil):
            remoteWins = false
        case (nil, nil):
            let lMtime = localMtimeMs ?? 0
            let rMtime = remoteMtimeMs ?? 0
            if abs(rMtime - lMtime) > 1000 {
                remoteWins = rMtime > lMtime
            } else {
                remoteWins = entryNonEmptyScore(remote) > entryNonEmptyScore(local)
            }
        }

        var winner = remoteWins ? remote : local
        let loser = remoteWins ? local : remote

        // 保留败方的未知扩展字段与缺失的 sourceFingerprint
        for (k, v) in loser where winner[k] == nil {
            if k == "updatedAt" { continue }
            winner[k] = v
        }
        if winner["updatedAt"] == nil, let loserUpdated = loser["updatedAt"] {
            winner["updatedAt"] = loserUpdated
        }

        return (winner, remoteWins)
    }

    private static func resolveOverrideConflict(
        local: [String: Any],
        localMtimeMs: Int64?,
        remote: [String: Any],
        remoteMtimeMs: Int64?
    ) -> (merged: [String: Any], remoteWon: Bool) {
        let lExplicit = SyncTimestamp.parseISO8601EpochMillis(local["updatedAt"] as? String)
        let rExplicit = SyncTimestamp.parseISO8601EpochMillis(remote["updatedAt"] as? String)
        let lManual = (local["isManuallyConfirmed"] as? Bool) == true
        let rManual = (remote["isManuallyConfirmed"] as? Bool) == true

        let remoteWins: Bool
        switch (lExplicit, rExplicit) {
        case (let l?, let r?):
            if l != r {
                remoteWins = r > l
            } else if lManual != rManual {
                remoteWins = rManual
            } else {
                remoteWins = overrideNonEmptyScore(remote) > overrideNonEmptyScore(local)
            }
        case (nil, .some):
            remoteWins = true
        case (.some, nil):
            remoteWins = false
        case (nil, nil):
            if lManual != rManual {
                remoteWins = rManual
            } else {
                let lMtime = localMtimeMs ?? 0
                let rMtime = remoteMtimeMs ?? 0
                if abs(rMtime - lMtime) > 1000 {
                    remoteWins = rMtime > lMtime
                } else {
                    remoteWins = overrideNonEmptyScore(remote) > overrideNonEmptyScore(local)
                }
            }
        }

        var winner = remoteWins ? remote : local
        let loser = remoteWins ? local : remote

        let winnerHasExplicitTime = SyncTimestamp.parseISO8601EpochMillis(winner["updatedAt"] as? String) != nil
        for (k, v) in loser {
            if k == "updatedAt" { continue }
            let winnerMissing: Bool
            if let existing = winner[k] {
                if let str = existing as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    winnerMissing = true
                } else {
                    winnerMissing = existing is NSNull
                }
            } else {
                winnerMissing = true
            }
            let isKnownOverrideKey: Bool = [
                "brand", "name", "model", "razorType", "isAdjustable", "isSlant",
                "material", "plateType", "gapOrSpec", "bladeType", "handleBrand",
                "knotBrand", "brushMaterial", "badgerTreatment", "badgerBand",
                "knotSize", "knotShape", "isSample", "status", "notes",
                "recognizedSource", "isManuallyConfirmed", "updatedAt"
            ].contains(k)

            // 未知扩展字段永远保留；若胜方为无 updatedAt 的旧版数据，则同时用另一侧非空字段兜底补全
            if winnerMissing && (!isKnownOverrideKey || !winnerHasExplicitTime) {
                winner[k] = v
            }
        }

        return (winner, remoteWins)
    }

    private static func entryNonEmptyScore(_ entry: [String: Any]) -> Int {
        var score = 0
        if let fields = entry["fields"] as? [[String: Any]] {
            for f in fields {
                let val = (f["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !val.isEmpty && val != "无" && val != "-" {
                    score += 1
                }
            }
        }
        return score
    }

    private static func overrideNonEmptyScore(_ ov: [String: Any]) -> Int {
        var score = 0
        for (k, v) in ov where k != "updatedAt" {
            if let s = v as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed != "品牌未注明" && trimmed != "无品牌" {
                    score += 1
                }
            } else if let b = v as? Bool, b {
                score += 1
            } else if !(v is NSNull) {
                score += 1
            }
        }
        return score
    }

    /// 日期 + 核心器材指纹（用于跨端不同 UUID 录入同一场剃须时防重）
    private static func coreGearFingerprint(for entry: [String: Any]) -> String? {
        let date = ((entry["date"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !date.isEmpty, let fields = entry["fields"] as? [[String: Any]] else { return nil }

        func norm(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        var razors: [String] = []
        var blades: [String] = []
        var brushes: [String] = []
        var soaps: [String] = []

        for f in fields {
            let label = ((f["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let val = norm((f["value"] as? String) ?? "")
            guard !val.isEmpty, val != "无", val != "-" else { continue }
            if label == "剃须刀" || (label.hasPrefix("剃须刀") && label.dropFirst(3).allSatisfy(\.isNumber)) {
                razors.append(val)
            } else if label == "刀片" || (label.hasPrefix("刀片") && label.dropFirst(2).allSatisfy(\.isNumber)) {
                blades.append(val)
            } else if label == "剃须刷" {
                brushes.append(val)
            } else if label == "剃须皂" {
                soaps.append(val)
            }
        }

        let nonEmptyGroups = [!razors.isEmpty, !blades.isEmpty, !brushes.isEmpty, !soaps.isEmpty].filter { $0 }.count
        guard nonEmptyGroups >= 2 else { return nil }

        let canonical = [
            date,
            razors.sorted().joined(separator: "+"),
            blades.sorted().joined(separator: "+"),
            brushes.sorted().joined(separator: "+"),
            soaps.sorted().joined(separator: "+")
        ].joined(separator: "\u{1F}")
        return StableHash.fnv1a64Hex(canonical)
    }

    private static func extractProcessText(_ entry: [String: Any]) -> String {
        guard let fields = entry["fields"] as? [[String: Any]] else { return "" }
        for f in fields {
            if ((f["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)) == "过程" {
                return ((f["value"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func areProcessTextsCompatible(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        let pa = extractProcessText(a)
        let pb = extractProcessText(b)
        return pa.isEmpty || pb.isEmpty || pa == pb
    }

    private static func pickCanonicalDuplicateID(_ a: String, _ b: String) -> String {
        let aLocal = a.hasPrefix("local-")
        let bLocal = b.hasPrefix("local-")
        if aLocal != bLocal {
            return aLocal ? b : a
        }
        return min(a, b)
    }

    private static func mergeHistoryArrays(local: [Any], remote: [Any]) -> [Any] {
        var result: [Any] = []
        var seen: Set<String> = []

        // 远端未见快照放前面，本地快照放末尾，确保当前设备撤销优先回退本地最近操作
        for item in remote + local {
            guard let key = canonicalJSONString(item) else { continue }
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        if result.count > maxHistoryDepth {
            result = Array(result.suffix(maxHistoryDepth))
        }
        return result
    }

    private static func mergeUnknownDictionaries(
        local: [String: Any],
        remote: [String: Any],
        remoteIsNewer: Bool
    ) -> [String: Any] {
        var merged = local
        for (k, rv) in remote {
            if let lv = merged[k] {
                if let lSub = lv as? [String: Any], let rSub = rv as? [String: Any] {
                    merged[k] = mergeUnknownDictionaries(local: lSub, remote: rSub, remoteIsNewer: remoteIsNewer)
                } else if remoteIsNewer {
                    merged[k] = rv
                }
            } else {
                merged[k] = rv
            }
        }
        return merged
    }

    private static func canonicalJSONString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        canonicalJSONString(lhs) == canonicalJSONString(rhs)
    }

    private static func databasesSemanticallyEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        var a = lhs
        var b = rhs
        a.removeValue(forKey: "lastSync")
        b.removeValue(forKey: "lastSync")
        if (a["deletedSourceIDs"] as? [Any])?.isEmpty == true { a.removeValue(forKey: "deletedSourceIDs") }
        if (b["deletedSourceIDs"] as? [Any])?.isEmpty == true { b.removeValue(forKey: "deletedSourceIDs") }
        if (a["deletedEntryIds"] as? [String: Any])?.isEmpty == true { a.removeValue(forKey: "deletedEntryIds") }
        if (b["deletedEntryIds"] as? [String: Any])?.isEmpty == true { b.removeValue(forKey: "deletedEntryIds") }
        return jsonObjectsEqual(a, b)
    }
}
