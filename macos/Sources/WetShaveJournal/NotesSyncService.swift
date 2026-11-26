import Foundation

struct RawAppleNote: Decodable, Equatable {
    let id: String
    let title: String
    let body: String
}

enum NotesSyncError: LocalizedError {
    case scriptNotFound
    case timeout
    case cancelled
    case permissionDenied(String)
    case scriptFailed(Int32, String)
    case launchFailed(Error)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return L10n.t("未找到备忘录脚本 read-notes.js", "read-notes.js not found")
        case .timeout:
            return L10n.t(
                "读取备忘录超时（超过 30 秒），请确认「备忘录」App 响应正常后重试",
                "Apple Notes sync timed out after 30 seconds. Make sure Notes is responsive and try again."
            )
        case .cancelled:
            return L10n.t("备忘录同步已取消", "Apple Notes sync was cancelled")
        case .permissionDenied:
            return L10n.t(
                "未获得控制「备忘录」权限，请前往「系统设置 → 隐私与安全性 → 自动化」开启「WetShaveJournal」的备忘录权限",
                "Automation permission denied. Go to System Settings → Privacy & Security → Automation and allow Notes access for WetShaveJournal."
            )
        case .scriptFailed(let code, let detail):
            let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                return L10n.t("脚本异常退出（退出码 \(code)）", "Script exited with code \(code)")
            }
            return clean
        case .launchFailed(let error):
            return error.localizedDescription
        case .invalidJSON:
            return L10n.t("解析备忘录数据失败，未修改现有日记", "Failed to parse Apple Notes data; existing entries kept intact")
        }
    }
}

struct NotesSyncPlan {
    var database: JournalDatabase
    var added: Int = 0
    var updatedFromSource: Int = 0
    var skippedLocalModified: Int = 0
    var conflictCount: Int = 0
    var skippedDeletedTombstone: Int = 0
    var suspectedDuplicateCount: Int = 0
    var removedSameIDDuplicates: Int = 0

    var hasDataChanges: Bool {
        added > 0 || updatedFromSource > 0 || conflictCount > 0 || removedSameIDDuplicates > 0
    }

    var shouldBackup: Bool {
        added > 0 || updatedFromSource > 0 || removedSameIDDuplicates > 0
    }

    func summaryToast(totalCount: Int) -> String {
        var partsZH: [String] = []
        var partsEN: [String] = []

        partsZH.append("新增 \(added) 篇")
        partsEN.append("\(added) added")

        if updatedFromSource > 0 {
            partsZH.append("更新 \(updatedFromSource) 篇")
            partsEN.append("\(updatedFromSource) updated")
        }
        if conflictCount > 0 {
            partsZH.append("冲突保留本地 \(conflictCount) 篇")
            partsEN.append("\(conflictCount) conflict(s) kept local")
        }
        let nonConflictSkipped = max(0, skippedLocalModified - conflictCount)
        if nonConflictSkipped > 0 {
            partsZH.append("跳过本地修改 \(nonConflictSkipped) 篇")
            partsEN.append("\(nonConflictSkipped) local kept")
        }
        if suspectedDuplicateCount > 0 {
            partsZH.append("标记疑似重复 \(suspectedDuplicateCount) 篇")
            partsEN.append("\(suspectedDuplicateCount) suspected duplicate(s) flagged")
        }
        if skippedDeletedTombstone > 0 {
            partsZH.append("跳过已删 \(skippedDeletedTombstone) 篇")
            partsEN.append("\(skippedDeletedTombstone) deleted skipped")
        }
        if removedSameIDDuplicates > 0 {
            partsZH.append("合并同 ID 重复 \(removedSameIDDuplicates) 篇")
            partsEN.append("\(removedSameIDDuplicates) same-ID duplicate(s) merged")
        }

        return L10n.t(
            "同步完成：\(partsZH.joined(separator: "、"))（共 \(totalCount) 篇）",
            "Synced: \(partsEN.joined(separator: ", ")) (\(totalCount) total)"
        )
    }
}

