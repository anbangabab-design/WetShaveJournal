import SwiftUI
import AppKit

// MARK: - 单品牌 AI 智能找图弹窗（从器材编辑页触发，支持中灰底候选对比、实时去边/圆裁预览与一键落盘 CustomLogos/）

struct AILogoFinderSheet: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let initialBrand: String
    let category: GearCategory?
    var onSaved: ((String) -> Void)? = nil

    @State private var queryBrand: String = ""
    @State private var isSearching: Bool = false
    @State private var progressText: String = ""
    @State private var searchResult: AILogoSearchResult? = nil
    @State private var selectedCandidateID: UUID? = nil

    // 实时处理选项（基于选中候选原图即时重算 256px PNG）
    @State private var trimMode: LogoTrimMode = .auto
    @State private var applyCircularMask: Bool = false
    @State private var processedPreview: (image: NSImage, pngData: Data)? = nil

    private var selectedCandidate: BrandLogoCandidate? {
        guard let res = searchResult else { return nil }
        if let id = selectedCandidateID, let hit = res.candidates.first(where: { $0.id == id }) {
            return hit
        }
        return res.candidates.first
    }

    private var targetBrandName: String {
        let trimmed = queryBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? initialBrand.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            // 顶部标题 + 品牌检索栏
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(ShaveTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.t("AI 智能品牌找图", "AI Brand Logo Finder"))
                            .font(.system(size: 17, weight: .bold))
                        Text(L10n.t(
                            "联网检索官网页头 / 直链 / Wayback 归档，自动去边规范化为 256px PNG 并支持视觉自检",
                            "Searches official headers, direct CDN links & Wayback archives, auto-trims to 256px PNG with AI vision audit"
                        ))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField(L10n.t("输入品牌名（英文原名命中率更高）", "Brand name (official name recommended)"), text: $queryBrand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5))
                        .onSubmit {
                            Task { await runSearch() }
                        }

                    Button {
                        Task { await runSearch() }
                    } label: {
                        HStack(spacing: 5) {
                            if isSearching {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text(isSearching ? L10n.t("检索中…", "Searching…") : L10n.t("开始找图", "Find Logo"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .disabled(isSearching || targetBrandName.isEmpty)
                }

                if !store.aiConfig.isReady {
                    Label(
                        L10n.t("当前未启用 AI 接口，将仅使用内置白名单官网与 Wayback 归档提取；可在「设置」开启 AI 联网获得更高命中率",
                               "AI API is not enabled; using known official sites & Wayback archive only. Enable AI in Settings for full web discovery."),
                        systemImage: "info.circle.fill"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(ShaveTheme.amber)
                }
            }
            .padding(18)

            Divider()

            // 主体内容区：加载态 / 候选图网格（中灰底）+ 底部精修与三背景预览
            if isSearching {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView()
                        .controlSize(.large)
                    Text(progressText.isEmpty ? L10n.t("正在检索官方品牌图标…", "Searching official brand logos…") : progressText)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let res = searchResult {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // AI 摘要与官网链接
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: res.visionVerified ? "checkmark.seal.fill" : (res.candidates.isEmpty ? "exclamationmark.triangle.fill" : "photo.stack"))
                                .foregroundStyle(res.visionVerified ? ShaveTheme.forest : (res.candidates.isEmpty ? ShaveTheme.amber : ShaveTheme.accent))
                            Text(res.summary)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            if let siteStr = res.officialSiteURL, let url = URL(string: siteStr) {
                                Button(L10n.t("打开官网", "Open Site")) {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 12))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(ShaveTheme.subtleSurface(scheme))
                        )

                        if res.candidates.isEmpty {
                            ContentUnavailableView(
                                L10n.t("未找到可用候选图标", "No Usable Logo Candidates Found"),
                                systemImage: "photo.badge.exclamationmark",
                                description: Text(L10n.t(
                                    "可尝试改用品牌完整英文名重新检索，或直接在器材编辑页点击「更换图标」手动上传本地图片。",
                                    "Try searching with the full official English brand name, or upload a local PNG via Custom Icon."
                                ))
                            )
                            .padding(.vertical, 28)
                        } else {
                            // 候选图网格（中灰底，白标与黑标一目了然）
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 155, maximum: 195), spacing: 12)],
                                spacing: 12
                            ) {
                                ForEach(res.candidates) { cand in
                                    let isSelected = selectedCandidate?.id == cand.id
                                    Button {
                                        selectCandidate(cand)
                                    } label: {
                                        VStack(spacing: 7) {
                                            ZStack(alignment: .topTrailing) {
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .fill(Color(white: 0.52))
                                                    .frame(height: 98)
                                                    .overlay(
                                                        Image(nsImage: cand.normalizedImage)
                                                            .resizable()
                                                            .interpolation(.high)
                                                            .scaledToFit()
                                                            .padding(10)
                                                    )

                                                if cand.aiRecommended {
                                                    Text(L10n.t("AI 推荐", "AI Pick"))
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2.5)
                                                        .background(Capsule().fill(ShaveTheme.forest))
                                                        .padding(6)
                                                }
                                            }

                                            HStack(spacing: 4) {
                                                Text(cand.source.displayName)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Spacer()
                                                Text("\(cand.pixelWidth)×\(cand.pixelHeight)")
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .fill(isSelected ? ShaveTheme.accentSoft : ShaveTheme.cardBackground(scheme))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                                .stroke(isSelected ? ShaveTheme.accent : ShaveTheme.cardBorder(scheme), lineWidth: isSelected ? 2 : 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // 选中候选的实时微调与三背景验收条（浅色 / 中灰 / 深色）
                            if let active = selectedCandidate {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 12) {
                                        Text(L10n.t("实时精修与三底色验收", "Refine & Preview"))
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        Picker("", selection: $trimMode) {
                                            ForEach(LogoTrimMode.allCases) { m in
                                                Text(m.displayName).tag(m)
                                            }
                                        }
                                        .labelsHidden()
                                        .frame(width: 118)

                                        Toggle(L10n.t("圆形裁切", "Circle Mask"), isOn: $applyCircularMask)
                                            .toggleStyle(.checkbox)
                                            .font(.system(size: 12.5))
                                    }

                                    let previewImg = processedPreview?.image ?? active.normalizedImage
                                    HStack(spacing: 10) {
                                        backdropSwatch(title: L10n.t("浅色卡片", "Light"), bg: Color.white, img: previewImg, darkBg: false)
                                        backdropSwatch(title: L10n.t("中灰验收", "Mid Gray"), bg: Color(white: 0.52), img: previewImg, darkBg: false)
                                        backdropSwatch(title: L10n.t("深色卡片", "Dark"), bg: Color(red: 0.145, green: 0.149, blue: 0.160), img: previewImg, darkBg: true)
                                    }
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(ShaveTheme.subtleSurface(scheme))
                                )
                            }
                        }
                    }
                    .padding(18)
                }
            } else {
                Spacer()
            }

            Divider()

            // 底部操作栏
            HStack {
                Button(L10n.t("取消", "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if let active = selectedCandidate {
                    let finalData = processedPreview?.pngData ?? active.pngData
                    Button {
                        let saveBrand = initialBrand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? targetBrandName
                            : initialBrand.trimmingCharacters(in: .whitespacesAndNewlines)
                        if BrandLogoCache.shared.setCustomLogoData(finalData, for: saveBrand) {
                            store.showToast(
                                L10n.t("已保存「\(saveBrand)」的永久品牌图标（256px PNG）", "Saved permanent logo for \(saveBrand) (256px PNG)"),
                                isLoading: false
                            )
                            onSaved?(saveBrand)
                            dismiss()
                        } else {
                            store.showToast(L10n.t("保存品牌图标失败", "Failed to save brand logo"), isLoading: false)
                        }
                    } label: {
                        Label(L10n.t("设为永久品牌图标", "Save as Brand Logo"), systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .frame(width: 640, height: 570)
        .onAppear {
            queryBrand = initialBrand
            if !initialBrand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Task { await runSearch() }
            }
        }
        .onChange(of: trimMode) { _, _ in recomputeProcessedPreview() }
        .onChange(of: applyCircularMask) { _, _ in recomputeProcessedPreview() }
    }

    @ViewBuilder
    private func backdropSwatch(title: String, bg: Color, img: NSImage, darkBg: Bool) -> some View {
        let shouldInvert = (darkBg && BrandLogoCache.shared.shouldInvertInDarkMode(image: img))
            || (!darkBg && bg == Color.white && BrandLogoCache.shared.shouldInvertInLightMode(image: img))
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(bg)
                .frame(height: 66)
                .overlay(
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .modifier(PreviewInvertModifier(isEnabled: shouldInvert))
                        .frame(maxWidth: 110, maxHeight: 46)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
                )
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func selectCandidate(_ cand: BrandLogoCandidate) {
        selectedCandidateID = cand.id
        trimMode = .auto
        applyCircularMask = cand.aiSuggestedCircular
        recomputeProcessedPreview()
    }

    private func recomputeProcessedPreview() {
        guard let active = selectedCandidate else {
            processedPreview = nil
            return
        }
        if let rebuilt = BrandLogoImageProcessor.normalizeLogo(
            active.rawImage,
            trimMode: trimMode,
            cropRect: active.aiCropRect,
            circularMask: applyCircularMask,
            maxLongEdge: 256
        ) {
            processedPreview = rebuilt
        } else {
            processedPreview = (active.normalizedImage, active.pngData)
        }
    }

    private func runSearch() async {
        let target = targetBrandName
        guard !target.isEmpty else { return }
        isSearching = true
        progressText = L10n.t("准备检索「\(target)」…", "Preparing search for \(target)…")
        searchResult = nil
        selectedCandidateID = nil
        processedPreview = nil

        let result = await AILogoFinderService.shared.findLogoCandidates(
            for: target,
            category: category,
            aiConfig: store.aiConfig,
            onProgress: { msg in
                Task { @MainActor in
                    progressText = msg
                }
            }
        )
        searchResult = result
        if let recID = result.recommendedCandidateID,
           let rec = result.candidates.first(where: { $0.id == recID }) {
            selectCandidate(rec)
        } else if let first = result.candidates.first {
            selectCandidate(first)
        }
        isSearching = false
    }
}

// MARK: - 批量 AI 补全缺失品牌 Logo 弹窗（从设置页触发，中灰底验收网格 + 一键应用勾选）

struct AIBatchLogoFinderSheet: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private struct MissingBrandEntry: Identifiable {
        let id: String
        let brand: String
        let category: GearCategory
        let itemCount: Int
        var selected: Bool
    }

    private struct BatchBrandResult: Identifiable {
        let id: String
        let brand: String
        let category: GearCategory
        let searchResult: AILogoSearchResult
        var candidateIndex: Int
        var circularMask: Bool
        var approved: Bool

        var activeCandidate: BrandLogoCandidate? {
            guard !searchResult.candidates.isEmpty else { return nil }
            let safeIdx = max(0, min(searchResult.candidates.count - 1, candidateIndex))
            return searchResult.candidates[safeIdx]
        }

        var renderedImageAndPNG: (NSImage, Data)? {
            guard let cand = activeCandidate else { return nil }
            if !circularMask {
                return (cand.normalizedImage, cand.pngData)
            }
            if let masked = BrandLogoImageProcessor.normalizeLogo(
                cand.rawImage,
                trimMode: .auto,
                cropRect: cand.aiCropRect,
                circularMask: true,
                maxLongEdge: 256
            ) {
                return masked
            }
            return (cand.normalizedImage, cand.pngData)
        }
    }

    @State private var missingBrands: [MissingBrandEntry] = []
    @State private var isRunning: Bool = false
    @State private var currentProgressIndex: Int = 0
    @State private var totalPlanned: Int = 0
    @State private var currentStatusText: String = ""
    @State private var results: [BatchBrandResult] = []
    @State private var runningTask: Task<Void, Never>? = nil

    private var selectedMissingCount: Int {
        missingBrands.filter(\.selected).count
    }

    private var approvedResultCount: Int {
        results.filter { $0.approved && $0.activeCandidate != nil }.count
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18))
                    .foregroundStyle(ShaveTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("AI 批量补全缺失品牌 Logo", "AI Batch Logo Finder"))
                        .font(.system(size: 17, weight: .bold))
                    Text(L10n.t(
                        "自动扫描器材库中仍显示字母圈的品牌，批量联网寻源、视觉核验并生成中灰底验收拼图",
                        "Scans monogram-only brands, fetches official logos with AI audit, and displays a mid-gray review grid"
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            if isRunning {
                VStack(spacing: 14) {
                    Spacer()
                    ProgressView(value: Double(currentProgressIndex), total: Double(max(1, totalPlanned)))
                        .frame(width: 340)
                    Text(L10n.t("正在处理 \(currentProgressIndex) / \(totalPlanned)：\(currentStatusText)", "Processing \(currentProgressIndex) / \(totalPlanned): \(currentStatusText)"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button(L10n.t("停止检索", "Stop")) {
                        runningTask?.cancel()
                        isRunning = false
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !results.isEmpty {
                // 结果中灰底验收网格
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 185, maximum: 225), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach($results) { $res in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Toggle("", isOn: $res.approved)
                                        .labelsHidden()
                                        .disabled(res.activeCandidate == nil)
                                    Text(res.brand)
                                        .font(.system(size: 12.5, weight: .bold))
                                        .lineLimit(1)
                                    Spacer()
                                    if res.searchResult.visionVerified && res.activeCandidate?.aiRecommended == true {
                                        Image(systemName: "checkmark.seal.fill")
                                            .font(.system(size: 12))
                                            .foregroundStyle(ShaveTheme.forest)
                                            .help(L10n.t("AI 视觉已核验通过", "Verified by AI Vision"))
                                    }
                                }

                                ZStack {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color(white: 0.52))
                                        .frame(height: 100)
                                    if let pair = res.renderedImageAndPNG {
                                        Image(nsImage: pair.0)
                                            .resizable()
                                            .interpolation(.high)
                                            .scaledToFit()
                                            .padding(10)
                                    } else {
                                        Text(L10n.t("未命中", "Not Found"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                }

                                HStack(spacing: 6) {
                                    if let cand = res.activeCandidate {
                                        Text(cand.source.displayName)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Button(L10n.t("圆裁", "Circle")) {
                                            res.circularMask.toggle()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .tint(res.circularMask ? ShaveTheme.accent : nil)

                                        if res.searchResult.candidates.count > 1 {
                                            Button(L10n.t("换图", "Next")) {
                                                res.candidateIndex = (res.candidateIndex + 1) % res.searchResult.candidates.count
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                        }
                                    } else {
                                        Text(L10n.t("保留字母徽章", "Keep monogram"))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(ShaveTheme.cardBackground(scheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(res.approved && res.activeCandidate != nil ? ShaveTheme.accent.opacity(0.65) : ShaveTheme.cardBorder(scheme), lineWidth: 1.2)
                            )
                        }
                    }
                    .padding(18)
                }
            } else if missingBrands.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    ContentUnavailableView(
                        L10n.t("所有品牌都已有专属 Logo", "All Brands Already Have Logos"),
                        systemImage: "checkmark.seal.fill",
                        description: Text(L10n.t(
                            "当前器材库中未发现缺失 Logo 的有效品牌；如需更换单个品牌的图标，可在器材编辑页点击「AI 找图」。",
                            "No missing brand logos detected. To replace a specific brand's logo, use AI Find Logo in Gear Editor."
                        ))
                    )
                    Spacer()
                }
            } else {
                // 待补全品牌勾选列表
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L10n.t("发现 \(missingBrands.count) 个当前仅显示字母徽章的品牌：", "Found \(missingBrands.count) brands without logos:"))
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button(L10n.t("全选", "Select All")) {
                            for i in missingBrands.indices { missingBrands[i].selected = true }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        Button(L10n.t("全不选", "Deselect")) {
                            for i in missingBrands.indices { missingBrands[i].selected = false }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                    List($missingBrands) { $entry in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $entry.selected)
                                .labelsHidden()
                            BrandAvatarView(brand: entry.brand, size: 24, category: entry.category)
                            Text(entry.brand)
                                .font(.system(size: 13.5, weight: .medium))
                            Spacer()
                            TagPill(text: entry.category.singularName, neutral: true)
                            Text(L10n.t("\(entry.itemCount) 件", "\(entry.itemCount)"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Divider()

            HStack {
                Button(L10n.t("关闭", "Close")) {
                    runningTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if !results.isEmpty && !isRunning {
                    Button(L10n.t("重新扫描", "Rescan")) {
                        results = []
                        scanMissingBrands()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if results.isEmpty {
                    Button {
                        startBatchSearch()
                    } label: {
                        Label(
                            L10n.t("开始 AI 找图 (\(selectedMissingCount))", "Start AI Logo Search (\(selectedMissingCount))"),
                            systemImage: "sparkles"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .disabled(isRunning || selectedMissingCount == 0)
                } else if !isRunning {
                    Button {
                        applyApprovedResults()
                    } label: {
                        Label(
                            L10n.t("保存勾选图标 (\(approvedResultCount))", "Save Approved Logos (\(approvedResultCount))"),
                            systemImage: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .disabled(approvedResultCount == 0)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
        }
        .frame(width: 720, height: 580)
        .onAppear {
            scanMissingBrands()
        }
        .onDisappear {
            runningTask?.cancel()
        }
    }

    private func scanMissingBrands() {
        var counts: [String: (brand: String, category: GearCategory, count: Int)] = [:]
        for cat in GearCategory.allCases {
            for item in store.gearItems(for: cat) {
                let b = item.brand.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !BrandLogoCache.shouldSkipBrand(b) else { continue }
                guard !BrandLogoCache.shared.hasAnyLogo(for: b) else { continue }
                let key = BrandLogoCache.asciiBrandKey(b)
                if var existing = counts[key] {
                    existing.count += 1
                    counts[key] = existing
                } else {
                    counts[key] = (b, cat, 1)
                }
            }
        }
        missingBrands = counts.values
            .sorted { ($0.count, $1.brand.lowercased()) > ($1.count, $0.brand.lowercased()) }
            .map { MissingBrandEntry(id: BrandLogoCache.asciiBrandKey($0.brand), brand: $0.brand, category: $0.category, itemCount: $0.count, selected: true) }
    }

    private func startBatchSearch() {
        let targets = missingBrands.filter(\.selected)
        guard !targets.isEmpty else { return }
        isRunning = true
        results = []
        totalPlanned = targets.count
        currentProgressIndex = 0

        let aiConfig = store.aiConfig
        runningTask = Task {
            var collected: [BatchBrandResult] = []
            for (idx, target) in targets.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    currentProgressIndex = idx + 1
                    currentStatusText = target.brand
                }
                let res = await AILogoFinderService.shared.findLogoCandidates(
                    for: target.brand,
                    category: target.category,
                    aiConfig: aiConfig
                )
                let bestIdx: Int = {
                    if let recID = res.recommendedCandidateID,
                       let foundIdx = res.candidates.firstIndex(where: { $0.id == recID }) {
                        return foundIdx
                    }
                    return 0
                }()
                let shouldPreApprove = !res.candidates.isEmpty && (res.recommendedCandidateID != nil)
                let defaultCircular = res.candidates.indices.contains(bestIdx) ? res.candidates[bestIdx].aiSuggestedCircular : false
                collected.append(BatchBrandResult(
                    id: target.id,
                    brand: target.brand,
                    category: target.category,
                    searchResult: res,
                    candidateIndex: bestIdx,
                    circularMask: defaultCircular,
                    approved: shouldPreApprove
                ))
            }
            await MainActor.run {
                results = collected
                isRunning = false
            }
        }
    }

    private func applyApprovedResults() {
        var saved = 0
        for item in results where item.approved {
            guard let pair = item.renderedImageAndPNG else { continue }
            if BrandLogoCache.shared.setCustomLogoData(pair.1, for: item.brand) {
                saved += 1
            }
        }
        store.showToast(
            L10n.t("已保存 \(saved) 个品牌永久图标至 CustomLogos/", "Saved \(saved) permanent brand logos to CustomLogos/"),
            isLoading: false
        )
        dismiss()
    }
}

private struct PreviewInvertModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.colorInvert()
        } else {
            content
        }
    }
}
