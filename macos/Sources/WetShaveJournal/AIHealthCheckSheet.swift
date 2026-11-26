import SwiftUI

/// AI 功能 ①：全库 AI 体检 + 联网纠错 + 疑似重复合并建议 Diff 弹窗（S08：逐项状态统计 + 有限重试 + 支持取消）
struct AIHealthCheckSheet: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let initialCategory: GearCategory

    enum AuditScope: String, CaseIterable, Identifiable {
        case currentCategory
        case allPending
        var id: String { rawValue }
    }

    private static let maxRetryRounds = 3

    @State private var scope: AuditScope = .currentCategory
    @State private var isAuditing: Bool = false
    @State private var auditTask: Task<Void, Never>? = nil
    @State private var errorMessage: String? = nil
    @State private var modelUsed: String? = nil
    @State private var updates: [GearAuditUpdateProposal] = []
    @State private var merges: [GearAuditMergeProposal] = []
    @State private var hasCompleted: Bool = false

    // S08 细粒度体检统计与未完成项追踪
    @State private var plannedCount: Int = 0
    @State private var verifiedCount: Int = 0
    @State private var undeterminedItems: [GearItem] = []
    @State private var failedItems: [GearItem] = []
    @State private var skippedCount: Int = 0
    @State private var unknownOrDuplicateIDCount: Int = 0
    @State private var liveUndeterminedCount: Int = 0
    @State private var liveFailedCount: Int = 0
    @State private var currentBatch: Int = 0
    @State private var totalBatches: Int = 0
    @State private var batchFailures: [GearAuditBatchFailure] = []
    @State private var retryRound: Int = 0

    private var targetItems: [GearItem] {
        switch scope {
        case .currentCategory: return store.gearItems(for: initialCategory)
        case .allPending: return store.allPendingItems()
        }
    }

    private var retryableItems: [GearItem] {
        failedItems + undeterminedItems
    }

    private var selectedCount: Int {
        updates.filter(\.selected).count + merges.filter(\.selected).count
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.t("AI 器材库体检", "AI Gear Audit"))
                        .font(.system(size: 20, weight: .bold))
                    Text(L10n.t("核验官网命名、补齐缺失参数、识别疑似重复条目；确认勾选后再写入", "Verify naming, fill missing specs, and spot duplicates. Review diffs before applying."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let m = modelUsed {
                    TagPill(text: m, color: ShaveTheme.accent)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if !store.aiConfig.isReady {
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(ShaveTheme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.t("尚未启用 AI 识别接口", "AI Recognition API is Not Enabled"))
                                .font(.system(size: 14, weight: .semibold))
                            Text(L10n.t("请前往「外观与设置 → AI 识别接口」选择 DeepSeek 或其他 OpenAI 兼容服务、填写 API Key 并开启开关。", "Go to Settings → AI Recognition API, enter your API key, and enable it."))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(ShaveTheme.accentSoft))
                } else {
                    HStack(spacing: 12) {
                        Picker("Scope", selection: $scope) {
                            Text(L10n.t("当前分类：\(initialCategory.displayName) (\(store.gearItems(for: initialCategory).count))", "Current: \(initialCategory.displayName) (\(store.gearItems(for: initialCategory).count))"))
                                .tag(AuditScope.currentCategory)
                            Text(L10n.t("全部待确认 (\(store.allPendingItems().count))", "All Pending (\(store.allPendingItems().count))"))
                                .tag(AuditScope.allPending)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if isAuditing {
                            Button(L10n.t("取消体检", "Cancel")) {
                                auditTask?.cancel()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                startAuditTask()
                            } label: {
                                Text(L10n.t("开始 AI 体检", "Start Audit"))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ShaveTheme.accent)
                            .disabled(targetItems.isEmpty)
                        }
                    }
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 13))
                        .foregroundStyle(ShaveTheme.crimson)
                }

                if hasCompleted || isAuditing {
                    let displayedFailed = isAuditing ? liveFailedCount : failedItems.count
                    let displayedUndetermined = isAuditing ? liveUndeterminedCount : undeterminedItems.count
                    HStack(spacing: 8) {
                        TagPill(text: L10n.t("计划 \(plannedCount)", "Planned \(plannedCount)"), neutral: true)
                        TagPill(text: L10n.t("已核查 \(verifiedCount)", "Verified \(verifiedCount)"), color: ShaveTheme.forest)
                        if displayedUndetermined > 0 {
                            TagPill(text: L10n.t("无法判断 \(displayedUndetermined)", "Uncertain \(displayedUndetermined)"), color: ShaveTheme.amber)
                        }
                        TagPill(
                            text: L10n.t("失败 \(displayedFailed)", "Failed \(displayedFailed)"),
                            color: displayedFailed == 0 ? ShaveTheme.slate : ShaveTheme.crimson
                        )
                        TagPill(text: L10n.t("跳过 \(skippedCount)", "Skipped \(skippedCount)"), color: ShaveTheme.amber)
                        if unknownOrDuplicateIDCount > 0 {
                            TagPill(text: L10n.t("异常 ID \(unknownOrDuplicateIDCount)", "Bad IDs \(unknownOrDuplicateIDCount)"), color: ShaveTheme.crimson)
                        }
                        Spacer()
                        if !isAuditing && !retryableItems.isEmpty {
                            Button {
                                startRetryTask()
                            } label: {
                                Label(
                                    retryRound >= Self.maxRetryRounds
                                        ? L10n.t("已达重试上限 (\(Self.maxRetryRounds))", "Retry Limit (\(Self.maxRetryRounds))")
                                        : L10n.t("重试未完成项 (\(retryableItems.count))", "Retry Incomplete (\(retryableItems.count))"),
                                    systemImage: "arrow.clockwise"
                                )
                                .font(.system(size: 12.5, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ShaveTheme.amber)
                            .disabled(isAuditing || retryRound >= Self.maxRetryRounds)
                        }
                    }

                    if !isAuditing && !batchFailures.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(
                                L10n.t("有 \(batchFailures.count) 个批次（共 \(failedItems.count) 件器材）未完成解析或被遗漏：", "\(batchFailures.count) batch(es) (\(failedItems.count) items) failed or omitted:"),
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(ShaveTheme.crimson)

                            ForEach(batchFailures) { f in
                                Text(L10n.t("• 第 \(f.batchIndex) 批（\(f.items.count) 件）：\(f.reason)", "• Batch #\(f.batchIndex) (\(f.items.count) items): \(f.reason)"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ShaveTheme.crimson.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ShaveTheme.crimson.opacity(0.32), lineWidth: 1))
                    }
                }

                if isAuditing {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                        if totalBatches > 0 {
                            Text(L10n.t(
                                "正在调用 AI 核验第 \(currentBatch)/\(totalBatches) 批（每批小块处理，高思考模型请稍候）...",
                                "Auditing batch \(currentBatch)/\(totalBatches) via AI..."
                            ))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                        } else {
                            Text(L10n.t("正在调用 AI 核验器材的官网规格与重复项...", "Auditing gear items via AI..."))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasCompleted && updates.isEmpty && merges.isEmpty && retryableItems.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(ShaveTheme.forest)
                        Text(L10n.t("全部器材命名与参数均很规范，暂未发现需要修正或合并的条目", "All checked items look clean — no fixes or merges needed."))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasCompleted && updates.isEmpty && merges.isEmpty && !retryableItems.isEmpty {
                    VStack(spacing: 10) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(ShaveTheme.amber)
                        Text(L10n.t("部分或全部器材未能完成核验（失败 \(failedItems.count)、无法判断 \(undeterminedItems.count)），请查看原因或点击重试", "Some items could not be verified (\(failedItems.count) failed, \(undeterminedItems.count) uncertain). Review reasons or retry."))
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !updates.isEmpty || !merges.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if !updates.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(L10n.t("规范纠错与属性补全建议（\(updates.count)）", "Naming & Spec Improvements (\(updates.count))"))
                                        .font(.system(size: 15, weight: .semibold))

                                    ForEach($updates) { $proposal in
                                        HStack(alignment: .top, spacing: 12) {
                                            Toggle("", isOn: $proposal.selected)
                                                .labelsHidden()
                                                .padding(.top, 2)

                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(spacing: 8) {
                                                    Text("\(L10n.brandDisplay(proposal.item.brand)) · \(proposal.item.model)")
                                                        .font(.system(size: 14, weight: .semibold))
                                                    TagPill(
                                                        text: "\(Int(proposal.confidence * 100))%",
                                                        color: proposal.confidence >= 0.72 ? ShaveTheme.forest : ShaveTheme.amber
                                                    )
                                                    if proposal.item.isManuallyConfirmed {
                                                        TagPill(text: L10n.t("已人工确认", "Manual"), color: ShaveTheme.slate)
                                                    }
                                                }

                                                VStack(alignment: .leading, spacing: 3) {
                                                    ForEach(proposal.changesSummary, id: \.self) { line in
                                                        Text("• \(line)")
                                                            .font(.system(size: 12.5, design: .monospaced))
                                                            .foregroundStyle(.primary)
                                                    }
                                                }

                                                Text(proposal.reason)
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(13)
                                        .background(RoundedRectangle(cornerRadius: 11).fill(ShaveTheme.cardBackground(scheme)))
                                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1))
                                    }
                                }
                            }

                            if !merges.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(L10n.t("疑似重复合并建议（\(merges.count)）", "Suspected Duplicate Merges (\(merges.count))"))
                                        .font(.system(size: 15, weight: .semibold))

                                    ForEach($merges) { $m in
                                        HStack(alignment: .top, spacing: 12) {
                                            Toggle("", isOn: $m.selected)
                                                .labelsHidden()
                                                .padding(.top, 2)

                                            VStack(alignment: .leading, spacing: 5) {
                                                HStack(spacing: 6) {
                                                    Text(m.source.name)
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                    Image(systemName: "arrow.right")
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(ShaveTheme.accent)
                                                    Text(m.target.name)
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                        .foregroundStyle(ShaveTheme.accent)
                                                }
                                                Text(m.reason)
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(13)
                                        .background(RoundedRectangle(cornerRadius: 11).fill(ShaveTheme.cardBackground(scheme)))
                                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Spacer()
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if hasCompleted && (!updates.isEmpty || !merges.isEmpty) {
                    Text(L10n.t("已勾选 \(selectedCount) 项改动", "\(selectedCount) changes selected"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("关闭", "Close")) {
                    auditTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                if !updates.isEmpty || !merges.isEmpty {
                    Button(L10n.t("应用选中修改", "Apply Selected")) {
                        errorMessage = nil
                        switch store.applyAuditProposals(updates: updates, merges: merges) {
                        case .success:
                            dismiss()
                        case .failure(let error):
                            errorMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .disabled(selectedCount == 0 || store.isReadOnlyProtected)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 740, height: 650)
        .onDisappear { auditTask?.cancel() }
    }

    private func startAuditTask() {
        auditTask?.cancel()
        auditTask = Task { await runAudit() }
    }

    private func startRetryTask() {
        auditTask?.cancel()
        auditTask = Task { await retryIncompleteItems() }
    }

    private func runAudit() async {
        let itemsToAudit = targetItems
        isAuditing = true
        errorMessage = nil
        hasCompleted = false
        updates = []
        merges = []
        undeterminedItems = []
        failedItems = []
        batchFailures = []
        plannedCount = itemsToAudit.count
        verifiedCount = 0
        skippedCount = 0
        unknownOrDuplicateIDCount = 0
        liveUndeterminedCount = 0
        liveFailedCount = 0
        currentBatch = 0
        totalBatches = 0
        retryRound = 0
        defer { isAuditing = false }

        do {
            let report = try await WebGearRecognizer.shared.auditGearItems(
                items: itemsToAudit,
                aiConfig: store.aiConfig
            ) { progress in
                currentBatch = progress.currentBatch
                totalBatches = progress.totalBatches
                verifiedCount = progress.verifiedCount
                liveUndeterminedCount = progress.undeterminedCount
                liveFailedCount = progress.failedCount
                skippedCount = progress.skippedCount
            }
            updates = report.updates
            merges = report.merges
            modelUsed = report.modelUsed
            plannedCount = report.plannedCount
            verifiedCount = report.verifiedCount
            undeterminedItems = report.undeterminedItems
            failedItems = report.failedItems
            skippedCount = report.skippedCount
            unknownOrDuplicateIDCount = report.unknownOrDuplicateIDCount
            liveUndeterminedCount = report.undeterminedItems.count
            liveFailedCount = report.failedItems.count
            batchFailures = report.failures
            hasCompleted = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retryIncompleteItems() async {
        guard !retryableItems.isEmpty, retryRound < Self.maxRetryRounds else { return }
        retryRound += 1
        let itemsToRetry = retryableItems
        let baseVerified = verifiedCount
        let baseSkipped = skippedCount
        let baseBadIDs = unknownOrDuplicateIDCount
        isAuditing = true
        errorMessage = nil
        liveFailedCount = failedItems.count
        liveUndeterminedCount = undeterminedItems.count
        currentBatch = 0
        totalBatches = 0
        defer { isAuditing = false }

        do {
            let report = try await WebGearRecognizer.shared.auditGearItems(
                items: itemsToRetry,
                aiConfig: store.aiConfig
            ) { progress in
                currentBatch = progress.currentBatch
                totalBatches = progress.totalBatches
                verifiedCount = baseVerified + progress.verifiedCount
                skippedCount = baseSkipped + progress.skippedCount
                liveUndeterminedCount = progress.undeterminedCount
                liveFailedCount = progress.failedCount
            }
            modelUsed = report.modelUsed
            verifiedCount = baseVerified + report.verifiedCount
            skippedCount = baseSkipped + report.skippedCount
            unknownOrDuplicateIDCount = baseBadIDs + report.unknownOrDuplicateIDCount
            undeterminedItems = report.undeterminedItems
            failedItems = report.failedItems
            liveUndeterminedCount = report.undeterminedItems.count
            liveFailedCount = report.failedItems.count
            batchFailures = report.failures

            for u in report.updates {
                if let idx = updates.firstIndex(where: { $0.id == u.id }) {
                    updates[idx] = u
                } else {
                    updates.append(u)
                }
            }
            for m in report.merges {
                if !merges.contains(where: { $0.id == m.id }) {
                    merges.append(m)
                }
            }
            hasCompleted = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
