import XCTest
@testable import WetShaveJournal

@MainActor
final class PersistenceAndSecurityTests: XCTestCase {

    private func makeTempDir(_ suffix: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_test_\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLegacyV132JSONLoadsAndRoundTripsWithoutDataLoss() throws {
        let dir = try makeTempDir("legacy_json")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 模拟 v1.3.1/v1.3.2 旧版 journal.json：无 schemaVersion、无 deletedSourceIDs、旧版 [String: GearOverride] 历史格式、旧 knotBrand 与 Slant plateType
        let legacyJSON = """
        {
          "entries": [
            {
              "id": "x-coredata://ABC/ICNote/p100",
              "date": "2026-01-15",
              "fields": [
                {"label": "日期", "value": "2026-01-15"},
                {"label": "剃须刀1", "value": "Blackland Blackbird Ti"},
                {"label": "剃须刀2", "value": "Karve Overlander"},
                {"label": "刀片1", "value": "Astra SP 2nd"},
                {"label": "刀片2", "value": "Feather 1st"},
                {"label": "剃须刷", "value": "Oumo 26mm"},
                {"label": "剃须皂", "value": "MDC Absinthe"},
                {"label": "起泡", "value": "碗起"},
                {"label": "过程", "value": "顺横逆无痛BBS"},
                {"label": "自定义备注", "value": "保留历史扩展字段"}
              ]
            }
          ],
          "duplicates": 0,
          "skipped": 0,
          "lastSync": 758000000,
          "overrides": {
            "剃须刀|blacklandblackbirdti": {
              "brand": "Blackland",
              "name": "Blackland Blackbird Ti",
              "plateType": "Slant",
              "material": "钛合金",
              "isManuallyConfirmed": true
            },
            "剃须刷|oumo26mm": {
              "brand": "CustomHandle",
              "knotBrand": "Oumo",
              "name": "Oumo 26mm"
            }
          },
          "pending": ["剃须皂|mdcabsinthe"],
          "history": [
            {
              "剃须刀|blacklandblackbirdti": {
                "brand": "Blackland",
                "name": "Blackland Blackbird"
              }
            }
          ]
        }
        """

        let repo = JournalRepository(dataDirectoryURL: dir)
        try legacyJSON.data(using: .utf8)!.write(to: repo.journalFileURL)

        let store = JournalStore(dataDirectoryURL: dir, loadUserPreferences: false)
        XCTAssertFalse(store.isReadOnlyProtected)
        XCTAssertEqual(store.database.entries.count, 1)
        XCTAssertEqual(store.database.entries[0].id, "x-coredata://ABC/ICNote/p100")
        XCTAssertEqual(store.database.entries[0].fieldValue(for: "自定义备注"), "保留历史扩展字段")
        XCTAssertEqual(store.database.entries[0].fieldValue(for: "剃须刀2"), "Karve Overlander")

        // 旧 Slant plateType 迁移为 plateType=.sb + isSlant=true
        let razorOv = try XCTUnwrap(store.database.overrides["剃须刀|blacklandblackbirdti"])
        XCTAssertEqual(razorOv.plateType, .sb)
        XCTAssertEqual(razorOv.isSlant, true)
        XCTAssertEqual(razorOv.isManuallyConfirmed, true)

        // 旧 knotBrand 迁移为 brand=Oumo + handleBrand=CustomHandle
        let brushOv = try XCTUnwrap(store.database.overrides["剃须刷|oumo26mm"])
        XCTAssertEqual(brushOv.brand, "Oumo")
        XCTAssertEqual(brushOv.handleBrand, "CustomHandle")

        // 旧 history 字典兼容解码
        XCTAssertEqual(store.database.history.count, 1)
        XCTAssertEqual(store.database.pending, ["剃须皂|mdcabsinthe"])

        // 保存回读校验
        try store.save(createBackup: true)
        let reloaded = try XCTUnwrap(repo.load())
        XCTAssertEqual(reloaded.schemaVersion, JournalDatabase.currentSchemaVersion)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].fieldValue(for: "自定义备注"), "保留历史扩展字段")
        XCTAssertEqual(reloaded.overrides["剃须刀|blacklandblackbirdti"]?.isManuallyConfirmed, true)
    }

    func testBuildMergedFieldsPreservesMultiRazorAndCustomFields() {
        let existing = JournalEntry(
            id: "x-coredata://note/1",
            date: "2026-02-01",
            fields: [
                JournalField(label: "日期", value: "2026-02-01"),
                JournalField(label: "剃须刀1", value: "Blackland Blackbird"),
                JournalField(label: "剃须刀2", value: "Wolfman WR2"),
                JournalField(label: "刀片1", value: "Astra SP 1st"),
                JournalField(label: "刀片2", value: "Feather 2nd"),
                JournalField(label: "水温", value: "温水")
            ]
        )

        let merged = JournalEntry.buildMergedFields(
            existingEntry: existing,
            dateStr: "2026-02-01",
            razor: "Blackland Blackbird Ti",
            blade: "Astra SP 2nd",
            brush: "Oumo",
            soap: "MDC",
            bowl: "",
            preShave: "",
            afterShave: "",
            afterShower: true,
            hotTowel: true,
            useAlum: false,
            processText: "顺横无痛BBS",
            loadingMethod: "挖取",
            latheringMethod: "碗起"
        )

        let updatedEntry = JournalEntry(id: existing.id, date: "2026-02-01", fields: merged)
        XCTAssertEqual(updatedEntry.fieldValue(for: "剃须刀1"), "Blackland Blackbird Ti")
        XCTAssertEqual(updatedEntry.fieldValue(for: "剃须刀2"), "Wolfman WR2")
        XCTAssertEqual(updatedEntry.fieldValue(for: "刀片1"), "Astra SP 2nd")
        XCTAssertEqual(updatedEntry.fieldValue(for: "刀片2"), "Feather 2nd")
        XCTAssertEqual(updatedEntry.fieldValue(for: "水温"), "温水")
    }

    func testCorruptJSONEnablesReadOnlyProtectionAndBlocksWrites() throws {
        let dir = try makeTempDir("corrupt_readonly")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = JournalRepository(dataDirectoryURL: dir)
        let corruptPayload = "{ not valid json !!!".data(using: .utf8)!
        try corruptPayload.write(to: repo.journalFileURL)

        let store = JournalStore(dataDirectoryURL: dir, loadUserPreferences: false)
        XCTAssertTrue(store.isReadOnlyProtected)
        XCTAssertNotNil(store.loadErrorMessage)

        let newEntry = JournalEntry(id: "local-1", date: "2026-03-01", fields: [JournalField(label: "剃须刀", value: "Test")])
        let upsertResult = store.upsertEntry(newEntry)
        if case .success = upsertResult {
            XCTFail("Expected write to fail under read-only protection")
        }

        // 原始损坏文件绝不被覆盖
        let diskBytes = try Data(contentsOf: repo.journalFileURL)
        XCTAssertEqual(diskBytes, corruptPayload)
        XCTAssertTrue(store.database.entries.isEmpty)
    }

    func testBackupFailureAbortsHighRiskWriteAndKeepsStateIntact() throws {
        let dir = try makeTempDir("backup_fail")
        defer { try? FileManager.default.removeItem(at: dir) }

        let repo = JournalRepository(dataDirectoryURL: dir)
        let initialDB = JournalDatabase(entries: [
            JournalEntry(id: "local-1", date: "2026-03-01", fields: [JournalField(label: "剃须刀", value: "Blackbird")])
        ])
        try repo.persist(initialDB, createBackup: false, isReadOnlyProtected: false)

        // 用普通文件替换 Backups 目录，模拟备份目录不可创建/不可写入
        try FileManager.default.removeItem(at: repo.backupsDirectoryURL)
        try Data("blocker".utf8).write(to: repo.backupsDirectoryURL)

        let store = JournalStore(dataDirectoryURL: dir, loadUserPreferences: false)
        // 因为 load() 会尝试 createDirectory(at: backupsDirectoryURL)，此时会进入只读保护并阻止写入
        XCTAssertTrue(store.isReadOnlyProtected)
        XCTAssertThrowsError(try repo.persist(initialDB, createBackup: true, isReadOnlyProtected: false))
    }

    func testKeychainMigrationAndEndpointSecurity() throws {
        let suiteName = "wsj.test.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // 1. 迁移成功：写入模拟 Keychain、回读一致、清除明文 legacy key
        defaults.set("sk-secret-legacy-12345", forKey: AIConfig.legacyAPIKeyDefaultsKey)
        var mockKeychain: String? = nil
        let migrated = AIConfig.loadWithKeychainMigration(
            defaults: defaults,
            keychainRead: { mockKeychain },
            keychainSave: { mockKeychain = $0 }
        )
        XCTAssertNil(migrated.warning)
        XCTAssertEqual(migrated.config.apiKey, "sk-secret-legacy-12345")
        XCTAssertEqual(mockKeychain, "sk-secret-legacy-12345")
        XCTAssertNil(defaults.string(forKey: AIConfig.legacyAPIKeyDefaultsKey))

        // 日志脱敏校验：绝不泄露真实 Key
        XCTAssertFalse(migrated.config.description.contains("sk-secret-legacy-12345"))
        XCTAssertTrue(migrated.config.description.contains("<redacted>"))

        // 2. 迁移失败：保留旧明文确保可用并给出 warning
        defaults.set("sk-fallback-key-999", forKey: AIConfig.legacyAPIKeyDefaultsKey)
        let failedMig = AIConfig.loadWithKeychainMigration(
            defaults: defaults,
            keychainRead: { nil },
            keychainSave: { _ in throw KeychainStoreError.osStatus(-25293) }
        )
        XCTAssertNotNil(failedMig.warning)
        XCTAssertEqual(failedMig.config.apiKey, "sk-fallback-key-999")
        XCTAssertEqual(defaults.string(forKey: AIConfig.legacyAPIKeyDefaultsKey), "sk-fallback-key-999")

        // 3. 本地私有加密文件存储校验（0700 目录 + 0600 文件 + AES-GCM 密文无明文泄露 + 删除回读）
        let secretRoot = try makeTempDir("local_secret")
        defer { try? FileManager.default.removeItem(at: secretRoot) }
        let secretDir = secretRoot.appendingPathComponent("WetShaveJournal_Secrets", isDirectory: true)
        let secretFile = secretDir.appendingPathComponent("ai_key.bin", isDirectory: false)

        XCTAssertNil(try LocalSecretStore.read(from: secretFile))

        let sampleKey = "sk-live-local-secret-9876543210"
        try LocalSecretStore.save(sampleKey, to: secretFile)
        XCTAssertEqual(try LocalSecretStore.read(from: secretFile), sampleKey)

        // 验证磁盘密文不包含明文 Key 或其 Base64 编码
        let rawBytes = try Data(contentsOf: secretFile)
        XCTAssertNil(rawBytes.range(of: Data(sampleKey.utf8)))
        XCTAssertNil(rawBytes.range(of: Data(Data(sampleKey.utf8).base64EncodedString().utf8)))

        // 验证严格权限：目录 0700，文件 0600
        let dirPerms = try FileManager.default.attributesOfItem(atPath: secretDir.path)[.posixPermissions] as? NSNumber
        let filePerms = try FileManager.default.attributesOfItem(atPath: secretFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((dirPerms?.intValue ?? 0) & 0o777, 0o700)
        XCTAssertEqual((filePerms?.intValue ?? 0) & 0o777, 0o600)

        // 默认路径独立于 Google Drive CloudStorage 与 journal.json 所在目录
        let defaultSecretPath = LocalSecretStore.defaultAIKeyFileURL.path
        XCTAssertTrue(defaultSecretPath.hasSuffix("/Library/Application Support/WetShaveJournal_Secrets/ai_key.bin"))
        XCTAssertFalse(defaultSecretPath.contains("/Library/CloudStorage/"))

        // 损坏密文必须安全报错
        try Data("corrupted-bytes".utf8).write(to: secretFile)
        XCTAssertThrowsError(try LocalSecretStore.read(from: secretFile))

        // 删除后回读为 nil
        try LocalSecretStore.delete(at: secretFile)
        XCTAssertNil(try LocalSecretStore.read(from: secretFile))

        // 4. 网络端点安全校验
        XCTAssertNotNil(EndpointSecurityValidator.validate("https://api.deepseek.com/v1", allowLocalHTTP: true).url)
        XCTAssertNil(EndpointSecurityValidator.validate("http://api.deepseek.com/v1", allowLocalHTTP: true).url)
        XCTAssertNotNil(EndpointSecurityValidator.validate("http://127.0.0.1:8317/v1", allowLocalHTTP: true).url)
        XCTAssertNotNil(EndpointSecurityValidator.validate("http://localhost:8317/v1", allowLocalHTTP: true).url)
        XCTAssertNotNil(EndpointSecurityValidator.validate("http://[::1]:8317/v1", allowLocalHTTP: true).url)
        XCTAssertNil(EndpointSecurityValidator.validate("http://127.0.0.1:8317/v1", allowLocalHTTP: false).url)
    }

    func testUnmountedCloudDirectoryEntersReadOnlyProtectionInsteadOfCreatingEmptyDB() {
        let missingCloudDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsj_unmounted_\(UUID().uuidString)", isDirectory: true)
        let repo = JournalRepository(dataDirectoryURL: missingCloudDir, requireMountedCloudRoot: true)
        XCTAssertThrowsError(try repo.load()) { err in
            guard case JournalPersistenceError.cloudDirectoryUnavailable = err else {
                return XCTFail("Expected cloudDirectoryUnavailable, got \(err)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingCloudDir.path))
    }
}
