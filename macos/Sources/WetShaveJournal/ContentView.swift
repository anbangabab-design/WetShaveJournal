import SwiftUI
import AppKit

enum AppTab: String, CaseIterable, Identifiable {
    case journal = "湿剃日记"
    case gear = "器材库"
    case randomDraw = "随机抽签"
    case stats = "数据统计"
    case settings = "外观与设置"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .journal: return L10n.t("湿剃日记", "Journal")
        case .gear: return L10n.t("器材库", "Gear")
        case .randomDraw: return L10n.t("随机抽签", "Randomizer")
        case .stats: return L10n.t("数据统计", "Stats")
        case .settings: return L10n.t("外观与设置", "Settings")
        }
    }

    var icon: String {
        switch self {
        case .journal: return "book.pages.fill"
        case .gear: return "tray.full.fill"
        case .randomDraw: return "dice.fill"
        case .stats: return "chart.xyaxis.line"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: JournalStore
    @EnvironmentObject var updateService: UpdateService
    @Environment(\.colorScheme) private var scheme

    @State private var selectedTab: AppTab = .journal
    @State private var showNewEntrySheet = false
    @State private var newEntryDraft: SOTDDraft? = nil

    var body: some View {
        let _ = store.language
        NavigationSplitView {
            List(AppTab.allCases, selection: $selectedTab) { tab in
                NavigationLink(value: tab) {
                    HStack(spacing: 10) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(selectedTab == tab ? ShaveTheme.accent : .secondary)
                            .frame(width: 22)
                        Text(tab.displayName)
                            .font(.system(size: 14.5, weight: selectedTab == tab ? .semibold : .regular))
                        Spacer()
                        if tab == .journal {
                            Text("\(store.database.entries.count)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        } else if tab == .gear && !store.database.pending.isEmpty {
                            Text("\(store.database.pending.count)")
                                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(ShaveTheme.amber.opacity(0.18)))
                                .foregroundStyle(ShaveTheme.amber)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 256)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    HStack(spacing: 6) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Button {
                                store.appearanceMode = mode
                            } label: {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(store.appearanceMode == mode ? ShaveTheme.accentSoft : Color.clear)
                                    )
                                    .foregroundStyle(store.appearanceMode == mode ? ShaveTheme.accent : .secondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .contentShape(Rectangle())
                            .help(mode.displayName)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        } detail: {
            ZStack(alignment: .bottom) {
                ShaveTheme.canvasBackground(scheme)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    if store.isReadOnlyProtected {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.shield.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(ShaveTheme.crimson)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.t("只读保护已启用：journal.json 读取失败", "Read-Only Protection Active: Failed to decode journal.json"))
                                    .font(.system(size: 13.5, weight: .semibold))
                                if let err = store.loadErrorMessage {
                                    Text(err)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Button(L10n.t("打开数据目录", "Open Folder")) {
                                NSWorkspace.shared.open(store.dataDirectoryURL)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Button(L10n.t("重新加载", "Retry")) {
                                store.load()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ShaveTheme.accent)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(ShaveTheme.crimson.opacity(scheme == .dark ? 0.18 : 0.10))
                        Divider()
                    }

                    Group {
                        switch selectedTab {
                        case .journal:
                            JournalView(onCreateNew: {
                                newEntryDraft = nil
                                showNewEntrySheet = true
                            })
                        case .gear:
                            GearLibraryView()
                        case .randomDraw:
                            RandomDrawView(onRecordSOTD: { draft in
                                newEntryDraft = draft
                                showNewEntrySheet = true
                            })
                        case .stats:
                            StatsView()
                        case .settings:
                            SettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 底部 Toast（单一 ToastState，非加载态 2.5 秒自动淡出，点 × 无条件立即关闭）
                if let toast = store.toast {
                    HStack(spacing: 10) {
                        if toast.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: store.isReadOnlyProtected ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(store.isReadOnlyProtected ? ShaveTheme.crimson : ShaveTheme.forest)
                        }
                        Text(toast.message)
                            .font(.system(size: 13.5, weight: .medium))
                        Button {
                            store.dismissToast()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .id(toast.id)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1))
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: store.toast)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await store.syncFromAppleNotes() }
                    } label: {
                        Label(
                            store.isSyncing ? L10n.t("同步中...", "Syncing...") : L10n.t("同步备忘录", "Sync Notes"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(store.isSyncing || store.isReadOnlyProtected)

                    Button {
                        newEntryDraft = nil
                        showNewEntrySheet = true
                    } label: {
                        Label(L10n.t("记一次 SOTD", "New SOTD"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .disabled(store.isReadOnlyProtected)
                }
            }
        }
        .task {
            await store.performStartupCloudSyncIfConfigured()
            await updateService.performSilentLaunchCheckIfEnabled()
        }
        .sheet(isPresented: $showNewEntrySheet) {
            EntryEditorSheet(editingEntry: nil, draft: newEntryDraft)
                .environmentObject(store)
        }
        .sheet(item: $updateService.availableRelease) { release in
            UpdateSheetView(release: release)
                .environmentObject(updateService)
                .environmentObject(store)
        }
        .alert(
            L10n.t("检查更新", "Check for Updates"),
            isPresented: Binding(
                get: { updateService.menuAlertMessage != nil },
                set: { if !$0 { updateService.menuAlertMessage = nil } }
            )
        ) {
            Button(L10n.t("好", "OK"), role: .cancel) {
                updateService.menuAlertMessage = nil
            }
        } message: {
            Text(updateService.menuAlertMessage ?? "")
        }
    }
}
