import SwiftUI

struct RandomDrawView: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let onRecordSOTD: (SOTDDraft) -> Void

    enum DrawMode: String, CaseIterable, Identifiable {
        case random
        case aiAdvisor
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .random: return L10n.t("随机抽签", "Random")
            case .aiAdvisor: return L10n.t("AI 推荐", "AI Advisor")
            }
        }
    }

    @State private var mode: DrawMode = .random

    // 随机抽签状态
    @State private var enabledCategories: Set<GearCategory> = Set(GearCategory.allCases)
    @State private var lockedCategories: Set<GearCategory> = []
    @State private var drawnItems: [GearCategory: GearItem] = [:]

    // AI 智能配装顾问状态
    @State private var advisorPrompt: String = ""
    @State private var isRecommending: Bool = false
    @State private var advisorError: String? = nil
    @State private var advisorReason: String = ""
    @State private var aiRecommendedItems: [GearCategory: GearItem] = [:]

    private var activeRazor: GearItem? {
        enabledCategories.contains(.razor) ? drawnItems[.razor] : nil
    }

    private var hasAnyDrawnItem: Bool {
        if mode == .random {
            return enabledCategories.contains { drawnItems[$0] != nil }
        }
        return !aiRecommendedItems.isEmpty
    }

    private var quickAdvisorPrompts: [(zh: String, en: String)] {
        [
            ("两天硬茬，要温和无痛 BBS", "2-day stubble, gentle painless BBS"),
            ("消灭长期吃灰的冷门器材", "Dust off neglected gear I rarely use"),
            ("清爽提神的搭配体验", "Fresh, crisp and uplifting shave"),
            ("经典高舒适度黄金组合", "Proven ultra-comfortable golden combo")
        ]
    }

    var body: some View {
        let _ = store.language
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 顶部标题 + 随机抽签 / AI 推荐双模式切换 + 操作按钮
                HStack(alignment: .center, spacing: 14) {
                    Text(L10n.t("随机抽签", "Randomizer"))
                        .font(.system(size: 26, weight: .bold, design: .rounded))

                    Picker("Mode", selection: $mode) {
                        ForEach(DrawMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)

                    Spacer()

                    HStack(spacing: 10) {
                        if mode == .random {
                            if !lockedCategories.isEmpty {
                                Button {
                                    lockedCategories.removeAll()
                                } label: {
                                    Label(L10n.t("全部解锁", "Unlock All"), systemImage: "lock.open")
                                        .font(.system(size: 13.5, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                            }

                            Button {
                                drawAll()
                            } label: {
                                Label(L10n.t("一次抽全套", "Roll All"), systemImage: "dice.fill")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(ShaveTheme.accent)
                            .controlSize(.large)
                            .disabled(enabledCategories.isEmpty)
                        }

                        Button {
                            onRecordSOTD(buildDraft())
                        } label: {
                            Label(L10n.t("用这套记 SOTD", "Log This Setup"), systemImage: "square.and.pencil")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!hasAnyDrawnItem || store.isReadOnlyProtected)
                    }
                }

                if mode == .random {
                    randomDrawBody
                } else {
                    aiAdvisorBody
                }
            }
            .padding(28)
        }
    }

    // MARK: - 随机抽签模式

    @ViewBuilder
    private var randomDrawBody: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.t("参与品类", "Categories"))
                        .font(.system(size: 14.5, weight: .semibold))
                    Spacer()
                    Button(L10n.t("全选", "All")) {
                        enabledCategories = Set(GearCategory.allCases)
                    }
                    .font(.system(size: 12.5))
                    .buttonStyle(.link)
                    Button(L10n.t("核心四件", "Core Four")) {
                        enabledCategories = [.razor, .blade, .brush, .soap]
                    }
                    .font(.system(size: 12.5))
                    .buttonStyle(.link)
                }

                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(GearCategory.allCases) { cat in
                        let isIncluded = enabledCategories.contains(cat)
                        let poolCount = store.eligibleDrawItems(
                            for: cat,
                            matchingRazor: cat == .blade ? activeRazor : nil
                        ).count

                        Button {
                            if isIncluded {
                                enabledCategories.remove(cat)
                                lockedCategories.remove(cat)
                            } else {
                                enabledCategories.insert(cat)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                Text(cat.displayName)
                                    .font(.system(size: 13, weight: isIncluded ? .semibold : .medium))
                                Text("\(poolCount)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(isIncluded ? ShaveTheme.accent.opacity(0.85) : .secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6.5)
                            .background(
                                Capsule().fill(isIncluded ? ShaveTheme.accentSoft : ShaveTheme.subtleSurface(scheme))
                            )
                            .overlay(
                                Capsule().stroke(isIncluded ? ShaveTheme.accent.opacity(0.38) : Color.clear, lineWidth: 1)
                            )
                            .foregroundStyle(isIncluded ? ShaveTheme.accent : .secondary)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }

        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 315, maximum: 440), spacing: 16)],
            spacing: 16
        ) {
            ForEach(GearCategory.allCases) { cat in
                if enabledCategories.contains(cat) {
                    DrawSlotCard(
                        category: cat,
                        item: drawnItems[cat],
                        isLocked: lockedCategories.contains(cat),
                        matchingRazor: cat == .blade ? activeRazor : nil,
                        eligibleCount: store.eligibleDrawItems(for: cat, matchingRazor: cat == .blade ? activeRazor : nil).count,
                        showControls: true,
                        onToggleLock: { toggleLock(cat) },
                        onRollSingle: { drawSingle(cat) }
                    )
                }
            }
        }
    }

    // MARK: - AI 智能配装顾问模式（AI 功能 ③）

    @ViewBuilder
    private var aiAdvisorBody: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 14) {
                if !store.aiConfig.isReady {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(ShaveTheme.accent)
                        Text(L10n.t("请先在「外观与设置 → AI 识别接口」启用并配置 API Key，即可使用 AI 智能配装顾问。", "Enable and configure your AI API key in Settings to use the AI Setup Advisor."))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 10) {
                        TextField(
                            L10n.t("描述今天的需求，例如：两天硬茬要温和无痛 BBS / 消灭吃灰器材...", "Describe what you want today, e.g., 2-day stubble gentle BBS..."),
                            text: $advisorPrompt
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5))
                        .onSubmit {
                            if !advisorPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRecommending {
                                Task { await runAIAdvisor() }
                            }
                        }

                        Button {
                            Task { await runAIAdvisor() }
                        } label: {
                            HStack(spacing: 6) {
                                if isRecommending { ProgressView().controlSize(.small) }
                                Label(
                                    isRecommending ? L10n.t("推荐中...", "Thinking...") : L10n.t("生成 AI 推荐", "Recommend"),
                                    systemImage: "sparkles"
                                )
                                .font(.system(size: 13.5, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaveTheme.accent)
                        .disabled(isRecommending || advisorPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(quickAdvisorPrompts, id: \.zh) { chip in
                            let text = L10n.t(chip.zh, chip.en)
                            Button {
                                advisorPrompt = text
                                Task { await runAIAdvisor() }
                            } label: {
                                Text(text)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(ShaveTheme.subtleSurface(scheme)))
                                    .foregroundStyle(.primary)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isRecommending)
                        }
                    }

                    if let err = advisorError {
                        Text(err)
                            .font(.system(size: 12.5))
                            .foregroundStyle(ShaveTheme.crimson)
                    }
                }
            }
        }

        if !advisorReason.isEmpty {
            SectionCard {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15))
                        .foregroundStyle(ShaveTheme.accent)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.t("AI 搭配理由", "Why This Setup"))
                            .font(.system(size: 14, weight: .semibold))
                        Text(advisorReason)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }

        if !aiRecommendedItems.isEmpty {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 315, maximum: 440), spacing: 16)],
                spacing: 16
            ) {
                ForEach(GearCategory.allCases) { cat in
                    if let item = aiRecommendedItems[cat] {
                        DrawSlotCard(
                            category: cat,
                            item: item,
                            isLocked: false,
                            matchingRazor: cat == .blade ? aiRecommendedItems[.razor] : nil,
                            eligibleCount: store.eligibleDrawItems(for: cat, matchingRazor: cat == .blade ? aiRecommendedItems[.razor] : nil).count,
                            showControls: false,
                            onToggleLock: {},
                            onRollSingle: {}
                        )
                    }
                }
            }
        }
    }

    private func runAIAdvisor() async {
        let req = advisorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !req.isEmpty else { return }

        isRecommending = true
        advisorError = nil
        defer { isRecommending = false }

        var eligible: [GearCategory: [GearItem]] = [:]
        for cat in GearCategory.allCases {
            eligible[cat] = store.eligibleDrawItems(for: cat)
        }

        do {
            let rec = try await WebGearRecognizer.shared.recommendSetup(
                requirement: req,
                eligibleByCategory: eligible,
                comboStats: store.razorBladeComboStats(),
                aiConfig: store.aiConfig
            )

            func findItem(_ cat: GearCategory, name: String?) -> GearItem? {
                guard let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
                let pool = eligible[cat] ?? []
                if let exact = pool.first(where: { $0.name.lowercased() == n.lowercased() }) { return exact }
                if let contains = pool.first(where: { $0.name.lowercased().contains(n.lowercased()) || n.lowercased().contains($0.name.lowercased()) }) { return contains }
                return nil
            }

            var mapped: [GearCategory: GearItem] = [:]
            if let r = findItem(.razor, name: rec.razorName) { mapped[.razor] = r }
            if let b = findItem(.blade, name: rec.bladeName) {
                // 二次硬校验：确保刀片类型与推荐剃须刀严格匹配
                if let r = mapped[.razor], let rt = r.razorType {
                    if rt.requiresBlade {
                        if let reqType = rt.matchingBladeType, b.bladeType != reqType {
                            mapped[.blade] = store.eligibleDrawItems(for: .blade, matchingRazor: r).first
                        } else {
                            mapped[.blade] = b
                        }
                    }
                } else {
                    mapped[.blade] = b
                }
            }
            if let br = findItem(.brush, name: rec.brushName) { mapped[.brush] = br }
            if let s = findItem(.soap, name: rec.soapName) { mapped[.soap] = s }
            if let bw = findItem(.bowl, name: rec.bowlName) { mapped[.bowl] = bw }
            if let pre = findItem(.preShave, name: rec.preShaveName) { mapped[.preShave] = pre }
            if let aft = findItem(.afterShave, name: rec.afterShaveName) { mapped[.afterShave] = aft }

            aiRecommendedItems = mapped
            advisorReason = rec.reason
        } catch {
            advisorError = error.localizedDescription
        }
    }

    private func toggleLock(_ category: GearCategory) {
        if lockedCategories.contains(category) {
            lockedCategories.remove(category)
        } else if drawnItems[category] != nil {
            lockedCategories.insert(category)
        }
    }

    private func drawAll() {
        if enabledCategories.contains(.razor) && !lockedCategories.contains(.razor) {
            drawSingleInternal(.razor, autoSyncBlade: false)
        }
        for cat in GearCategory.allCases where cat != .razor {
            guard enabledCategories.contains(cat) else { continue }
            if lockedCategories.contains(cat) { continue }
            drawSingleInternal(cat, autoSyncBlade: false)
        }
    }

    private func drawSingle(_ category: GearCategory) {
        drawSingleInternal(category, autoSyncBlade: true)
    }

    private func drawSingleInternal(_ category: GearCategory, autoSyncBlade: Bool) {
        let razorRef: GearItem? = (category == .blade) ? activeRazor : nil
        let pool = store.eligibleDrawItems(for: category, matchingRazor: razorRef)

        if pool.isEmpty {
            drawnItems.removeValue(forKey: category)
            lockedCategories.remove(category)
        } else {
            let currentID = drawnItems[category]?.id
            let candidates = (pool.count > 1 && currentID != nil)
                ? pool.filter { $0.id != currentID }
                : pool
            drawnItems[category] = candidates.randomElement()
        }

        if category == .razor && autoSyncBlade && enabledCategories.contains(.blade) && !lockedCategories.contains(.blade) {
            let newRazor = drawnItems[.razor]
            if let rType = newRazor?.razorType, !rType.requiresBlade {
                drawnItems.removeValue(forKey: .blade)
            } else if let requiredType = newRazor?.razorType?.matchingBladeType {
                if drawnItems[.blade]?.bladeType != requiredType {
                    drawSingleInternal(.blade, autoSyncBlade: false)
                }
            }
        }
    }

    private func buildDraft() -> SOTDDraft {
        if mode == .aiAdvisor {
            return SOTDDraft(
                razor: aiRecommendedItems[.razor]?.name ?? "",
                blade: aiRecommendedItems[.blade]?.name ?? "",
                brush: aiRecommendedItems[.brush]?.name ?? "",
                soap: aiRecommendedItems[.soap]?.name ?? "",
                preShave: aiRecommendedItems[.preShave]?.name ?? "",
                afterShave: aiRecommendedItems[.afterShave]?.name ?? "",
                bowl: aiRecommendedItems[.bowl]?.name ?? ""
            )
        }
        return SOTDDraft(
            razor: enabledCategories.contains(.razor) ? (drawnItems[.razor]?.name ?? "") : "",
            blade: enabledCategories.contains(.blade) ? (drawnItems[.blade]?.name ?? "") : "",
            brush: enabledCategories.contains(.brush) ? (drawnItems[.brush]?.name ?? "") : "",
            soap: enabledCategories.contains(.soap) ? (drawnItems[.soap]?.name ?? "") : "",
            preShave: enabledCategories.contains(.preShave) ? (drawnItems[.preShave]?.name ?? "") : "",
            afterShave: enabledCategories.contains(.afterShave) ? (drawnItems[.afterShave]?.name ?? "") : "",
            bowl: enabledCategories.contains(.bowl) ? (drawnItems[.bowl]?.name ?? "") : ""
        )
    }
}