/// Apple 备忘录同步服务（S01 / S04 / S05）：
/// - 稳定来源 ID 主键区分同步更新与不同真实日记，绝不凭“同日/同器材/同过程”自动删除不同 ID 记录
/// - 基于 sourceFingerprint + locallyModified 实现三方冲突检测（仅源变更新、仅本地变保留、双边变保留本地并标冲突、旧无基准保守保留）
/// - 对用户在 App 内主动删除的来源 ID 记录 tombstone，正常同步不复活，并支持显式恢复重新导入
enum NotesSyncService {
    private static let rowRegex = try! NSRegularExpression(pattern: #"(?is)<tr[^>]*>(.*?)</tr>"#)
    private static let cellRegex = try! NSRegularExpression(pattern: #"(?is)<t[dh][^>]*>(.*?)</t[dh]>"#)
    private static let htmlTagRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    private static let isoDateRegex = try! NSRegularExpression(pattern: #"(\d{4})[-/\.](\d{1,2})[-/\.](\d{1,2})"#)

    /// 纯函数三方同步规划器（无外部进程与文件 I/O，支持完整单元测试）
    static func planSync(
        notes: [RawAppleNote],
        into currentDB: JournalDatabase,
        allowReimportDeleted: Bool = false
    ) -> NotesSyncPlan {
        var candidate = currentDB
        var plan = NotesSyncPlan(database: candidate)

        var deletedSet = Set(candidate.deletedSourceIDs ?? [])
        if allowReimportDeleted {
            let incomingIDs = Set(notes.map(\.id))
            deletedSet.subtract(incomingIDs)
            if var entryTombstones = candidate.deletedEntryIds {
                for id in incomingIDs {
                    entryTombstones.removeValue(forKey: id)
                }
                candidate.deletedEntryIds = entryTombstones.isEmpty ? nil : entryTombstones
            }
        }

        // 仅清理历史上确属「同一稳定 ID 且全字段完全一致」的内部重复，绝不触碰不同 ID 或存在差异的记录（S01）
        var seenExactByID: [String: String] = [:]
        var dedupedEntries: [JournalEntry] = []
        dedupedEntries.reserveCapacity(candidate.entries.count)
        for entry in candidate.entries {
            let fp = entry.fullBusinessFingerprint
            if let existingFP = seenExactByID[entry.id], existingFP == fp {
                plan.removedSameIDDuplicates += 1
                continue
            }
            seenExactByID[entry.id] = fp
            dedupedEntries.append(entry)
        }
        candidate.entries = dedupedEntries

        var indexByID: [String: Int] = Dictionary(
            candidate.entries.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        var existingFullFingerprints: Set<String> = Set(candidate.entries.map(\.fullBusinessFingerprint))

        for note in notes {
            // S05：仅按稳定来源 ID 过滤已主动删除的记录，绝不按日期或器材名屏蔽不相关日记
            if !allowReimportDeleted && deletedSet.contains(note.id) {
                plan.skippedDeletedTombstone += 1
                continue
            }

            guard var parsed = parseNoteHTML(id: note.id, title: note.title, html: note.body) else { continue }
            let noteFingerprint = parsed.contentFingerprint
            parsed.sourceFingerprint = noteFingerprint
            parsed.locallyModified = false
            parsed.hasSyncConflict = nil

            if let idx = indexByID[parsed.id] {
                let existing = candidate.entries[idx]

                if existing.contentFingerprint == noteFingerprint {
                    // 无实质变化：补齐历史记录缺失的来源指纹基准，清除旧冲突标记
                    if existing.sourceFingerprint == nil {
                        candidate.entries[idx].sourceFingerprint = noteFingerprint
                    }
                    if existing.hasSyncConflict == true {
                        candidate.entries[idx].hasSyncConflict = nil
                    }
                    continue
                }

                // S04 三方合并判定
                guard let baseFingerprint = existing.sourceFingerprint else {
                    // 旧数据无 sourceFingerprint 基准：采用保守策略保留本地，不猜测谁先改
                    plan.skippedLocalModified += 1
                    continue
                }

                let sourceChanged = (baseFingerprint != noteFingerprint)
                let localChanged = (existing.locallyModified == true) || (existing.contentFingerprint != baseFingerprint)

                if sourceChanged && !localChanged {
                    // 仅来源改变：安全更新本地记录并刷新来源基准
                    candidate.entries[idx].date = parsed.date
                    candidate.entries[idx].fields = parsed.fields
                    candidate.entries[idx].sourceFingerprint = noteFingerprint
                    candidate.entries[idx].locallyModified = false
                    candidate.entries[idx].hasSyncConflict = nil
                    candidate.entries[idx].updatedAt = SyncTimestamp.nowISO8601()
                    plan.updatedFromSource += 1
                } else if !sourceChanged && localChanged {
                    // 仅本地改变：保留本地改动
                    plan.skippedLocalModified += 1
                } else if sourceChanged && localChanged {
                    // 双边同时改变：保留本地改动并显式标记冲突，绝不静默覆盖
                    candidate.entries[idx].hasSyncConflict = true
                    plan.conflictCount += 1
                    plan.skippedLocalModified += 1
                } else {
                    plan.skippedLocalModified += 1
                }
            } else {
                // 新来源 ID：绝不因为同日/同器材/同文本而删除或静默吞掉独立来源日记（S01）
                // 若与已有记录的全字段精确业务指纹完全一致，仍保留两条记录但显式标记疑似重复
                let fullFP = parsed.fullBusinessFingerprint
                if existingFullFingerprints.contains(fullFP) {
                    parsed.suspectedDuplicate = true
                    plan.suspectedDuplicateCount += 1
                }
                parsed.updatedAt = SyncTimestamp.nowISO8601()
                let newIdx = candidate.entries.count
                indexByID[parsed.id] = newIdx
                existingFullFingerprints.insert(fullFP)
                candidate.entries.append(parsed)
                plan.added += 1
            }
        }

        if allowReimportDeleted {
            candidate.deletedSourceIDs = deletedSet.isEmpty ? nil : Array(deletedSet).sorted()
        }

        if plan.added > 0 || plan.updatedFromSource > 0 || plan.removedSameIDDuplicates > 0 {
            candidate.entries.sort { $0.date > $1.date }
        }
        candidate.lastSync = Date().timeIntervalSinceReferenceDate
        plan.database = candidate
        return plan
    }

    /// 运行外部脚本（默认 /usr/bin/osascript -l JavaScript <scriptPath>），支持并发排空管道防 64KB 死锁、超时强杀与任务取消
    static func runProcess(
        executablePath: String = "/usr/bin/osascript",
        arguments: [String],
        timeoutSeconds: TimeInterval = 30
    ) async -> Result<String, NotesSyncError> {
        final class ProcessController: @unchecked Sendable {
            let lock = NSLock()
            var process: Process?
            var didTimeout = false
            var didCancel = false
            var didFinish = false

            func terminateForCancel() {
                lock.lock()
                guard !didFinish else {
                    lock.unlock()
                    return
                }
                didCancel = true
                let proc = process
                lock.unlock()
                Self.terminateProcess(proc)
            }

            static func terminateProcess(_ process: Process?) {
                guard let process = process, process.isRunning else { return }
                let pid = process.processIdentifier
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
        }

        let controller = ProcessController()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    if Task.isCancelled {
                        continuation.resume(returning: .failure(.cancelled))
                        return
                    }

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = arguments

                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    process.standardOutput = outPipe
                    process.standardError = errPipe

                    controller.lock.lock()
                    if controller.didCancel {
                        controller.lock.unlock()
                        try? outPipe.fileHandleForReading.close()
                        try? errPipe.fileHandleForReading.close()
                        continuation.resume(returning: .failure(.cancelled))
                        return
                    }
                    controller.process = process
                    controller.lock.unlock()

                    let timeoutTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timeoutTimer.schedule(deadline: .now() + timeoutSeconds)
                    timeoutTimer.setEventHandler {
                        controller.lock.lock()
                        guard !controller.didFinish else {
                            controller.lock.unlock()
                            return
                        }
                        controller.didTimeout = true
                        let proc = controller.process
                        controller.lock.unlock()
                        ProcessController.terminateProcess(proc)
                    }

                    do {
                        try process.run()
                    } catch {
                        timeoutTimer.cancel()
                        try? outPipe.fileHandleForReading.close()
                        try? errPipe.fileHandleForReading.close()
                        continuation.resume(returning: .failure(.launchFailed(error)))
                        return
                    }

                    timeoutTimer.resume()

                    // 必须在 waitUntilExit() 之前并发排空 stdout 和 stderr，彻底避免 64KB 管道缓冲死锁
                    let readGroup = DispatchGroup()
                    var outData = Data()
                    var errData = Data()

                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                        try? outPipe.fileHandleForReading.close()
                        readGroup.leave()
                    }

                    readGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        try? errPipe.fileHandleForReading.close()
                        readGroup.leave()
                    }

                    readGroup.wait()
                    process.waitUntilExit()

                    controller.lock.lock()
                    controller.didFinish = true
                    let timedOut = controller.didTimeout
                    let cancelled = controller.didCancel
                    controller.lock.unlock()
                    timeoutTimer.cancel()

                    if cancelled {
                        continuation.resume(returning: .failure(.cancelled))
                        return
                    }
                    if timedOut {
                        continuation.resume(returning: .failure(.timeout))
                        return
                    }

                    if process.terminationStatus != 0 {
                        let errStr = String(data: errData, encoding: .utf8) ?? ""
                        let lower = errStr.lowercased()
                        if errStr.contains("-1743")
                            || lower.contains("not authorized to send apple events")
                            || lower.contains("operation not permitted")
                            || errStr.contains("不允许发送 Apple 事件")
                            || errStr.contains("未被授权") {
                            continuation.resume(returning: .failure(.permissionDenied(errStr)))
                        } else {
                            continuation.resume(returning: .failure(.scriptFailed(process.terminationStatus, errStr)))
                        }
                        return
                    }

                    let outputString = String(data: outData, encoding: .utf8) ?? "[]"
                    continuation.resume(returning: .success(outputString))
                }
            }
        } onCancel: {
            controller.terminateForCancel()
        }
    }

