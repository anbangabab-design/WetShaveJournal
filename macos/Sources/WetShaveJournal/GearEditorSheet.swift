import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 器材编辑、自定义品牌图标、详细参数、合并、拆分与 AI 识别弹窗
struct GearEditorSheet: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let item: GearItem?
    var defaultCategory: GearCategory = .razor

    @State private var category: GearCategory = .razor
    @State private var brand: String = ""
    @State private var model: String = ""
    @State private var fullName: String = ""
    @State private var status: GearStatus = .active
    @State private var isPending: Bool = false
    @State private var isSample: Bool = false

    // 剃须刀字段
    @State private var razorType: RazorType = .de
    @State private var isAdjustable: Bool = false
    @State private var isSlant: Bool = false
    @State private var material: String = ""
    @State private var plateType: PlateType? = nil
    @State private var gapOrSpec: String = ""

    // 刀片字段
    @State private var bladeType: BladeType? = nil

    // 剃须刷字段
    @State private var handleBrand: String = ""
    @State private var brushMaterial: BrushMaterial? = nil
    @State private var badgerTreatment: BadgerTreatment? = nil
    @State private var badgerBand: BadgerBand? = nil
    @State private var knotSize: String = ""
    @State private var knotShape: BrushKnotShape? = nil

    @State private var notes: String = ""
    @State private var isRecognizing: Bool = false
    @State private var recognitionFeedback: WebRecognitionResult? = nil

    // 合并、拆分与删除状态
    @State private var mergeTargetID: String = ""
    @State private var showMergeConfirm: Bool = false
    @State private var rawKeyToSplit: String? = nil
    @State private var itemToDelete: GearItem? = nil
    @State private var saveErrorMessage: String? = nil
    @State private var showAILogoFinder: Bool = false

    private var mergeCandidates: [GearItem] {
        guard let current = item else { return [] }
        return store.gearItems(for: current.category).filter { $0.id != current.id }
    }

    private var headerBrandName: String {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "品牌未注明" : trimmed
    }

    private var headerTitle: String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        let f = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { return f }
        return item == nil ? L10n.t("新增器材", "New Gear") : L10n.t("编辑器材", "Edit Gear")
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            // 弹窗头部：52×52 醒目品牌 Logo + 品牌名与型号层级 + AI 自动识别按钮
            HStack(alignment: .center, spacing: 15) {
                Button {
                    pickCustomBrandIcon()
                } label: {
                    BrandAvatarView(brand: headerBrandName, size: 52, maxWidth: 86, category: category)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .disabled(brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(L10n.t("点击更换该品牌的自定义图标", "Click to set a custom logo for this brand"))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(L10n.brandDisplay(headerBrandName))
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if category == .brush {
                            let hb = handleBrand.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !hb.isEmpty && hb.lowercased() != headerBrandName.lowercased() {
                                Text("×")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                Text(L10n.handleTag(hb))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if !status.isDefaultNormal {
                            TagPill(text: status.displayName, color: ShaveTheme.statusColor(for: status))
                        }
                        if isPending {
                            TagPill(text: L10n.t("待确认", "Pending"), color: ShaveTheme.amber, filled: true)
                        }
                    }

                    Text(headerTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                Button {
                    Task { await runWebRecognition() }
                } label: {
                    Label(
                        isRecognizing
                            ? L10n.t("识别中...", "Recognizing...")
                            : (store.aiConfig.isReady ? L10n.t("AI 自动识别", "AI Identify") : L10n.t("联网自动识别", "Auto Identify")),
                        systemImage: store.aiConfig.isReady ? "sparkles" : "globe"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isRecognizing || (fullName.isEmpty && model.isEmpty))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let fb = recognitionFeedback {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(
                                    fb.confidence >= 0.72
                                        ? L10n.t("识别完成（置信度 \(Int(fb.confidence * 100))%）", "Identified (\(Int(fb.confidence * 100))% confidence)")
                                        : L10n.t("置信度偏低（\(Int(fb.confidence * 100))%），建议人工核对", "Low confidence (\(Int(fb.confidence * 100))%) — please verify"),
                                    systemImage: fb.confidence >= 0.72 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                                )
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(fb.confidence >= 0.72 ? ShaveTheme.forest : ShaveTheme.amber)
                                Spacer()
                                if let urlStr = fb.sourceURL, let url = URL(string: urlStr) {
                                    Button(L10n.t("查看来源", "Open Link")) {
                                        NSWorkspace.shared.open(url)
                                    }
                                    .font(.system(size: 12.5))
                                    .buttonStyle(.link)
                                }
                            }
                            Text(fb.sourceSummary + (fb.isCorrection ? L10n.t(" · 已纠正拼写", " · Spelling fixed") : ""))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 11).fill(ShaveTheme.accentSoft))
                    }

                    SectionCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.t("基础信息", "Basic Info"))
                                .font(.system(size: 16, weight: .semibold))

                            if item == nil {
                                Picker(L10n.t("分类", "Category"), selection: $category) {
                                    ForEach(GearCategory.allCases) { c in
                                        Text(c.displayName).tag(c)
                                    }
                                }
                                .onChange(of: category) { _, newCat in
                                    status = GearStatus.normalized(status, for: newCat)
                                }
                            }

                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(category == .brush ? L10n.t("刷节品牌（主品牌）", "Knot Brand (Primary)") : L10n.t("品牌", "Brand"))
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        if category == .razor {
                                            Button(L10n.t("设为仿刀", "Clone")) {
                                                brand = "仿刀"
                                            }
                                            .font(.system(size: 12))
                                            .buttonStyle(.link)
                                        }
                                        Button {
                                            showAILogoFinder = true
                                        } label: {
                                            Label(L10n.t("AI 找图", "AI Find Logo"), systemImage: "sparkles")
                                                .font(.system(size: 12))
                                        }
                                        .buttonStyle(.link)
                                        .disabled(brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || BrandLogoCache.shouldSkipBrand(brand))

                                        Button(L10n.t("更换图标", "Custom Icon")) {
                                            pickCustomBrandIcon()
                                        }
                                        .font(.system(size: 12))
                                        .buttonStyle(.link)
                                        .disabled(brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                    TextField(category == .brush ? "Shavemac / Frank Shaving / Wald..." : "Blutt / Wolfman...", text: $brand)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.t("型号（保留版本代号）", "Model (Keep Sub-Model Code)"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    TextField("Next Level 112+ / WR1 0.74 / BR-1...", text: $model)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.t("完整名称（用于日记记录与单品区分）", "Canonical Name (Unique Identifier)"))
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                TextField("Blutt BR-1 0.99", text: $fullName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack(spacing: 20) {
                                Picker(L10n.t("状态", "Status"), selection: $status) {
                                    ForEach(GearStatus.options(for: category)) { s in
                                        Text(s.displayName).tag(s)
                                    }
                                }
                                .frame(width: 210)

                                Toggle(L10n.t("待确认", "Pending"), isOn: $isPending)
                                    .tint(ShaveTheme.amber)

                                if category.supportsSample {
                                    Toggle(L10n.t("小样", "Sample"), isOn: $isSample)
                                        .tint(ShaveTheme.slate)
                                }
                            }
                        }
                    }

                    if category == .razor {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("剃须刀参数", "Razor Specs"))
                                    .font(.system(size: 16, weight: .semibold))

                                Picker(L10n.t("刀型", "Type"), selection: $razorType) {
                                    ForEach(RazorType.allCases) { rt in
                                        Text(rt.displayName).tag(rt)
                                    }
                                }

                                HStack(spacing: 24) {
                                    Toggle(L10n.t("可调刀", "Adjustable"), isOn: $isAdjustable)
                                        .tint(ShaveTheme.accent)
                                    Toggle(L10n.t("Slant 斜头", "Slant"), isOn: $isSlant)
                                        .tint(ShaveTheme.accent)
                                }

                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(L10n.t("材质", "Material"))
                                                .font(.system(size: 12.5))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Menu(L10n.t("快选", "Presets")) {
                                                ForEach(GearKnowledgeBase.standardRazorMaterials, id: \.self) { mat in
                                                    Button(L10n.materialDisplay(mat)) { material = mat }
                                                }
                                                Divider()
                                                Button(L10n.t("清空", "Clear")) { material = "" }
                                            }
                                            .font(.system(size: 12))
                                            .menuStyle(.borderlessButton)
                                        }
                                        TextField(L10n.t("不锈钢 / 钛合金 / 黄铜...", "Stainless Steel / Titanium..."), text: $material)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(L10n.t("底板", "Baseplate"))
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(.secondary)
                                        Picker("Baseplate", selection: $plateType) {
                                            Text(L10n.t("未标注", "None")).tag(PlateType?.none)
                                            ForEach(PlateType.allCases) { pt in
                                                Text(pt.displayName).tag(PlateType?.some(pt))
                                            }
                                        }
                                        .labelsHidden()
                                    }
                                }

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.t("卡片短规格（最多 10 字符，如 0.99 / 1.12+ / Standard / Lite）", "Short Card Spec (max 10 chars, e.g. 0.99 / 1.12+ / Standard)"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    TextField("0.99 / 1.12+ / Standard / Lite...", text: $gapOrSpec)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    } else if category == .blade {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(L10n.t("刀片参数", "Blade Specs"))
                                    .font(.system(size: 16, weight: .semibold))

                                Picker(L10n.t("刀片类型", "Blade Type"), selection: $bladeType) {
                                    Text(L10n.t("未标注", "None")).tag(BladeType?.none)
                                    ForEach(BladeType.allCases) { bt in
                                        Text(bt.displayName).tag(BladeType?.some(bt))
                                    }
                                }
                                .frame(maxWidth: 280)
                            }
                        }
                    } else if category == .brush {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("剃须刷参数", "Brush Specs"))
                                    .font(.system(size: 16, weight: .semibold))

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(L10n.t("手柄品牌（混搭刷选填，原厂同品牌留空）", "Handle Brand (Optional — leave blank for factory handle)"))
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                    TextField("RV / Chisel & Hound / AKA / S.ghost...", text: $handleBrand)
                                        .textFieldStyle(.roundedBorder)
                                }

                                HStack(spacing: 14) {
                                    Picker(L10n.t("刷毛", "Hair"), selection: $brushMaterial) {
                                        Text(L10n.t("未标注", "None")).tag(BrushMaterial?.none)
                                        ForEach(BrushMaterial.allCases) { bm in
                                            Text(bm.displayName).tag(BrushMaterial?.some(bm))
                                        }
                                    }

                                    Picker(L10n.t("毛型", "Shape"), selection: $knotShape) {
                                        Text(L10n.t("未标注", "None")).tag(BrushKnotShape?.none)
                                        ForEach(BrushKnotShape.allCases) { sh in
                                            Text(sh.displayName).tag(BrushKnotShape?.some(sh))
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(L10n.t("结径", "Knot Size"))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                        TextField("26mm", text: $knotSize)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(width: 92)
                                    }
                                }

                                if brushMaterial == .badger {
                                    HStack(spacing: 16) {
                                        Picker(L10n.t("处理", "Tips"), selection: $badgerTreatment) {
                                            Text(L10n.t("未标注", "None")).tag(BadgerTreatment?.none)
                                            ForEach(BadgerTreatment.allCases) { bt in
                                                Text(bt.displayName).tag(BadgerTreatment?.some(bt))
                                            }
                                        }

                                        Picker(L10n.t("段数", "Band"), selection: $badgerBand) {
                                            Text(L10n.t("未标注", "None")).tag(BadgerBand?.none)
                                            ForEach(BadgerBand.allCases) { bb in
                                                Text(bb.displayName).tag(BadgerBand?.some(bb))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.t("详细参数 / 备注", "Detailed Specs & Notes"))
                                .font(.system(size: 16, weight: .semibold))
                            TextField(
                                L10n.t("露刃量、刀隙详述、克重、入手来源或个人使用备注...", "Blade exposure, weight, provenance, or personal notes..."),
                                text: $notes,
                                axis: .vertical
                            )
                            .lineLimit(2...5)
                            .textFieldStyle(.roundedBorder)
                        }
                    }

                    if let currentItem = item {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("合并与拆分", "Merge & Split"))
                                    .font(.system(size: 16, weight: .semibold))

                                HStack(spacing: 10) {
                                    Picker("Target", selection: $mergeTargetID) {
                                        Text(L10n.t("选择要并入的目标器材...", "Merge into another item...")).tag("")
                                        ForEach(mergeCandidates) { cand in
                                            Text("[\(L10n.brandDisplay(cand.brand))] \(cand.name) (\(cand.count))").tag(cand.id)
                                        }
                                    }
                                    .labelsHidden()

                                    Button(L10n.t("合并", "Merge")) {
                                        showMergeConfirm = true
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(mergeTargetID.isEmpty || store.isReadOnlyProtected)
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text(L10n.t("关联原始写法（\(currentItem.rawKeys.count)）", "Linked Raw Entries (\(currentItem.rawKeys.count))"))
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(.secondary)

                                    VStack(spacing: 6) {
                                        ForEach(currentItem.rawKeys, id: \.self) { rk in
                                            let sample = store.rawEntrySamples(forRawKey: rk, category: currentItem.category)
                                            HStack(spacing: 8) {
                                                Text(sample.display)
                                                    .font(.system(size: 13, weight: .medium))
                                                if sample.count > 0 {
                                                    TagPill(text: L10n.t("\(sample.count) 次", "\(sample.count)"), neutral: true)
                                                }
                                                Spacer()
                                                if currentItem.rawKeys.count > 1 {
                                                    Button(L10n.t("拆分", "Split")) {
                                                        rawKeyToSplit = rk
                                                    }
                                                    .font(.system(size: 12))
                                                    .buttonStyle(.bordered)
                                                    .controlSize(.small)
                                                    .disabled(store.isReadOnlyProtected)
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6.5)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(ShaveTheme.subtleSurface(scheme)))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }

            Divider()

            if let errMsg = saveErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ShaveTheme.crimson)
                    Text(errMsg)
                        .font(.system(size: 12.5))
                        .foregroundStyle(ShaveTheme.crimson)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
            }

            HStack {
                if let currentItem = item {
                    Button(role: .destructive) {
                        saveErrorMessage = nil
                        itemToDelete = currentItem
                    } label: {
                        Label(L10n.t("删除器材", "Delete Gear"), systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(store.isReadOnlyProtected)
                }
                Spacer()
                Button(L10n.t("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("保存", "Save")) {
                    saveGear()
                }
                .buttonStyle(.borderedProminent)
                .tint(ShaveTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled((fullName.trimmingCharacters(in: .whitespaces).isEmpty && model.trimmingCharacters(in: .whitespaces).isEmpty) || store.isReadOnlyProtected)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(width: 680, height: 760)
        .onAppear(perform: populate)
        .sheet(isPresented: $showAILogoFinder) {
            AILogoFinderSheet(
                initialBrand: brand.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category
            )
            .environmentObject(store)
        }
        .gearDeleteConfirmation(
            targetItem: $itemToDelete,
            onDeleted: { dismiss() },
            onError: { saveErrorMessage = $0.localizedDescription }
        )
        .alert(L10n.t("确认合并器材？", "Merge Gear?"), isPresented: $showMergeConfirm) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) {}
            Button(L10n.t("合并", "Merge"), role: .destructive) {
                saveErrorMessage = nil
                if let src = item, let target = mergeCandidates.first(where: { $0.id == mergeTargetID }) {
                    switch store.mergeGearItem(source: src, into: target) {
                    case .success:
                        dismiss()
                    case .failure(let error):
                        saveErrorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            if let src = item, let target = mergeCandidates.first(where: { $0.id == mergeTargetID }) {
                Text(L10n.t("将「\(src.name)」合并至「\(target.name)」。", "Merge \"\(src.name)\" into \"\(target.name)\"."))
            }
        }
        .alert(L10n.t("拆分为独立器材？", "Split Into Separate Item?"), isPresented: Binding(
            get: { rawKeyToSplit != nil },
            set: { if !$0 { rawKeyToSplit = nil } }
        )) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) { rawKeyToSplit = nil }
            Button(L10n.t("拆分", "Split")) {
                saveErrorMessage = nil
                if let rk = rawKeyToSplit, let src = item {
                    let result = store.splitRawKey(rk, from: src)
                    rawKeyToSplit = nil
                    switch result {
                    case .success:
                        dismiss()
                    case .failure(let error):
                        saveErrorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(L10n.t("该条原始写法将被拆出为独立新器材并标为待确认。", "This raw entry will become a separate pending item."))
        }
    }

    private func pickCustomBrandIcon() {
        let targetBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetBrand.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .icns, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L10n.t("选择「\(targetBrand)」品牌图标", "Choose Icon for \(targetBrand)")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if BrandLogoCache.shared.setCustomLogo(from: url, for: targetBrand) {
            store.showToast(L10n.t("已更新「\(targetBrand)」品牌图标", "Updated custom icon for \(targetBrand)"), isLoading: false)
        } else {
            store.showToast(L10n.t("无法读取所选图片文件", "Could not load selected image"), isLoading: false)
        }
    }

    private func populate() {
        guard let item = item else {
            category = defaultCategory
            status = GearStatus.normalized(nil, for: defaultCategory)
            return
        }
        category = item.category
        brand = item.brand
        model = item.model
        fullName = item.name
        status = GearStatus.normalized(item.status, for: item.category)
        isPending = item.isPending
        isSample = item.isSample
        razorType = item.razorType ?? .de
        isAdjustable = item.isAdjustable
        isSlant = item.isSlant
        material = item.material ?? ""
        plateType = item.plateType
        gapOrSpec = item.gapOrSpec ?? ""
        bladeType = item.bladeType
        handleBrand = item.handleBrand ?? ""
        brushMaterial = item.brushMaterial
        badgerTreatment = item.badgerTreatment
        badgerBand = item.badgerBand
        knotSize = item.knotSize ?? ""
        knotShape = item.knotShape
        notes = item.notes ?? ""
    }

    private func runWebRecognition() async {
        isRecognizing = true
        defer { isRecognizing = false }
        let query = fullName.trimmingCharacters(in: .whitespaces).isEmpty ? "\(brand) \(model)" : fullName
        let res = await WebGearRecognizer.shared.recognize(name: query, category: category, aiConfig: store.aiConfig)
        recognitionFeedback = res

        // 若该器材已经人工确认或本次 AI 置信度偏低，则仅补全空白字段，不覆盖已有人工值
        let protectExistingValues = (item?.isManuallyConfirmed == true) || (res.confidence < 0.72)

        func applyString(_ suggested: String?, to current: inout String, treatUnknownAsEmpty: Bool = false) {
            guard let s = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            let trimmedCurrent = current.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectivelyEmpty = trimmedCurrent.isEmpty || (treatUnknownAsEmpty && (trimmedCurrent == "品牌未注明" || trimmedCurrent == "无品牌"))
            if !protectExistingValues || effectivelyEmpty {
                current = s
            }
        }

        applyString(res.suggestedBrand, to: &brand, treatUnknownAsEmpty: true)
        applyString(res.suggestedHandleBrand, to: &handleBrand)
        applyString(res.suggestedName, to: &fullName)
        applyString(res.suggestedModel, to: &model)
        if let rt = res.razorType, (!protectExistingValues || item?.razorType == nil) { razorType = rt }
        if let adj = res.isAdjustable, !protectExistingValues { isAdjustable = adj }
        if let sl = res.isSlant, !protectExistingValues { isSlant = sl }
        applyString(res.material, to: &material)
        if let pt = res.plateType, (!protectExistingValues || plateType == nil) { plateType = pt }
        applyString(res.gapOrSpec, to: &gapOrSpec)
        if let extraNotes = res.notes, !extraNotes.isEmpty {
            let cur = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if cur.isEmpty {
                notes = extraNotes
            } else if !cur.localizedCaseInsensitiveContains(extraNotes) {
                notes = "\(cur)；\(extraNotes)"
            }
        }
        if let bt = res.bladeType, (!protectExistingValues || bladeType == nil) { bladeType = bt }
        if let bm = res.brushMaterial, (!protectExistingValues || brushMaterial == nil) { brushMaterial = bm }
        if let tr = res.badgerTreatment, (!protectExistingValues || badgerTreatment == nil) { badgerTreatment = tr }
        if let bb = res.badgerBand, (!protectExistingValues || badgerBand == nil) { badgerBand = bb }
        applyString(res.knotSize, to: &knotSize)
        if let sh = res.knotShape, (!protectExistingValues || knotShape == nil) { knotShape = sh }
        if res.confidence < 0.72 {
            isPending = true
        } else if item?.isManuallyConfirmed != true {
            isPending = false
        }
    }

    private func saveGear() {
        let rawBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBrand = rawBrand.isEmpty ? "品牌未注明" : (GearSanitizer.sanitizeBrand(rawBrand) ?? rawBrand)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFull: String = {
            let f = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !f.isEmpty { return f }
            return cleanBrand == "仿刀" || cleanBrand == "品牌未注明" ? cleanModel : "\(cleanBrand) \(cleanModel)"
        }()
        let rawHandle = handleBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHandle: String? = (!rawHandle.isEmpty && rawHandle.lowercased() != cleanBrand.lowercased()) ? rawHandle : nil

        let rawOverride = GearOverride(
            brand: cleanBrand,
            name: cleanFull,
            model: cleanModel.isEmpty ? nil : cleanModel,
            razorType: category == .razor ? razorType : nil,
            isAdjustable: category == .razor ? isAdjustable : nil,
            isSlant: category == .razor ? isSlant : nil,
            material: category == .razor ? GearSanitizer.sanitizeMaterialStrict(material) : nil,
            plateType: category == .razor ? plateType : nil,
            gapOrSpec: category == .razor && !gapOrSpec.trimmingCharacters(in: .whitespaces).isEmpty ? gapOrSpec.trimmingCharacters(in: .whitespaces) : nil,
            bladeType: category == .blade ? bladeType : nil,
            handleBrand: category == .brush ? cleanHandle : nil,
            brushMaterial: category == .brush ? brushMaterial : nil,
            badgerTreatment: category == .brush && brushMaterial == .badger ? badgerTreatment : nil,
            badgerBand: category == .brush && brushMaterial == .badger ? badgerBand : nil,
            knotSize: category == .brush && !knotSize.trimmingCharacters(in: .whitespaces).isEmpty ? knotSize.trimmingCharacters(in: .whitespaces) : nil,
            knotShape: category == .brush ? knotShape : nil,
            isSample: (category.supportsSample && isSample) ? true : nil,
            status: GearStatus.normalized(status, for: category),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines),
            recognizedSource: recognitionFeedback?.sourceSummary ?? item?.recognizedSource,
            isManuallyConfirmed: true
        )
        let sanitized = GearSanitizer.sanitizeOverride(rawOverride, category: category)
        saveErrorMessage = nil

        switch store.updateGearItem(
            rawKeys: item?.rawKeys ?? [],
            category: category,
            newOverride: sanitized,
            clearPending: !isPending
        ) {
        case .success:
            dismiss()
        case .failure(let error):
            saveErrorMessage = error.localizedDescription
        }
    }
}

struct GearDeleteAlertModifier: ViewModifier {
    @EnvironmentObject var store: JournalStore
    @Binding var targetItem: GearItem?
    var onDeleted: (() -> Void)? = nil
    var onError: ((Error) -> Void)? = nil

    func body(content: Content) -> some View {
        content.alert(
            L10n.t("确认删除器材？", "Delete Gear?"),
            isPresented: Binding(
                get: { targetItem != nil },
                set: { if !$0 { targetItem = nil } }
            ),
            presenting: targetItem
        ) { target in
            let refCount = store.referencedEntryCount(for: target)
            if refCount == 0 {
                Button(L10n.t("删除器材", "Delete Gear"), role: .destructive) {
                    let result = store.deleteGearItem(target, removeFromEntries: false)
                    targetItem = nil
                    switch result {
                    case .success:
                        onDeleted?()
                    case .failure(let error):
                        onError?(error)
                    }
                }
                Button(L10n.t("取消", "Cancel"), role: .cancel) {
                    targetItem = nil
                }
            } else {
                Button(L10n.t("仅移除档案规则", "Remove Profile Rules Only")) {
                    let result = store.deleteGearItem(target, removeFromEntries: false)
                    targetItem = nil
                    switch result {
                    case .success:
                        onDeleted?()
                    case .failure(let error):
                        onError?(error)
                    }
                }
                Button(L10n.t("彻底删除（含日记中的该项）", "Delete Completely (Include Entries)"), role: .destructive) {
                    let result = store.deleteGearItem(target, removeFromEntries: true)
                    targetItem = nil
                    switch result {
                    case .success:
                        onDeleted?()
                    case .failure(let error):
                        onError?(error)
                    }
                }
                Button(L10n.t("取消", "Cancel"), role: .cancel) {
                    targetItem = nil
                }
            }
        } message: { target in
            let refCount = store.referencedEntryCount(for: target)
            if refCount == 0 {
                Text(L10n.t(
                    "「\(target.name)」当前关联了 0 篇日记，确认后将从器材库彻底移除。",
                    "\"\(target.name)\" is linked to 0 journal entries and will be permanently removed from your gear library."
                ))
            } else {
                Text(L10n.t(
                    "「\(target.name)」当前关联了 \(refCount) 篇日记。\n• 仅移除档案规则：清除自定义分类/参数与合并规则，保留日记原文。\n• 彻底删除：同步从这 \(refCount) 篇日记中移除该器材字段（保留其余字段，并先自动备份 journal.json）。",
                    "\"\(target.name)\" is linked to \(refCount) journal entries.\n• Remove Profile Rules Only: clears custom specs & merge rules while keeping journal entries intact.\n• Delete Completely: also removes this gear field from those \(refCount) entries (other fields stay intact; journal.json is backed up first)."
                ))
            }
        }
    }
}

extension View {
    func gearDeleteConfirmation(
        targetItem: Binding<GearItem?>,
        onDeleted: (() -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> some View {
        modifier(GearDeleteAlertModifier(targetItem: targetItem, onDeleted: onDeleted, onError: onError))
    }
}
