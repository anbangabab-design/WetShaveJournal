import XCTest
@testable import WetShaveJournal

@MainActor
final class NotesSyncTests: XCTestCase {

    private func makeHTMLTable(rows: [(String, String)]) -> String {
        let body = rows.map { "<tr><td>\($0.0)</td><td>\($0.1)</td></tr>" }.joined()
        return "<html><body><table>\(body)</table></body></html>"
    }

    func testS01NeverAutoDeletesDifferentIDEntriesOrDistinctSameDayShaves() {
        let htmlMorning = makeHTMLTable(rows: [
            ("日期", "2026-04-10"),
            ("剃须刀", "Blackland Blackbird Ti"),
            ("刀片", "Astra SP 1st"),
            ("剃须刷", "Oumo 26mm"),
            ("剃须皂", "MDC Absinthe"),
            ("起泡", "碗起"),
            ("是否热敷", "是"),
            ("过程", "顺横无痛BBS")
        ])
        let htmlEveningDifferentLather = makeHTMLTable(rows: [
            ("日期", "2026-04-10"),
            ("剃须刀", "Blackland Blackbird Ti"),
            ("刀片", "Astra SP 1st"),
            ("剃须刷", "Oumo 26mm"),
            ("剃须皂", "MDC Absinthe"),
            ("起泡", "脸起"),
            ("是否热敷", "否"),
            ("过程", "顺横无痛BBS")
        ])

        let initialDB = JournalDatabase()
        // 同日同器材但不同起泡/热敷
        let plan1 = NotesSyncService.planSync(
            notes: [
                RawAppleNote(id: "note-1", title: "SOTD 2026-04-10", body: htmlMorning),
                RawAppleNote(id: "note-2", title: "SOTD 2026-04-10", body: htmlEveningDifferentLather)
            ],
            into: initialDB
        )
        XCTAssertEqual(plan1.database.entries.count, 2)
        XCTAssertEqual(plan1.added, 2)
        XCTAssertEqual(plan1.suspectedDuplicateCount, 0)

        // 不同来源 ID 但全字段完全一致：绝不删除，保留两条并标记疑似重复
        let plan2 = NotesSyncService.planSync(
            notes: [
                RawAppleNote(id: "note-1", title: "SOTD 2026-04-10", body: htmlMorning),
                RawAppleNote(id: "note-2", title: "SOTD 2026-04-10", body: htmlEveningDifferentLather),
                RawAppleNote(id: "note-3-same-content", title: "SOTD 2026-04-10", body: htmlMorning)
            ],
            into: plan1.database
        )
        XCTAssertEqual(plan2.database.entries.count, 3)
        XCTAssertEqual(plan2.added, 1)
        XCTAssertEqual(plan2.suspectedDuplicateCount, 1)
        let flagged = plan2.database.entries.first(where: { $0.id == "note-3-same-content" })
        XCTAssertEqual(flagged?.suspectedDuplicate, true)

        // 重复同步幂等性
        let plan3 = NotesSyncService.planSync(
            notes: [
                RawAppleNote(id: "note-1", title: "SOTD 2026-04-10", body: htmlMorning),
                RawAppleNote(id: "note-2", title: "SOTD 2026-04-10", body: htmlEveningDifferentLather),
                RawAppleNote(id: "note-3-same-content", title: "SOTD 2026-04-10", body: htmlMorning)
            ],
            into: plan2.database
        )
        XCTAssertEqual(plan3.database.entries.count, 3)
        XCTAssertEqual(plan3.added, 0)
        XCTAssertEqual(plan3.updatedFromSource, 0)
    }

    func testS04ThreeWayMergeHandlesSourceOnlyLocalOnlyBothChangedAndLegacyNoBaseline() {
        let htmlV1 = makeHTMLTable(rows: [("日期", "2026-04-12"), ("剃须刀", "Blackbird"), ("过程", "顺无痛BBS")])
        let htmlV2 = makeHTMLTable(rows: [("日期", "2026-04-12"), ("剃须刀", "Blackbird"), ("过程", "顺横逆无痛BBS 备注更新")])

        // 首次导入建立 sourceFingerprint 基准
        let p0 = NotesSyncService.planSync(
            notes: [
                RawAppleNote(id: "n-source-only", title: "SOTD 2026-04-12", body: htmlV1),
                RawAppleNote(id: "n-local-only", title: "SOTD 2026-04-12", body: htmlV1),
                RawAppleNote(id: "n-both", title: "SOTD 2026-04-12", body: htmlV1)
            ],
            into: JournalDatabase()
        )
        var db = p0.database

        // 模拟本地改动 n-local-only 与 n-both
        for idx in db.entries.indices {
            if db.entries[idx].id == "n-local-only" || db.entries[idx].id == "n-both" {
                db.entries[idx].fields.append(JournalField(label: "本地备注", value: "App内修订"))
                db.entries[idx].locallyModified = true
            }
        }
        // 加入一条无 sourceFingerprint 基准的旧历史记录
        db.entries.append(JournalEntry(
            id: "n-legacy-no-base",
            date: "2026-04-12",
            fields: [JournalField(label: "日期", value: "2026-04-12"), JournalField(label: "剃须刀", value: "旧本地编辑版")],
            sourceFingerprint: nil,
            locallyModified: nil
        ))

        let p1 = NotesSyncService.planSync(
            notes: [
                RawAppleNote(id: "n-source-only", title: "SOTD 2026-04-12", body: htmlV2),
                RawAppleNote(id: "n-local-only", title: "SOTD 2026-04-12", body: htmlV1),
                RawAppleNote(id: "n-both", title: "SOTD 2026-04-12", body: htmlV2),
                RawAppleNote(id: "n-legacy-no-base", title: "SOTD 2026-04-12", body: htmlV2)
            ],
            into: db
        )

        // 仅来源改变 -> 更新成功
        XCTAssertEqual(p1.updatedFromSource, 1)
        let sourceOnly = p1.database.entries.first(where: { $0.id == "n-source-only" })
        XCTAssertEqual(sourceOnly?.processText, "顺横逆无痛BBS 备注更新")
        XCTAssertNil(sourceOnly?.hasSyncConflict)

        // 仅本地改变 -> 保留本地且无冲突
        let localOnly = p1.database.entries.first(where: { $0.id == "n-local-only" })
        XCTAssertEqual(localOnly?.fieldValue(for: "本地备注"), "App内修订")
        XCTAssertNil(localOnly?.hasSyncConflict)

        // 双边同时改变 -> 保留本地且明确标记 hasSyncConflict = true
        XCTAssertEqual(p1.conflictCount, 1)
        let both = p1.database.entries.first(where: { $0.id == "n-both" })
        XCTAssertEqual(both?.fieldValue(for: "本地备注"), "App内修订")
        XCTAssertEqual(both?.hasSyncConflict, true)

        // 旧记录无基准 -> 保守保留不覆盖
        let legacy = p1.database.entries.first(where: { $0.id == "n-legacy-no-base" })
        XCTAssertEqual(legacy?.primaryRazor, "旧本地编辑版")
    }

