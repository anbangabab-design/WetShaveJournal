import SwiftUI
import AppKit

/// FlClash 风格原生更新弹窗 Sheet（R06：独立视图文件，展示版本对比、双语更新日志、下载进度与 SHA-256 一致性校验状态）
struct UpdateSheetView: View {
    @EnvironmentObject var updateService: UpdateService
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let release: GitHubReleaseInfo

    private var appIconImage: NSImage {
        if let icnsPath = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
           let img = NSImage(contentsOfFile: icnsPath) {
            return img
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: appIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.t("发现新版本 v\(release.version)", "Update Available: v\(release.version)"))
                        .font(.system(size: 18, weight: .bold))

                    HStack(spacing: 6) {
                        TagPill(text: L10n.t("当前 v\(AppMetadata.version)", "Current v\(AppMetadata.version)"), neutral: true)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TagPill(text: "v\(release.version)", color: ShaveTheme.accent)

                        if let asset = release.matchedAsset {
                            Text(asset.size > 0
                                 ? "· \(asset.name) (\(UpdateService.formatMB(asset.size)))"
                                 : "· \(asset.name)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.t("更新日志", "Release Notes"))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if release.hasTrustedDigest {
                        TagPill(text: L10n.t("支持 SHA-256 校验", "SHA-256 Verified"), color: ShaveTheme.forest)
                    } else if release.isFromWebFallback {
                        TagPill(text: L10n.t("网页通道（需手动核验）", "Web Fallback (Manual Verify)"), color: ShaveTheme.amber)
                    }
                }

                let displayedNotes = UpdateService.localizedReleaseNotes(from: release.body, isEnglish: L10n.isEnglish)
                ScrollView {
                    Text(
                        displayedNotes.isEmpty
                            ? L10n.t("点击下方「前往发布页」查看完整更新说明。", "Click \"Release Page\" below to view full release notes.")
                            : displayedNotes
                    )
                    .font(.system(size: 13.5))
                    .lineSpacing(4)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
                }
                .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1))

                switch updateService.downloadState {
                case .idle:
                    if release.hasDirectAsset && !release.hasTrustedDigest {
                        HStack(spacing: 8) {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(ShaveTheme.amber)
                            Text(L10n.t(
                                "当前通过网页通道获取版本且暂未获取到 SHA-256 摘要，点击下载将先尝试通过 GitHub API 或同 Release 的 SHA256SUMS.txt 恢复摘要；若仍无法校验将不会自动打开安装包。",
                                "Fetched via web fallback without a SHA-256 digest yet. Downloading will first attempt to retrieve the digest via GitHub API or the Release's SHA256SUMS.txt; unverified installers will not auto-open."
                            ))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.amber.opacity(0.08)))
                    }

                case .downloading(let progress, let downloaded, let total):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L10n.t("正在下载更新包...", "Downloading update..."))
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            if total > 0 {
                                Text("\(Int(progress * 100))% · \(UpdateService.formatMB(downloaded)) / \(UpdateService.formatMB(total))")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(UpdateService.formatMB(downloaded))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if total > 0 {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .tint(ShaveTheme.accent)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(ShaveTheme.accent)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.accentSoft))

                case .verifying:
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L10n.t("正在校验安装包大小与 SHA-256 摘要...", "Verifying installer size and SHA-256 checksum..."))
                            .font(.system(size: 12.5, weight: .medium))
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.accentSoft))

                case .completed(let fileURL, let sha256Hex):
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(ShaveTheme.forest)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("已通过 SHA-256 一致性校验并打开安装包", "SHA-256 verified against Release metadata; installer opened"))
                                .font(.system(size: 12.5, weight: .semibold))
                            Text(L10n.t(
                                "SHA-256: \(sha256Hex.prefix(16))…（校验与 Release 元数据一致；请拖入「应用程序」或按向导覆盖安装后重启）",
                                "SHA-256: \(sha256Hex.prefix(16))… (matches Release metadata; drag to Applications or finish installing and restart)"
                            ))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.t("在访达中显示", "Reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.forest.opacity(0.10)))

                case .failed(let message):
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(ShaveTheme.crimson)
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(ShaveTheme.crimson)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.crimson.opacity(0.08)))
                }
            }
            .padding(22)

            Divider()

            HStack(spacing: 10) {
                Button(L10n.t("忽略此版本", "Ignore This Version")) {
                    updateService.ignoreVersion(release.version)
                }
                .buttonStyle(.bordered)
                .disabled(updateService.downloadState.isBusy)

                Spacer()

                if updateService.downloadState.isBusy {
                    Button(L10n.t("取消", "Cancel")) {
                        updateService.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button(L10n.t("前往发布页", "Release Page")) {
                        NSWorkspace.shared.open(release.htmlURL)
                    }
                    .buttonStyle(.bordered)

                    if case .completed = updateService.downloadState {
                        Button(L10n.t("完成", "Done")) {
                            updateService.dismissSheet()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaveTheme.accent)
                        .keyboardShortcut(.defaultAction)
                    } else if release.hasDirectAsset {
                        Button {
                            updateService.startDownload(for: release)
                        } label: {
                            Label(L10n.t("安全下载并校验", "Download & Verify"), systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaveTheme.accent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button {
                            NSWorkspace.shared.open(release.htmlURL)
                            updateService.dismissSheet()
                        } label: {
                            Label(L10n.t("前往下载", "Open Release Page"), systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaveTheme.accent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 530)
    }
}
