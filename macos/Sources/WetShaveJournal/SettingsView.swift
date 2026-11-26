import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: JournalStore
    @EnvironmentObject var updateService: UpdateService
    @Environment(\.colorScheme) private var scheme

    @State private var showAPIKey: Bool = false
    @State private var isTestingAI: Bool = false
    @State private var aiTestResult: (ok: Bool, message: String)? = nil

    private var appIconImage: NSImage {
        if let icnsPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: icnsPath) {
            return img
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        let _ = store.language
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.t("外观与设置", "Settings"))
                    .font(.system(size: 26, weight: .bold, design: .rounded))

                // 外观与语言
                SectionCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.t("界面与语言", "Appearance & Language"))
                            .font(.system(size: 16, weight: .semibold))

                        HStack(alignment: .center, spacing: 20) {
                            Text(L10n.t("外观模式", "Appearance"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 118, alignment: .leading)

                            Picker("Appearance", selection: $store.appearanceMode) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Label(mode.displayName, systemImage: mode.icon).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 380)
                        }

                        HStack(alignment: .center, spacing: 20) {
                            Text(L10n.t("语言 / Language", "Language"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 118, alignment: .leading)

                            Picker("Language", selection: $store.language) {
                                ForEach(AppLanguage.allCases) { lang in
                                    Text(lang.displayName).tag(lang)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 380)
                        }
                    }
                }

                // 通用 OpenAI 兼容 AI 识别接口（含 DeepSeek deepseek-flash + deepseek_web_search）
                SectionCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(L10n.t("AI 识别接口", "AI Recognition API"))
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Toggle(L10n.t("启用 AI 接口识别", "Enable AI API"), isOn: $store.aiConfig.enabled)
                                .toggleStyle(.switch)
                                .tint(ShaveTheme.accent)
                        }

                        HStack(alignment: .center, spacing: 20) {
                            Text(L10n.t("快捷预设", "Preset"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 118, alignment: .leading)

                            Picker("Preset", selection: Binding(
                                get: { store.aiConfig.preset },
                                set: { newPreset in
                                    store.aiConfig.preset = newPreset
                                    if newPreset != .custom {
                                        store.aiConfig.baseURL = newPreset.defaultBaseURL
                                        store.aiConfig.model = newPreset.defaultModel
                                    }
                                    store.aiConfig.enableWebSearch = newPreset.defaultWebSearch
                                    store.aiConfig.enableGoogleSearch = (newPreset == .custom)
                                        ? store.aiConfig.model.lowercased().contains("gemini")
                                        : newPreset.defaultGoogleSearch
                                    aiTestResult = nil
                                }
                            )) {
                                ForEach(AIProviderPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 420)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 20) {
                                Text("Base URL")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 118, alignment: .leading)
                                TextField("https://api.deepseek.com/v1", text: $store.aiConfig.baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13, design: .monospaced))
                            }

                            let baseStatus = EndpointSecurityValidator.validate(
                                store.aiConfig.baseURL,
                                allowLocalHTTP: true,
                                contextLabel: "Base URL"
                            )
                            if baseStatus.isLocalHTTP {
                                Label(
                                    L10n.t("本机明文 HTTP 模式：仅限 localhost / 127.0.0.1 / ::1 本地模型服务使用", "Local HTTP endpoint: allowed for localhost / 127.0.0.1 / ::1 local models only."),
                                    systemImage: "info.circle.fill"
                                )
                                .font(.system(size: 12))
                                .foregroundStyle(ShaveTheme.amber)
                                .padding(.leading, 138)
                            } else if let urlErr = baseStatus.errorMessage,
                                      !store.aiConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Label(urlErr, systemImage: "exclamationmark.shield.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ShaveTheme.crimson)
                                    .padding(.leading, 138)
                            }
                        }

                        HStack(alignment: .center, spacing: 20) {
                            Text(L10n.t("模型名称", "Model"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 118, alignment: .leading)
                            TextField("deepseek-flash", text: $store.aiConfig.model)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 13, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .center, spacing: 20) {
                                Text("API Key")
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 118, alignment: .leading)

                                HStack(spacing: 8) {
                                    Group {
                                        if showAPIKey {
                                            TextField("sk-...", text: $store.aiConfig.apiKey)
                                        } else {
                                            SecureField("sk-...", text: $store.aiConfig.apiKey)
                                        }
                                    }
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 13, design: .monospaced))

                                    Button {
                                        showAPIKey.toggle()
                                    } label: {
                                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                            .font(.system(size: 13))
                                            .frame(width: 28, height: 26)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.bordered)
                                    .help(showAPIKey ? L10n.t("隐藏 Key", "Hide Key") : L10n.t("显示 Key", "Show Key"))

                                    if !store.aiConfig.apiKey.isEmpty {
                                        Button(role: .destructive) {
                                            store.clearAIAPIKey()
                                            aiTestResult = nil
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.system(size: 12.5))
                                                .frame(width: 28, height: 26)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.bordered)
                                        .help(L10n.t("从钥匙串删除 API Key", "Delete API key from Keychain"))
                                    }
                                }
                            }

                            if let kcWarning = store.keychainWarningMessage {
                                Label(kcWarning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ShaveTheme.amber)
                                    .padding(.leading, 138)
                            }
                        }

                        Toggle(
                            L10n.t("启用 DeepSeek 联网搜索（deepseek_web_search）", "Enable DeepSeek Web Search (deepseek_web_search)"),
                            isOn: $store.aiConfig.enableWebSearch
                        )
                        .toggleStyle(.switch)
                        .tint(ShaveTheme.accent)
                        .font(.system(size: 13))

                        Toggle(
                            L10n.t("启用 Google 联网搜索（适配 Gemini / 本地 CPA）", "Enable Google Web Search (Gemini / Local CPA)"),
                            isOn: $store.aiConfig.enableGoogleSearch
                        )
                        .toggleStyle(.switch)
                        .tint(ShaveTheme.accent)
                        .font(.system(size: 13))

                        HStack(spacing: 12) {
                            Button {
                                Task { await runConnectionTest() }
                            } label: {
                                HStack(spacing: 6) {
                                    if isTestingAI { ProgressView().controlSize(.small) }
                                    Text(isTestingAI ? L10n.t("测试中...", "Testing...") : L10n.t("测试连接", "Test Connection"))
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isTestingAI || store.aiConfig.apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                            if let res = aiTestResult {
                                Label(res.message, systemImage: res.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(res.ok ? ShaveTheme.forest : ShaveTheme.crimson)
                                    .lineLimit(2)
                            } else {
                                Text(L10n.t("Key 安全存于 macOS 钥匙串（Keychain），不写入 journal.json；不支持联网工具时自动回退普通请求", "Key stored securely in macOS Keychain (never in journal.json). Auto-falls back if web search tool is unsupported."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }

                // 器材库与品牌 Logo 维护
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.t("器材库与品牌图标", "Gear Library & Brand Logos"))
                            .font(.system(size: 16, weight: .semibold))

                        FlowLayout(spacing: 10, lineSpacing: 10) {
                            Button {
                                Task { await store.recognizeAllPending() }
                            } label: {
                                Label(
                                    L10n.t("识别待确认 (\(store.database.pending.count))", "Identify Pending (\(store.database.pending.count))"),
                                    systemImage: store.aiConfig.isReady ? "sparkles" : "globe"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ShaveTheme.accent)
                            .disabled(store.isRecognizingBatch || store.database.pending.isEmpty || store.isReadOnlyProtected)

                            Button {
                                store.undoLastOverrideChange()
                            } label: {
                                Label(L10n.t("撤销上次修改", "Undo Last Edit"), systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.database.history.isEmpty || store.isReadOnlyProtected)

                            Button {
                                exportCSV()
                            } label: {
                                Label(L10n.t("导出 CSV", "Export CSV"), systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                BrandLogoCache.shared.clearAutoCacheAndRefetch()
                                store.showToast(
                                    L10n.t("已清理品牌 Logo 缓存，浏览器材库时将重新抓取官网图标", "Cleared logo cache — logos will re-fetch from official sites"),
                                    isLoading: false
                                )
                            } label: {
                                Label(L10n.t("清理并重抓品牌 Logo", "Refresh Brand Logos"), systemImage: "arrow.clockwise.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                // 数据与同步
                SectionCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.t("数据与同步", "Data & Sync"))
                            .font(.system(size: 16, weight: .semibold))

                        let syncDate = Date(timeIntervalSinceReferenceDate: store.database.lastSync)
                        Text(L10n.t(
                            "\(store.database.entries.count) 篇日记 · \(store.database.overrides.count) 条器材规则 · 上次同步 \(syncDate.formatted(date: .abbreviated, time: .shortened))",
                            "\(store.database.entries.count) entries · \(store.database.overrides.count) gear rules · Last sync \(syncDate.formatted(date: .abbreviated, time: .shortened))"
                        ))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                        FlowLayout(spacing: 10, lineSpacing: 10) {
                            Button {
                                Task { await store.syncFromAppleNotes() }
                            } label: {
                                Label(L10n.t("同步备忘录", "Sync Apple Notes"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isSyncing || store.isReadOnlyProtected)

                            if !store.deletedSourceIDs.isEmpty {
                                Button {
                                    Task { await store.syncFromAppleNotes(allowReimportDeleted: true) }
                                } label: {
                                    Label(
                                        L10n.t("恢复已删备忘录 (\(store.deletedSourceIDs.count))", "Re-import Deleted (\(store.deletedSourceIDs.count))"),
                                        systemImage: "arrow.counterclockwise"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .disabled(store.isSyncing || store.isReadOnlyProtected)
                                .help(L10n.t(
                                    "重新从 Apple 备忘录导入你在应用内主动删除过的同步记录",
                                    "Re-import Apple Notes entries you previously deleted in this app"
                                ))
                            }

                            Button {
                                NSWorkspace.shared.open(store.dataDirectoryURL)
                            } label: {
                                Label(L10n.t("打开数据目录", "Open Data Folder"), systemImage: "folder")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                do {
                                    try store.save(createBackup: true)
                                    store.showToast(L10n.t("已创建并校验数据备份", "Verified backup created"), isLoading: false)
                                } catch {
                                    store.showToast(error.localizedDescription, isLoading: false)
                                }
                            } label: {
                                Label(L10n.t("立即备份", "Backup Now"), systemImage: "externaldrive.badge.plus")
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isReadOnlyProtected)
                        }

                        Divider()
                            .padding(.vertical, 2)

                        // 云盘双端同步区块（Google Drive / iCloud / OneDrive 智能双向合并）
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: store.hasCloudSyncDirectory ? "icloud.and.arrow.up.fill" : "icloud")
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(store.hasCloudSyncDirectory ? ShaveTheme.accent : .secondary)
                                Text(L10n.t("云盘双端同步", "Cloud Drive Sync"))
                                    .font(.system(size: 14.5, weight: .semibold))
                                cloudSyncStatusPill
                                Spacer()
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(L10n.t("绑定云盘同步目录", "Bound Cloud Sync Folder"))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if store.hasCloudSyncDirectory {
                                    Text(store.cloudSyncDirectoryPath)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                } else {
                                    Text(L10n.t(
                                        "尚未配置（建议指向 Google Drive / iCloud / OneDrive 内的 WetShaveJournal_Sync/）",
                                        "Not configured (recommended: WetShaveJournal_Sync/ inside Google Drive, iCloud, or OneDrive)"
                                    ))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(ShaveTheme.subtleSurface(scheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
                            )

                            if store.hasCloudSyncDirectory {
                                VStack(alignment: .leading, spacing: 4) {
                                    if let lastISO = store.lastCloudSyncAt,
                                       let lastDate = SyncTimestamp.parseDate(lastISO) {
                                        Text(L10n.t(
                                            "上次云盘同步：\(lastDate.formatted(date: .abbreviated, time: .shortened))",
                                            "Last cloud sync: \(lastDate.formatted(date: .abbreviated, time: .shortened))"
                                        ))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    }

                                    if let result = store.lastCloudSyncResult {
                                        let isWarn = result.status == .unavailable || result.status == .error
                                        Label(
                                            result.summaryText(isEnglish: L10n.isEnglish),
                                            systemImage: isWarn
                                                ? "exclamationmark.triangle.fill"
                                                : (result.status == .sameDirectory ? "info.circle.fill" : "checkmark.circle.fill")
                                        )
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(
                                            result.status == .error
                                                ? ShaveTheme.crimson
                                                : (result.status == .unavailable ? ShaveTheme.amber : ShaveTheme.forest)
                                        )
                                    }
                                }
                            }

                            FlowLayout(spacing: 10, lineSpacing: 10) {
                                Button {
                                    pickCloudSyncDirectory()
                                } label: {
                                    Label(
                                        store.hasCloudSyncDirectory
                                            ? L10n.t("更改云盘同步目录", "Change Sync Folder")
                                            : L10n.t("选择云盘同步目录", "Select Sync Folder"),
                                        systemImage: "folder.badge.gearshape"
                                    )
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(ShaveTheme.accent)

                                Button {
                                    Task { await store.syncWithCloudDirectory(manual: true) }
                                } label: {
                                    HStack(spacing: 6) {
                                        if store.isCloudSyncing {
                                            ProgressView().controlSize(.small)
                                        }
                                        Label(
                                            store.isCloudSyncing
                                                ? L10n.t("同步中...", "Syncing...")
                                                : L10n.t("立即双向同步", "Sync Now"),
                                            systemImage: "arrow.triangle.2.circlepath.icloud"
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!store.hasCloudSyncDirectory || store.isCloudSyncing || store.isReadOnlyProtected)

                                if store.hasCloudSyncDirectory {
                                    Button {
                                        let url = URL(fileURLWithPath: store.cloudSyncDirectoryPath, isDirectory: true)
                                        if FileManager.default.fileExists(atPath: url.path) {
                                            NSWorkspace.shared.open(url)
                                        } else {
                                            store.showToast(
                                                L10n.t("云盘同步目录当前不可访问（可能未挂载）", "Cloud sync folder is currently unavailable"),
                                                isLoading: false
                                            )
                                        }
                                    } label: {
                                        Label(L10n.t("打开同步目录", "Open Sync Folder"), systemImage: "folder")
                                    }
                                    .buttonStyle(.bordered)

                                    Button(role: .destructive) {
                                        store.clearCloudSyncDirectory()
                                    } label: {
                                        Label(L10n.t("关闭/清除同步目录", "Disable & Clear"), systemImage: "icloud.slash")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(store.isCloudSyncing)
                                }
                            }

                            Text(L10n.t(
                                "智能双向合并 journal.json（按 ID 与更新时间合并日记、器材规则、删除墓碑及未知扩展字段）并增量同步 CustomLogos/；启动时静默同步，保存后防抖 2 秒自动同步；写入前自动保留本地备份并采用原子替换。",
                                "Smart bidirectional merge for journal.json (entries, gear rules, deletion tombstones, and extension fields) plus incremental CustomLogos/ sync. Silently syncs on launch and 2s after edits with automatic local backup and atomic replacement."
                            ))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }

                // 关于湿剃日记与检查版本更新
                SectionCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 16) {
                            Image(nsImage: appIconImage)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("WetShaveJournal")
                                        .font(.system(size: 17, weight: .bold))
                                    TagPill(text: "v\(AppMetadata.version)", color: ShaveTheme.accent)
                                }
                                Text(L10n.t(
                                    "专为传统湿剃爱好者打造的 macOS 原生 SOTD 日记、器材档案库与 AI 配装复盘工具。",
                                    "Native macOS SOTD journal, gear archive, randomizer, and AI shaving companion."
                                ))
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        Toggle(
                            L10n.t("启动时自动检查更新", "Check for updates automatically on launch"),
                            isOn: $updateService.autoCheckOnLaunch
                        )
                        .toggleStyle(.switch)
                        .tint(ShaveTheme.accent)
                        .font(.system(size: 13.5))

                        HStack(spacing: 12) {
                            Button {
                                Task {
                                    await updateService.checkForUpdates(manual: true, presentAlertOnNoUpdate: false)
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    if updateService.isChecking { ProgressView().controlSize(.small) }
                                    Label(
                                        updateService.isChecking ? L10n.t("检查中...", "Checking...") : L10n.t("检查更新", "Check for Updates"),
                                        systemImage: "arrow.down.circle"
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(updateService.isChecking)

                            if let statusMsg = updateService.statusMessage {
                                Label(
                                    statusMsg,
                                    systemImage: updateService.statusIsError
                                        ? "exclamationmark.triangle.fill"
                                        : (updateService.statusIsUpToDate ? "checkmark.circle.fill" : "sparkles")
                                )
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(
                                    updateService.statusIsError
                                        ? ShaveTheme.crimson
                                        : (updateService.statusIsUpToDate ? ShaveTheme.forest : ShaveTheme.accent)
                                )
                                .lineLimit(2)
                            } else if !updateService.ignoredVersion.isEmpty {
                                HStack(spacing: 6) {
                                    Text(L10n.t("已忽略版本 v\(updateService.ignoredVersion)", "Ignored v\(updateService.ignoredVersion)"))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    Button(L10n.t("清除忽略", "Reset")) {
                                        updateService.clearIgnoredVersion()
                                    }
                                    .buttonStyle(.link)
                                    .font(.system(size: 12))
                                }
                            } else {
                                Text("GitHub · \(UpdateService.githubRepo)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pickCloudSyncDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L10n.t("选择云盘同步目录", "Select Cloud Sync Folder")
        panel.prompt = L10n.t("选择此目录", "Select Folder")
        if store.hasCloudSyncDirectory {
            let currentURL = URL(fileURLWithPath: store.cloudSyncDirectoryPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: currentURL.path) {
                panel.directoryURL = currentURL
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.setCloudSyncDirectory(url)
    }

    @ViewBuilder
    private var cloudSyncStatusPill: some View {
        if store.isCloudSyncing {
            TagPill(text: L10n.t("同步中", "Syncing"), color: ShaveTheme.accent)
        } else if !store.hasCloudSyncDirectory {
            TagPill(text: L10n.t("未配置", "Off"), neutral: true)
        } else if let status = store.lastCloudSyncResult?.status {
            switch status {
            case .unavailable:
                TagPill(text: L10n.t("目录不可用", "Unavailable"), color: ShaveTheme.amber)
            case .error:
                TagPill(text: L10n.t("同步异常", "Error"), color: ShaveTheme.crimson)
            case .sameDirectory:
                TagPill(text: L10n.t("同目录跳过", "Same Folder"), color: ShaveTheme.amber)
            case .synced, .upToDate:
                TagPill(text: L10n.t("已开启", "Enabled"), color: ShaveTheme.forest)
            case .disabled:
                TagPill(text: L10n.t("未配置", "Off"), neutral: true)
            }
        } else {
            TagPill(text: L10n.t("已开启", "Enabled"), color: ShaveTheme.forest)
        }
    }

    private func runConnectionTest() async {
        isTestingAI = true
        aiTestResult = nil
        let res = await WebGearRecognizer.shared.testAIConnection(config: store.aiConfig)
        isTestingAI = false
        aiTestResult = res
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = L10n.isEnglish ? "WetShaveJournal_Gear.csv" : "装备资料库导出.csv"
        panel.canCreateDirectories = true
        panel.title = L10n.t("导出装备资料库（CSV）", "Export Gear Library (CSV)")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = store.exportGearLibraryCSV()
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            store.showToast(L10n.t("已导出：\(url.lastPathComponent)", "Exported: \(url.lastPathComponent)"), isLoading: false)
        } catch {
            store.showToast(L10n.t("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)"), isLoading: false)
        }
    }
}
