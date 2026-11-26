import Foundation

enum JournalPersistenceError: LocalizedError {
    case readOnlyProtected
    case cloudDirectoryUnavailable(String)
    case backupFailed(Error)
    case backupVerificationFailed(String)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .readOnlyProtected:
            return L10n.t(
                "当前处于只读保护状态，已阻止写入以保护原 journal.json",
                "Read-only protection active: write blocked to protect journal.json."
            )
        case .cloudDirectoryUnavailable(let path):
            return L10n.t(
                "云盘数据目录当前不可访问（\(path)），请确认 Google Drive 已启动并挂载后重试",
                "Cloud data directory is currently unavailable (\(path)). Make sure Google Drive is running and mounted."
            )
        case .backupFailed(let err):
            return L10n.t(
                "创建备份失败，操作已中止：\(err.localizedDescription)",
                "Backup failed; operation aborted: \(err.localizedDescription)"
            )
        case .backupVerificationFailed(let reason):
            return L10n.t(
                "备份校验失败，操作已中止：\(reason)",
                "Backup verification failed; operation aborted: \(reason)"
            )
        case .writeFailed(let err):
            return L10n.t(
                "保存 journal.json 失败：\(err.localizedDescription)",
                "Failed to save journal.json: \(err.localizedDescription)"
            )
        }
    }
}

/// 负责 journal.json 的磁盘读写、原子写入、独立校验备份与备份保留策略（支持本机与 Google Drive 云盘目录）
final class JournalRepository {
    static let dataDirectoryDefaultsKey = "WetShaveJournal.DataDirectoryPath"

    let dataDirectoryURL: URL
    let journalFileURL: URL
    let backupsDirectoryURL: URL
    /// 当使用 CloudStorage 云盘路径时要求挂载目录已存在，防止云盘未挂载时静默创建空库
    let requireMountedCloudRoot: Bool