    static func runAppleNotesScript(
        scriptPath: String,
        timeoutSeconds: TimeInterval = 30
    ) async -> Result<String, NotesSyncError> {
        await runProcess(
            executablePath: "/usr/bin/osascript",
            arguments: ["-l", "JavaScript", scriptPath],
            timeoutSeconds: timeoutSeconds
        )
    }

    static func parseNoteHTML(id: String, title: String, html: String) -> JournalEntry? {
        var fields: [JournalField] = []
        let rows = rowRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for r in rows {
            guard let rowRange = Range(r.range(at: 1), in: html) else { continue }
            let rowStr = String(html[rowRange])
            let cells = cellRegex.matches(in: rowStr, range: NSRange(rowStr.startIndex..., in: rowStr))
            if cells.count >= 2,
               let r1 = Range(cells[0].range(at: 1), in: rowStr),
               let r2 = Range(cells[1].range(at: 1), in: rowStr) {
                let label = cleanHTMLText(String(rowStr[r1]))
                let value = cleanHTMLText(String(rowStr[r2]))
                if !label.isEmpty {
                    fields.append(JournalField(label: label, value: value))
                }
            }
        }

        guard !fields.isEmpty else { return nil }
        let dateFromTitle = extractISODate(from: title)
        let dateFromField = extractISODate(from: fields.first(where: { $0.label == "日期" })?.value ?? "")
        let finalDate = dateFromTitle ?? dateFromField ?? JournalDateFormatter.isoDay.string(from: Date())
        return JournalEntry(id: id, date: finalDate, fields: fields)
    }

    private static func cleanHTMLText(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        let stripped = htmlTagRegex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractISODate(from text: String) -> String? {
        if let m = isoDateRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r1 = Range(m.range(at: 1), in: text),
           let r2 = Range(m.range(at: 2), in: text),
           let r3 = Range(m.range(at: 3), in: text),
           let y = Int(text[r1]), let mo = Int(text[r2]), let d = Int(text[r3]) {
            return String(format: "%04d-%02d-%02d", y, mo, d)
        }
        return nil
    }
}
