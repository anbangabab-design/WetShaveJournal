import XCTest
@testable import WetShaveJournal

@MainActor
final class CloudSyncTests: XCTestCase {

    private func makeTempDir(_ suffix: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_cloudsync_test_\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testBidirectionalMergeEntriesOverridesTombstonesAndUnknownFields() throws {
        let localDir = try makeTempDir("local")
        let cloudDir = try makeTempDir("cloud")
        defer {
            try? FileManager.default.removeItem(at: localDir)
            try? FileManager.default.removeItem(at: cloudDir)
        }

        let localJSON: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                [
                    "id": "entry-shared",
                    "date": "2026-11-20",
                    "fields": [
                        ["label": "剃须刀", "value": "Blackland Blackbird"],
                        ["label": "刀片", "value": "Feather 1st"],
                        ["label": "过程", "value": "顺横无痛BBS"]
                    ],
                    "updatedAt": "2026-11-20T10:00:00.000Z",
                    "localOnlyTag": "mac-meta"
                ],
                [
                    "id": "entry-mac-only",
                    "date": "2026-11-21",
                    "fields": [
                        ["label": "剃须刀", "value": "Wolfman WR2"],
                        ["label": "刀片", "value": "Astra SP 1st"],
                        ["label": "剃须皂", "value": "MDC Rose"]
                    ],
                    "updatedAt": "2026-11-21T08:00:00.000Z"
                ],
                [
                    "id": "entry-deleted-on-win",
                    "date": "2026-11-18",
                    "fields": [
                        ["label": "剃须刀", "value": "Merkur 34C"]
                    ],
                    "updatedAt": "2026-11-18T08:00:00.000Z"
                ]
            ],
            "duplicates": 0,
            "skipped": 0,
            "lastSync": 780_000_000.0,
            "overrides": [
                "剃须刀|blacklandblackbird": [
                    "brand": "Blackland",
                    "name": "Blackland Blackbird",
                    "material": "不锈钢",
                    "updatedAt": "2026-11-20T09:00:00.000Z"
                ]
            ],
            "pending": ["剃须刀|blacklandblackbird", "剃须皂|mdcrose"],
            "history": [],
            "macCustomExtension": ["version": 1, "flag": true]
        ]