    func testS05DeletedImportedEntryUsesTombstoneAndSupportsExplicitReimport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wsj_s05_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = JournalStore(dataDirectoryURL: dir, loadUserPreferences: false)
        let html = makeHTMLTable(rows: [("日期", "2026-04-15"), ("剃须刀", "Wolfman WR2"), ("过程", "顺横无痛BBS")])

        _ = store.applySyncedNotes([
            RawAppleNote(id: "x-coredata://note/delete-me", title: "SOTD 2026-04-15", body: html),
            RawAppleNote(id: "x-coredata://note/keep-me", title: "SOTD 2026-04-15", body: html)
        ])
        XCTAssertEqual(store.database.entries.count, 2)

        // 主动删除第一条
        let toDelete = try XCTUnwrap(store.database.entries.first(where: { $0.id == "x-coredata://note/delete-me" }))
        _ = store.deleteEntry(toDelete)
        XCTAssertEqual(store.database.entries.count, 1)
        XCTAssertEqual(store.deletedSourceIDs, ["x-coredata://note/delete-me"])

        // 正常同步：被删记录不复活，同日同器材的第三条新 ID 仍可正常导入（不按日期/器材屏蔽）
        let syncResult = try store.applySyncedNotes([
            RawAppleNote(id: "x-coredata://note/delete-me", title: "SOTD 2026-04-15", body: html),
            RawAppleNote(id: "x-coredata://note/keep-me", title: "SOTD 2026-04-15", body: html),
            RawAppleNote(id: "x-coredata://note/new-same-day", title: "SOTD 2026-04-15", body: html)
        ]).get()
        XCTAssertEqual(syncResult.skippedDeletedTombstone, 1)
        XCTAssertEqual(syncResult.added, 1)
        XCTAssertFalse(store.database.entries.contains(where: { $0.id == "x-coredata://note/delete-me" }))
        XCTAssertTrue(store.database.entries.contains(where: { $0.id == "x-coredata://note/new-same-day" }))

        // 显式恢复重新导入
        let restoreResult = try store.applySyncedNotes([
            RawAppleNote(id: "x-coredata://note/delete-me", title: "SOTD 2026-04-15", body: html)
        ], allowReimportDeleted: true).get()
        XCTAssertEqual(restoreResult.added, 1)
        XCTAssertTrue(store.database.entries.contains(where: { $0.id == "x-coredata://note/delete-me" }))
        XCTAssertTrue(store.deletedSourceIDs.isEmpty)
    }

    func testRunProcessHandlesLargeOutputTimeoutAndCancellation() async {
        // 1. 大于 128KB 输出不发生 64KB 管道死锁
        let largeRes = await NotesSyncService.runProcess(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", "print('A' * 160000)"],
            timeoutSeconds: 10
        )
        switch largeRes {
        case .success(let out):
            XCTAssertGreaterThanOrEqual(out.count, 160000)
        case .failure(let err):
            XCTFail("Large output failed: \(err)")
        }

        // 2. 超时安全退出
        let timeoutRes = await NotesSyncService.runProcess(
            executablePath: "/bin/sleep",
            arguments: ["5"],
            timeoutSeconds: 0.4
        )
        if case .failure(.timeout) = timeoutRes {
            // expected
        } else {
            XCTFail("Expected timeout error, got \(timeoutRes)")
        }

        // 3. 任务取消安全退出
        let task = Task {
            await NotesSyncService.runProcess(
                executablePath: "/bin/sleep",
                arguments: ["5"],
                timeoutSeconds: 10
            )
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let cancelRes = await task.value
        if case .failure(.cancelled) = cancelRes {
            // expected
        } else {
            XCTFail("Expected cancelled error, got \(cancelRes)")
        }
    }

    func testReadNotesScriptExcludesRecentlyDeletedFolders() throws {
        let scriptURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/read-notes.js")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("最近删除"))
        XCTAssertTrue(script.contains("Recently Deleted"))
        XCTAssertTrue(script.contains("废纸篓"))
        XCTAssertTrue(script.contains("Trash"))
        XCTAssertTrue(script.contains("app.folders()"))
    }
}
