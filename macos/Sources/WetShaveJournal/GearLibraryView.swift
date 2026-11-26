import SwiftUI

enum GearViewMode: String, CaseIterable, Identifiable {
    case single = "按单品"
    case byBrand = "按品牌"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .single: return L10n.t("按单品", "Items")
        case .byBrand: return L10n.t("按品牌", "Brands")
        }
    }
}

struct GearLibraryView: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    @State private var selectedCategory: GearCategory = .razor
    @State private var viewMode: GearViewMode = .single
    @State private var searchText: String = ""
    @State private var onlyPending: Bool = false

    // 剃须刀多级筛选（filterMaterial 始终保存底层中文材质键，界面展示统一经 L10n 翻译）
    @State private var filterRazorType: RazorType? = nil
    @State private var filterAdjustableOnly: Bool = false
    @State private var filterSlantOnly: Bool = false
    @State private var filterPlateType: PlateType? = nil
    @State private var filterMaterial: String = ""

    // 刀片筛选
    @State private var filterBladeType: BladeType? = nil

    // 剃须刷多级筛选
    @State private var filterBrushMaterial: BrushMaterial? = nil
    @State private var filterBadgerTreatment: BadgerTreatment? = nil
    @State private var filterBadgerBand: BadgerBand? = nil
    @State private var filterKnotShape: BrushKnotShape? = nil

    // 剃须皂 / 须后小样筛选
    @State private var filterSampleOnly: Bool = false

    // 通用状态筛选
    @State private var filterStatus: GearStatus? = nil

    @State private var editingItem: GearItem? = nil
    @State private var itemToDelete: GearItem? = nil
    @State private var showNewGearSheet: Bool = false
    @State private var showAIAuditSheet: Bool = false

    private var rawItems: [GearItem] {
        store.gearItems(for: selectedCategory)
    }

    private var availableMaterials: [String] {
        Array(Set(rawItems.compactMap { $0.material?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }

    private var pendingCountInCategory: Int {
        rawItems.filter(\.isPending).count
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || onlyPending
            || filterStatus != nil
            || filterRazorType != nil
            || filterAdjustableOnly
            || filterSlantOnly
            || filterPlateType != nil
            || !filterMaterial.isEmpty
            || filterBladeType != nil
            || filterBrushMaterial != nil
            || filterBadgerTreatment != nil
            || filterBadgerBand != nil
            || filterKnotShape != nil
            || filterSampleOnly
    }

    private var filteredItems: [GearItem] {
        rawItems.filter { item in
            if onlyPending && !item.isPending { return false }
            if let st = filterStatus, item.status != st { return false }

            if selectedCategory == .razor {
                if let rt = filterRazorType, item.razorType != rt { return false }
                if filterAdjustableOnly && !item.isAdjustable { return false }
                if filterSlantOnly && !item.isSlant { return false }
                if let pt = filterPlateType, item.plateType != pt { return false }
                if !filterMaterial.isEmpty, item.material != filterMaterial { return false }
            } else if selectedCategory == .blade {
                if let bt = filterBladeType, item.bladeType != bt { return false }
            } else if selectedCategory == .brush {
                if let bm = filterBrushMaterial, item.brushMaterial != bm { return false }
                if filterBrushMaterial == .badger || filterBrushMaterial == nil {
                    if let bt = filterBadgerTreatment, item.badgerTreatment != bt { return false }
                    if let bb = filterBadgerBand, item.badgerBand != bb { return false }
                }
                if let sh = filterKnotShape, item.knotShape != sh { return false }
            } else if selectedCategory.supportsSample {
                if filterSampleOnly && !item.isSample { return false }
            }

            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if q.isEmpty { return true }
            let matMatch: Bool = {
                guard let m = item.material else { return false }
                return m.lowercased().contains(q) || L10n.materialDisplay(m).lowercased().contains(q)
            }()
            return item.name.lowercased().contains(q)
                || item.brand.lowercased().contains(q)
                || L10n.brandDisplay(item.brand).lowercased().contains(q)
                || item.model.lowercased().contains(q)
                || (item.handleBrand?.lowercased().contains(q) ?? false)
                || matMatch
                || (item.gapOrSpec?.lowercased().contains(q) ?? false)
                || (item.notes?.lowercased().contains(q) ?? false)
        }
    }

    private var groupedByBrand: [BrandGroup] {
        store.brandGroups(for: filteredItems)
    }

    var body: some View {
        let _ = store.language
        VStack(spacing: 0) {
            // 顶部：分类切换 + 视图模式 + AI 体检 + 新增
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(GearCategory.allCases) { cat in
                                let active = selectedCategory == cat
                                Button {
                                    selectedCategory = cat
                                    resetCategoryFilters()
                                } label: {
                                    Text(cat.displayName)
                                        .font(.system(size: 13.5, weight: active ? .semibold : .medium))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7.5)
                                        .background(
                                            Capsule().fill(active ? ShaveTheme.accent : ShaveTheme.cardBackground(scheme))
                                        )
                                        .overlay(
                                            Capsule().stroke(active ? Color.clear : ShaveTheme.cardBorder(scheme), lineWidth: 1)
                                        )
                                        .foregroundStyle(active ? Color.white : .primary)
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Picker("View Mode", selection: $viewMode) {
                        ForEach(GearViewMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 152)

                    Button {
                        showAIAuditSheet = true
                    } label: {
                        Label(L10n.t("AI 体检", "AI Audit"), systemImage: "sparkles")
                            .font(.system(size: 13.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isReadOnlyProtected)

                    Button {
                        showNewGearSheet = true
                    } label: {
                        Label(L10n.t("新增", "Add"), systemImage: "plus")
                            .font(.system(size: 13.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isReadOnlyProtected)
                }

                // 搜索栏 + 筛选条 + 清除筛选
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        TextField(L10n.t("搜索品牌、型号、材质、手柄...", "Search brand, model, spec..."), text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: 245)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ShaveTheme.cardBackground(scheme)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if pendingCountInCategory > 0 || onlyPending {
                                ToggleChipButton(
                                    title: L10n.t("待确认 (\(pendingCountInCategory))", "Pending (\(pendingCountInCategory))"),
                                    isOn: $onlyPending,
                                    activeColor: ShaveTheme.amber
                                )
                            }

                            Menu {
                                Button(L10n.t("全部状态", "All Statuses")) { filterStatus = nil }
                                Divider()
                                ForEach(GearStatus.options(for: selectedCategory)) { st in
                                    Button(st.displayName) { filterStatus = st }
                                }
                            } label: {
                                FilterChipLabel(title: filterStatus?.displayName ?? L10n.t("状态", "Status"), active: filterStatus != nil)
                            }
                            .menuStyle(.borderlessButton)

                            if selectedCategory.supportsSample {
                                ToggleChipButton(
                                    title: L10n.t("小样", "Sample"),
                                    isOn: $filterSampleOnly,
                                    activeColor: ShaveTheme.slate
                                )
                            }

                            if selectedCategory == .razor {
                                Menu {
                                    Button(L10n.t("全部刀型", "All Types")) { filterRazorType = nil }
                                    Divider()
                                    ForEach(RazorType.allCases) { rt in
                                        Button(rt.displayName) { filterRazorType = rt }
                                    }
                                } label: {
                                    FilterChipLabel(title: filterRazorType?.shortLabel ?? L10n.t("刀型", "Type"), active: filterRazorType != nil)
                                }
                                .menuStyle(.borderlessButton)

                                ToggleChipButton(title: L10n.t("可调", "Adjustable"), isOn: $filterAdjustableOnly, activeColor: ShaveTheme.accent)
                                ToggleChipButton(title: "Slant", isOn: $filterSlantOnly, activeColor: ShaveTheme.accent)

                                Menu {
                                    Button(L10n.t("全部底板", "All Plates")) { filterPlateType = nil }
                                    Divider()
                                    ForEach(PlateType.allCases) { pt in
                                        Button(pt.displayName) { filterPlateType = pt }
                                    }
                                } label: {
                                    FilterChipLabel(title: filterPlateType?.rawValue ?? L10n.t("底板", "Plate"), active: filterPlateType != nil)
                                }
                                .menuStyle(.borderlessButton)

                                if !availableMaterials.isEmpty {
                                    Menu {
                                        Button(L10n.t("全部材质", "All Materials")) { filterMaterial = "" }
                                        Divider()
                                        ForEach(availableMaterials, id: \.self) { m in
                                            Button(L10n.materialDisplay(m)) { filterMaterial = m }
                                        }
                                    } label: {
                                        FilterChipLabel(
                                            title: filterMaterial.isEmpty ? L10n.t("材质", "Material") : L10n.materialDisplay(filterMaterial),
                                            active: !filterMaterial.isEmpty
                                        )
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            } else if selectedCategory == .blade {
                                Menu {
                                    Button(L10n.t("全部刀片类型", "All Blade Types")) { filterBladeType = nil }
                                    Divider()
                                    ForEach(BladeType.allCases) { bt in
                                        Button(bt.displayName) { filterBladeType = bt }
                                    }
                                } label: {
                                    FilterChipLabel(title: filterBladeType?.displayName ?? L10n.t("刀片类型", "Type"), active: filterBladeType != nil)
                                }
                                .menuStyle(.borderlessButton)
                            } else if selectedCategory == .brush {
                                Menu {
                                    Button(L10n.t("全部刷毛", "All Hair")) {
                                        filterBrushMaterial = nil
                                        filterBadgerTreatment = nil
                                        filterBadgerBand = nil
                                    }
                                    Divider()
                                    ForEach(BrushMaterial.allCases) { bm in
                                        Button(bm.displayName) { filterBrushMaterial = bm }
                                    }
                                } label: {
                                    FilterChipLabel(title: filterBrushMaterial?.displayName ?? L10n.t("刷毛", "Hair"), active: filterBrushMaterial != nil)
                                }
                                .menuStyle(.borderlessButton)

                                if filterBrushMaterial == nil || filterBrushMaterial == .badger {
                                    Menu {
                                        Button(L10n.t("全部处理", "All Tips")) { filterBadgerTreatment = nil }
                                        Divider()
                                        ForEach(BadgerTreatment.allCases) { bt in
                                            Button(bt.displayName) { filterBadgerTreatment = bt }
                                        }
                                    } label: {
                                        FilterChipLabel(title: filterBadgerTreatment?.displayName ?? L10n.t("处理", "Tips"), active: filterBadgerTreatment != nil)
                                    }
                                    .menuStyle(.borderlessButton)

                                    Menu {
                                        Button(L10n.t("全部段数", "All Bands")) { filterBadgerBand = nil }
                                        Divider()
                                        ForEach(BadgerBand.allCases) { bb in
                                            Button(bb.displayName) { filterBadgerBand = bb }
                                        }
                                    } label: {
                                        FilterChipLabel(title: filterBadgerBand?.displayName ?? L10n.t("段数", "Band"), active: filterBadgerBand != nil)
                                    }
                                    .menuStyle(.borderlessButton)
                                }

                                Menu {
                                    Button(L10n.t("全部毛型", "All Shapes")) { filterKnotShape = nil }
                                    Divider()
                                    ForEach(BrushKnotShape.allCases) { sh in
                                        Button(sh.displayName) { filterKnotShape = sh }
                                    }
                                } label: {
                                    FilterChipLabel(title: filterKnotShape?.displayName ?? L10n.t("毛型", "Shape"), active: filterKnotShape != nil)
                                }
                                .menuStyle(.borderlessButton)
                            }

                            if hasActiveFilters {
                                Button {
                                    resetAllFilters()
                                } label: {
                                    Text(L10n.t("清除筛选", "Clear"))
                                        .font(.system(size: 12.5, weight: .medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .foregroundStyle(ShaveTheme.accent)
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    if !store.database.pending.isEmpty {
                        Button {
                            Task { await store.recognizeAllPending() }
                        } label: {
                            Label(
                                store.isRecognizingBatch ? L10n.t("识别中...", "Working...") : L10n.t("识别待确认", "Identify Pending"),
                                systemImage: store.aiConfig.isReady ? "sparkles" : "globe"
                            )
                            .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isRecognizingBatch || store.isReadOnlyProtected)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // 主体内容区
            if filteredItems.isEmpty {
                VStack {
                    Spacer(minLength: 0)
                    ContentUnavailableView {
                        Label(L10n.t("无符合条件的\(selectedCategory.displayName)", "No Matching \(selectedCategory.displayName)"), systemImage: selectedCategory.icon)
                    } actions: {
                        if hasActiveFilters {
                            Button(L10n.t("清除筛选", "Clear Filters")) { resetAllFilters() }
                                .buttonStyle(.bordered)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .single {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 295, maximum: 390), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(filteredItems) { item in
                            GearCardView(item: item)
                                .onTapGesture { editingItem = item }
                                .contextMenu {
                                    Button {
                                        editingItem = item
                                    } label: {
                                        Label(L10n.t("编辑器材", "Edit Gear"), systemImage: "pencil")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        itemToDelete = item
                                    } label: {
                                        Label(L10n.t("删除器材", "Delete Gear"), systemImage: "trash")
                                    }
                                    .disabled(store.isReadOnlyProtected)
                                }
                        }
                    }
                    .padding(24)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(groupedByBrand) { group in
                            BrandSectionView(
                                group: group,
                                category: selectedCategory,
                                isReadOnlyProtected: store.isReadOnlyProtected,
                                onSelectItem: { editingItem = $0 },
                                onDeleteItem: { itemToDelete = $0 }
                            )
                        }
                    }
                    .padding(24)
                }
            }
        }
        .sheet(item: $editingItem) { item in
            GearEditorSheet(item: item)
                .environmentObject(store)
        }
        .sheet(isPresented: $showNewGearSheet) {
            GearEditorSheet(item: nil, defaultCategory: selectedCategory)
                .environmentObject(store)
        }
        .sheet(isPresented: $showAIAuditSheet) {
            AIHealthCheckSheet(initialCategory: selectedCategory)
                .environmentObject(store)
        }
        .gearDeleteConfirmation(targetItem: $itemToDelete)
    }

    private func resetCategoryFilters() {
        filterRazorType = nil
        filterAdjustableOnly = false
        filterSlantOnly = false
        filterPlateType = nil
        filterMaterial = ""
        filterBladeType = nil
        filterBrushMaterial = nil
        filterBadgerTreatment = nil
        filterBadgerBand = nil
        filterKnotShape = nil
        filterSampleOnly = false
        filterStatus = nil
        onlyPending = false
    }

    private func resetAllFilters() {
        searchText = ""
        resetCategoryFilters()
    }
}

private struct ToggleChipButton: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    @Binding var isOn: Bool
    var activeColor: Color = ShaveTheme.accent

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: isOn ? .semibold : .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isOn ? activeColor.opacity(0.14) : ShaveTheme.subtleSurface(scheme))
                )
                .overlay(
                    Capsule().stroke(isOn ? activeColor.opacity(0.42) : Color.clear, lineWidth: 1)
                )
                .foregroundStyle(isOn ? activeColor : .primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct FilterChipLabel: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let active: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(active ? ShaveTheme.accentSoft : ShaveTheme.subtleSurface(scheme)))
        .foregroundStyle(active ? ShaveTheme.accent : .primary)
        .contentShape(Capsule())
    }
}

private struct BrandSectionView: View {
    @Environment(\.colorScheme) private var scheme
    let group: BrandGroup
    let category: GearCategory
    let isReadOnlyProtected: Bool
    let onSelectItem: (GearItem) -> Void
    let onDeleteItem: (GearItem) -> Void
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 11) {
                    BrandAvatarView(brand: group.brand, size: 30, category: category)

                    Text(L10n.brandDisplay(group.brand))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)

                    TagPill(text: L10n.t("\(group.items.count) 款", "\(group.items.count)"), neutral: true)
                    TagPill(text: L10n.t("\(group.totalUses) 次", "\(group.totalUses) uses"), color: ShaveTheme.accent)

                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 285, maximum: 385), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(group.items) { item in
                        GearCardView(item: item)
                            .onTapGesture { onSelectItem(item) }
                            .contextMenu {
                                Button {
                                    onSelectItem(item)
                                } label: {
                                    Label(L10n.t("编辑器材", "Edit Gear"), systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    onDeleteItem(item)
                                } label: {
                                    Label(L10n.t("删除器材", "Delete Gear"), systemImage: "trash")
                                }
                                .disabled(isReadOnlyProtected)
                            }
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(ShaveTheme.cardBackground(scheme).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
        )
    }
}