        let remoteJSON: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                [
                    "id": "entry-shared",
                    "date": "2026-11-20",
                    "fields": [
                        ["label": "剃须刀", "value": "Blackland Blackbird Ti"],
                        ["label": "刀片", "value": "Feather 2nd"],
                        ["label": "过程", "value": "顺横逆无痛BBS"]
                    ],
                    "updatedAt": "2026-11-20T12:00:00.000Z",
                    "winOnlyTag": "win-meta"
                ],
                [
                    "id": "entry-win-only",
                    "date": "2026-11-22",
                    "fields": [
                        ["label": "剃须刀", "value": "Tatara Masamune"],
                        ["label": "刀片", "value": "Gillette Nacet 1st"],
                        ["label": "剃须皂", "value": "B&M Seville"]
                    ],
                    "updatedAt": "2026-11-22T09:00:00.000Z"
                ]
            ],
            "duplicates": 0,
            "skipped": 0,
            "lastSync": 780_000_100.0,
            "overrides": [
                "剃须刀|blacklandblackbird": [
                    "brand": "Blackland",
                    "name": "Blackland Blackbird Ti",
                    "material": "钛合金",
                    "isManuallyConfirmed": true,
                    "updatedAt": "2026-11-20T12:30:00.000Z"
                ],
                "剃须刀|tataramasamune": [
                    "brand": "Tatara",
                    "name": "Tatara Masamune",
                    "material": "不锈钢",
                    "updatedAt": "2026-11-22T09:05:00.000Z"
                ]
            ],
            "pending": [],
            "history": [],
            "deletedEntryIds": [
                "entry-deleted-on-win": "2026-11-19T08:00:00.000Z"
            ],
            "winCustomExtension": "preserved-value"
        ]

        let repo = JournalRepository(dataDirectoryURL: localDir)
        try JSONSerialization.data(withJSONObject: localJSON, options: [.sortedKeys]).write(to: repo.journalFileURL)
        try JSONSerialization.data(withJSONObject: remoteJSON, options: [.sortedKeys]).write(to: cloudDir.appendingPathComponent("journal.json"))

        let result = CloudSyncService.performBidirectionalSync(localRepository: repo, cloudSyncDirectory: cloudDir)
        XCTAssertEqual(result.status, .synced)
        XCTAssertEqual(result.entriesAdded, 1)
        XCTAssertEqual(result.entriesUpdated, 1)
        XCTAssertEqual(result.entriesDeleted, 1)
        XCTAssertEqual(result.rulesAdded, 1)
        XCTAssertEqual(result.rulesUpdated, 1)

        // 本地回读验证
        let localData = try Data(contentsOf: repo.journalFileURL)
        let mergedObj = try XCTUnwrap(JSONSerialization.jsonObject(with: localData) as? [String: Any])
        XCTAssertNotNil(mergedObj["macCustomExtension"])
        XCTAssertEqual(mergedObj["winCustomExtension"] as? String, "preserved-value")

        let decoded = try XCTUnwrap(repo.load())
        XCTAssertEqual(decoded.entries.map(\.id), ["entry-win-only", "entry-mac-only", "entry-shared"])
        let shared = try XCTUnwrap(decoded.entries.first { $0.id == "entry-shared" })
        XCTAssertEqual(shared.primaryRazor, "Blackland Blackbird Ti")

        // 云端手动确认过的黑鸟应从 pending 移出，而 mdcrose 仍保留 pending
        XCTAssertFalse(decoded.pending.contains("剃须刀|blacklandblackbird"))
        XCTAssertTrue(decoded.pending.contains("剃须皂|mdcrose"))
        XCTAssertEqual(decoded.overrides["剃须刀|blacklandblackbird"]?.material, "钛合金")
        XCTAssertEqual(decoded.overrides["剃须刀|tataramasamune"]?.brand, "Tatara")
        XCTAssertEqual(decoded.deletedEntryIds?["entry-deleted-on-win"], "2026-11-19T08:00:00.000Z")

        // 本地同步覆盖前必须已生成验证备份
        let backups = try FileManager.default.contentsOfDirectory(at: repo.backupsDirectoryURL, includingPropertiesForKeys: nil)
        XCTAssertGreaterThanOrEqual(backups.count, 1)

        // 再次同步应完全幂等（upToDate）
        let second = CloudSyncService.performBidirectionalSync(localRepository: repo, cloudSyncDirectory: cloudDir)
        XCTAssertEqual(second.status, .upToDate)
    }

    func testCrossDeviceFingerprintDedupAndCustomLogosSync() throws {
        let localDir = try makeTempDir("dedup_local")
        let cloudDir = try makeTempDir("dedup_cloud")
        defer {
            try? FileManager.default.removeItem(at: localDir)
            try? FileManager.default.removeItem(at: cloudDir)
        }

        let localJSON: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                [
                    "id": "local-bbb",
                    "date": "2026-11-25",
                    "fields": [
                        ["label": "剃须刀", "value": "Karve Overlander"],
                        ["label": "刀片", "value": "Astra SP 1st"],
                        ["label": "剃须皂", "value": "Stirling Executive Man"],
                        ["label": "过程", "value": "顺横无痛BBS"]
                    ],
                    "updatedAt": "2026-11-25T08:00:00.000Z"
                ]
            ],
            "overrides": [:],
            "pending": [],
            "history": []
        ]
        let remoteJSON: [String: Any] = [
            "schemaVersion": 2,
            "entries": [
                [
                    "id": "local-aaa",
                    "date": "2026-11-25",
                    "fields": [
                        ["label": "剃须刀", "value": "Karve Overlander"],
                        ["label": "刀片", "value": "Astra SP 1st"],
                        ["label": "剃须皂", "value": "Stirling Executive Man"],
                        ["label": "过程", "value": "顺横无痛BBS"]
                    ],
                    "updatedAt": "2026-11-25T09:00:00.000Z"
                ]
            ],
            "overrides": [:],
            "pending": [],
            "history": []
        ]

        let repo = JournalRepository(dataDirectoryURL: localDir)
        try JSONSerialization.data(withJSONObject: localJSON).write(to: repo.journalFileURL)
        try JSONSerialization.data(withJSONObject: remoteJSON).write(to: cloudDir.appendingPathComponent("journal.json"))

        // 准备双向 CustomLogos
        let localLogos = localDir.appendingPathComponent("CustomLogos", isDirectory: true)
        let cloudLogos = cloudDir.appendingPathComponent("CustomLogos", isDirectory: true)
        try FileManager.default.createDirectory(at: localLogos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudLogos, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]).write(to: localLogos.appendingPathComponent("karve.png"))
        try Data([0x89, 0x50, 0x4E, 0x47, 5, 6, 7, 8]).write(to: cloudLogos.appendingPathComponent("blackland.png"))

        let result = CloudSyncService.performBidirectionalSync(localRepository: repo, cloudSyncDirectory: cloudDir)
        XCTAssertEqual(result.status, .synced)
        XCTAssertEqual(result.logosPulled, 1)
        XCTAssertEqual(result.logosPushed, 1)

        // 不同 UUID 但同日同核心器材防重收敛为单一确定性 ID (local-aaa)
        let loaded = try XCTUnwrap(repo.load())
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].id, "local-aaa")

        XCTAssertTrue(FileManager.default.fileExists(atPath: localLogos.appendingPathComponent("blackland.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudLogos.appendingPathComponent("karve.png").path))
    }

    func testUnavailableCloudDirectoryDegradesGracefullyWithoutCreatingFolder() throws {
        let localDir = try makeTempDir("unavail_local")
        defer { try? FileManager.default.removeItem(at: localDir) }

        let missingCloud = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_unmounted_cloud_\(UUID().uuidString)", isDirectory: true)
        let repo = JournalRepository(dataDirectoryURL: localDir)
        let initial = JournalDatabase(entries: [
            JournalEntry(id: "local-1", date: "2026-11-26", fields: [JournalField(label: "剃须刀", value: "Henson")])
        ])
        try repo.persist(initial, createBackup: false, isReadOnlyProtected: false)

        let result = CloudSyncService.performBidirectionalSync(localRepository: repo, cloudSyncDirectory: missingCloud)
        XCTAssertEqual(result.status, .unavailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingCloud.path))

        // 本地数据毫发无损
        let reloaded = try XCTUnwrap(repo.load())
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].id, "local-1")
    }
}