private struct DrawSlotCard: View {
    @Environment(\.colorScheme) private var scheme

    let category: GearCategory
    let item: GearItem?
    let isLocked: Bool
    let matchingRazor: GearItem?
    let eligibleCount: Int
    var showControls: Bool = true
    let onToggleLock: () -> Void
    let onRollSingle: () -> Void

    private var bladeMatchNote: String? {
        guard category == .blade, let rt = matchingRazor?.razorType else { return nil }
        if !rt.requiresBlade {
            return L10n.t("直剃无需刀片", "No blade needed for Straight")
        }
        if let bt = rt.matchingBladeType {
            return L10n.t("匹配 \(bt.displayName) 刀片", "Matched: \(bt.displayName)")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(category.singularName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("\(eligibleCount)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer()

                if showControls {
                    Button(action: onToggleLock) {
                        Image(systemName: isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 13))
                            .foregroundStyle(isLocked ? ShaveTheme.accent : .secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(isLocked ? ShaveTheme.accentSoft : ShaveTheme.subtleSurface(scheme))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(item == nil)
                    .help(isLocked ? L10n.t("解锁", "Unlock") : L10n.t("锁定", "Lock"))

                    Button(action: onRollSingle) {
                        Text(L10n.t("单抽", "Roll"))
                            .font(.system(size: 12.5, weight: .medium))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(ShaveTheme.subtleSurface(scheme))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLocked || eligibleCount == 0)
                }
            }

            if let note = bladeMatchNote {
                TagPill(text: note, color: ShaveTheme.accent)
            }

            if let item = item {
                HStack(alignment: .center, spacing: 10) {
                    BrandAvatarView(brand: item.brand, size: 35, maxWidth: 56, category: category, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(L10n.brandDisplay(item.brand))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                            if category == .brush, let hb = item.handleBrand, !hb.isEmpty {
                                Text("×")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(L10n.handleTag(hb))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.primary.opacity(0.8))
                            }
                        }
                        HStack(spacing: 7) {
                            Text(item.model)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if category == .brush, let ks = item.knotSize, !ks.isEmpty {
                                Text(ks)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 7.5)
                                    .padding(.vertical, 2.5)
                                    .background(Capsule().fill(ShaveTheme.accentSoft))
                                    .foregroundStyle(ShaveTheme.accent)
                                    .fixedSize()
                            }
                            if category.supportsSample && item.isSample {
                                TagPill(text: L10n.t("小样", "Sample"), color: ShaveTheme.slate)
                                    .fixedSize()
                            }
                        }
                    }
                }

                let tags = GearSpecFormatter.specTags(for: item)
                if !tags.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                            TagPill(text: t, neutral: true)
                        }
                    }
                }

                Spacer(minLength: 0)

                HStack {
                    Text(L10n.t("\(item.count) 次", "\(item.count) uses"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !item.lastUsedDate.isEmpty {
                        Text(item.lastUsedDate)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Spacer(minLength: 6)
                    Text(emptyMessage)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(ShaveTheme.cardBackground(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isLocked ? ShaveTheme.accent.opacity(0.55) : ShaveTheme.cardBorder(scheme), lineWidth: isLocked ? 1.4 : 1)
        )
    }

    private var emptyMessage: String {
        if category == .blade, let rt = matchingRazor?.razorType, !rt.requiresBlade {
            return L10n.t("直剃无需匹配刀片", "Straight razor requires no blade")
        }
        if eligibleCount == 0 {
            return category == .blade
                ? L10n.t("无匹配库存刀片", "No matching in-stock blades")
                : L10n.t("无在用\(category.singularName)", "No active \(category.displayName.lowercased())")
        }
        return L10n.t("点击抽取", "Tap to roll")
    }
}