    private static let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS"
        return f
    }()

    static func defaultAppSupportDirectory() -> URL {
        let fm = FileManager.default
        if let envDir = ProcessInfo.processInfo.environment["WSJ_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envDir.isEmpty {
            return URL(fileURLWithPath: envDir, isDirectory: true)
        }
        if let savedPath = UserDefaults.standard.string(forKey: dataDirectoryDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !savedPath.isEmpty {
            return URL(fileURLWithPath: savedPath, isDirectory: true)
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let localDir = appSupport.appendingPathComponent("WetShaveJournal", isDirectory: true)
        if fm.fileExists(atPath: localDir.appendingPathComponent("journal.json").path) {
            return localDir
        }

        // 若本地无数据但 Google Drive 存在已迁移的 WetShaveJournal_Backup/Data/journal.json，自动发现并挂载
        let cloudStorage = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        if let drives = try? fm.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for drive in drives where drive.lastPathComponent.hasPrefix("GoogleDrive-") {
                for driveName in ["我的云端硬盘", "My Drive"] {
                    let candidate = drive
                        .appendingPathComponent(driveName, isDirectory: true)
                        .appendingPathComponent("WetShaveJournal_Backup/Data", isDirectory: true)
                    if fm.fileExists(atPath: candidate.appendingPathComponent("journal.json").path) {
                        return candidate
                    }
                }
            }
        }
        return localDir
    }

    init(
        dataDirectoryURL: URL = JournalRepository.defaultAppSupportDirectory(),
        requireMountedCloudRoot: Bool? = nil
    ) {
        self.dataDirectoryURL = dataDirectoryURL
        self.journalFileURL = dataDirectoryURL.appendingPathComponent("journal.json")
        self.backupsDirectoryURL = dataDirectoryURL.appendingPathComponent("Backups", isDirectory: true)
        self.requireMountedCloudRoot = requireMountedCloudRoot ?? dataDirectoryURL.path.contains("/Library/CloudStorage/")
    }

    /// 读取并解码 journal.json；若文件尚未创建返回 nil；若损坏/云盘未挂载抛出错误供上层进入只读保护
    func load() throws -> JournalDatabase? {
        let fm = FileManager.default
        if requireMountedCloudRoot && !fm.fileExists(atPath: dataDirectoryURL.path) {
            throw JournalPersistenceError.cloudDirectoryUnavailable(dataDirectoryURL.path)
        }
        try fm.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: journalFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: journalFileURL)
        var decoded = try JSONDecoder().decode(JournalDatabase.self, from: data)
        decoded.entries.sort { $0.date > $1.date }
        return decoded
    }

    /// 同目录临时文件 + 落盘刷新 + 原子替换，确保本地与云盘写入不会出现半截损坏文件
    static func atomicWriteData(_ data: Data, to targetURL: URL) throws {
        let fm = FileManager.default
        let parentDir = targetURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let shortID = String(UUID().uuidString.prefix(10)).lowercased()
        let tmpURL = parentDir.appendingPathComponent(".\(targetURL.lastPathComponent).\(shortID).tmp")

        do {
            try data.write(to: tmpURL, options: [.withoutOverwriting])
            if let handle = try? FileHandle(forWritingTo: tmpURL) {
                try? handle.synchronize()
                try? handle.close()
            }
            if fm.fileExists(atPath: targetURL.path) {
                _ = try fm.replaceItemAt(targetURL, withItemAt: tmpURL, backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: tmpURL, to: targetURL)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }
    }

    /// 原子持久化数据库；高风险操作可要求先创建并回读校验独立备份，同时无损保留磁盘上可能存在的未知顶层扩展字段
    func persist(_ candidate: JournalDatabase, createBackup: Bool, isReadOnlyProtected: Bool) throws {
        guard !isReadOnlyProtected else {
            throw JournalPersistenceError.readOnlyProtected
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw JournalPersistenceError.writeFailed(error)
        }

        if createBackup {
            try createVerifiedBackup(fallbackDatabase: candidate)
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var toEncode = candidate
            toEncode.schemaVersion = JournalDatabase.currentSchemaVersion
            var data = try encoder.encode(toEncode)

            // 若磁盘已有合法 journal.json 且包含未知顶层扩展字段，则无损合并保留
            if fm.fileExists(atPath: journalFileURL.path),
               let existingData = try? Data(contentsOf: journalFileURL),
               let existingObj = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] {
                let unknownPairs = existingObj.filter { !JournalDatabase.knownTopLevelKeys.contains($0.key) }
                if !unknownPairs.isEmpty,
                   var encodedObj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    for (k, v) in unknownPairs where encodedObj[k] == nil {
                        encodedObj[k] = v
                    }
                    data = try JSONSerialization.data(withJSONObject: encodedObj, options: [.sortedKeys])
                }
            }

            try Self.atomicWriteData(data, to: journalFileURL)
        } catch {
            throw JournalPersistenceError.writeFailed(error)
        }
    }

    /// 创建并校验一份独立备份（毫秒时间戳 + 短 UUID，写入后校验可读且可 JSON 解码；清理旧备份时绝不删除最后一份有效备份）
    @discardableResult
    func createVerifiedBackup(fallbackDatabase: JournalDatabase, maxKeepCount: Int = 30) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: backupsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw JournalPersistenceError.backupFailed(error)
        }

        let sourceData: Data
        if fm.fileExists(atPath: journalFileURL.path) {
            do {
                sourceData = try Data(contentsOf: journalFileURL)
            } catch {
                throw JournalPersistenceError.backupFailed(error)
            }
        } else {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                sourceData = try encoder.encode(fallbackDatabase)
            } catch {
                throw JournalPersistenceError.backupFailed(error)
            }
        }

        let ts = Self.backupTimestampFormatter.string(from: Date())
        let shortUUID = String(UUID().uuidString.prefix(8)).lowercased()
        let backupURL = backupsDirectoryURL.appendingPathComponent("journal_auto_\(ts)_\(shortUUID).json")

        do {
            try sourceData.write(to: backupURL, options: .atomic)
        } catch {
            throw JournalPersistenceError.backupFailed(error)
        }

        let verifiedData: Data
        do {
            verifiedData = try Data(contentsOf: backupURL)
        } catch {
            try? fm.removeItem(at: backupURL)
            throw JournalPersistenceError.backupVerificationFailed(error.localizedDescription)
        }

        guard !verifiedData.isEmpty else {
            try? fm.removeItem(at: backupURL)
            throw JournalPersistenceError.backupVerificationFailed(L10n.t("备份文件为空", "Backup file is empty"))
        }

        do {
            _ = try JSONDecoder().decode(JournalDatabase.self, from: verifiedData)
        } catch {
            try? fm.removeItem(at: backupURL)
            throw JournalPersistenceError.backupVerificationFailed(
                L10n.t("备份 JSON 校验失败：\(error.localizedDescription)", "Backup JSON decode failed: \(error.localizedDescription)")
            )
        }

        pruneBackupsSafely(maxKeepCount: maxKeepCount, protectedValidURL: backupURL)
        return backupURL
    }

    /// 清理超额旧备份：始终保留最新有效备份，且永远不会删除最后一份有效备份
    func pruneBackupsSafely(maxKeepCount: Int, protectedValidURL: URL) {
        let fm = FileManager.default
        guard maxKeepCount >= 1,
              let entries = try? fm.contentsOfDirectory(
                at: backupsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        let candidates = entries
            .filter { $0.lastPathComponent.hasPrefix("journal_auto_") && $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if d1 != d2 { return d1 > d2 }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }

        guard candidates.count > maxKeepCount else { return }

        func isValidBackup(_ url: URL) -> Bool {
            if url.standardizedFileURL == protectedValidURL.standardizedFileURL { return true }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
            return (try? JSONDecoder().decode(JournalDatabase.self, from: data)) != nil
        }

        var remainingValidCount = candidates.filter(isValidBackup).count
        let toConsiderRemoving = candidates.dropFirst(maxKeepCount)
        for oldURL in toConsiderRemoving {
            if oldURL.standardizedFileURL == protectedValidURL.standardizedFileURL { continue }
            let valid = isValidBackup(oldURL)
            if valid && remainingValidCount <= 1 {
                continue
            }
            if (try? fm.removeItem(at: oldURL)) != nil, valid {
                remainingValidCount -= 1
            }
        }
    }
}
