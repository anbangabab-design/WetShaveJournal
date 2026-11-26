import SwiftUI
import AppKit

struct JournalView: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let onCreateNew: () -> Void

    @State private var searchText: String = ""
    @State private var selectedEntryID: String?
    @State private var filterResult: ShaveResult? = nil
    @State private var filterIrritation: IrritationLevel? = nil
    @State private var editingEntry: JournalEntry? = nil
    @State private var entryToDelete: JournalEntry? = nil

    // 日历定位状态
    @State private var showCalendarPopover: Bool = false
    @State private var calendarDisplayedMonth: Date = Date()
    @State private var selectedEmptyDateISO: String? = nil
    @State private var backfillDateTarget: BackfillDateTarget? = nil
    @State private var scrollTargetID: String? = nil
    @State private var scrollRequestToken: UUID = UUID()

    private struct BackfillDateTarget: Identifiable {
        let id: String
        let date: Date
    }

    private var entriesByDate: [String: [JournalEntry]] {
        store.statisticsSnapshot.entriesByDate
    }

    private var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filterResult != nil
            || filterIrritation != nil
    }

    private var filteredEntries: [JournalEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parsedMap = store.statisticsSnapshot.parsedProcessByEntryID
        return store.database.entries.filter { entry in
            if filterResult != nil || filterIrritation != nil {
                let proc = parsedMap[entry.id] ?? ProcessParser.parse(entry.processText)
                if let res = filterResult, proc.result != res { return false }
                if let irr = filterIrritation, proc.irritation != irr { return false }
            }
            if q.isEmpty { return true }
            if entry.date.lowercased().contains(q) { return true }
            return entry.fields.contains { $0.value.lowercased().contains(q) }
        }
    }

    private var activeEntry: JournalEntry? {
        if let id = selectedEntryID, let match = filteredEntries.first(where: { $0.id == id }) {
            return match
        }
        return filteredEntries.first
    }

    var body: some View {
        let _ = store.language
        HSplitView {
            // 左侧：日记时间线列表
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                            TextField(L10n.t("搜索日期、器材或过程...", "Search date, gear, notes..."), text: $searchText)
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
                        .padding(.vertical, 8.5)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(ShaveTheme.cardBackground(scheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
                        )

                        Button {
                            if !showCalendarPopover {
                                calendarDisplayedMonth = activeEntry?.parsedDate ?? Date()
                                selectedEmptyDateISO = nil
                            }
                            showCalendarPopover.toggle()
                        } label: {
                            Image(systemName: "calendar")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(showCalendarPopover ? ShaveTheme.accent : .primary)
                                .frame(width: 36, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(showCalendarPopover ? ShaveTheme.accentSoft : ShaveTheme.cardBackground(scheme))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(showCalendarPopover ? ShaveTheme.accent.opacity(0.45) : ShaveTheme.cardBorder(scheme), lineWidth: 1)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("日历定位", "Calendar Jump"))
                        .popover(isPresented: $showCalendarPopover, arrowEdge: .bottom) {
                            JournalCalendarPopover(
                                entriesByDate: entriesByDate,
                                activeDateISO: activeEntry?.date,
                                displayedMonth: $calendarDisplayedMonth,
                                selectedEmptyDateISO: $selectedEmptyDateISO,
                                onSelectRecordedDate: { isoDate, dayEntries in
                                    jumpToRecordedDate(isoDate, dayEntries: dayEntries)
                                },
                                onRequestBackfill: { isoDate, date in
                                    showCalendarPopover = false
                                    selectedEmptyDateISO = nil
                                    backfillDateTarget = BackfillDateTarget(id: isoDate, date: date)
                                }
                            )
                            .environmentObject(store)
                        }
                    }

                    HStack(spacing: 7) {
                        Menu {
                            Button(L10n.t("全部效果", "All Results")) { filterResult = nil }
                            Divider()
                            ForEach(ShaveResult.allCases) { r in
                                Button(r.displayName) { filterResult = r }
                            }
                        } label: {
                            Text(filterResult?.displayName ?? L10n.t("效果", "Result"))
                                .font(.system(size: 12.5, weight: filterResult != nil ? .semibold : .medium))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(Capsule().fill(filterResult != nil ? ShaveTheme.accentSoft : ShaveTheme.subtleSurface(scheme)))
                                .foregroundStyle(filterResult != nil ? ShaveTheme.accent : .primary)
                                .contentShape(Capsule())
                        }
                        .menuStyle(.borderlessButton)

                        Menu {
                            Button(L10n.t("全部肤感", "All Comfort")) { filterIrritation = nil }
                            Divider()
                            ForEach(IrritationLevel.allCases) { l in
                                Button(l.displayName) { filterIrritation = l }
                            }
                        } label: {
                            Text(filterIrritation?.displayName ?? L10n.t("肤感", "Comfort"))
                                .font(.system(size: 12.5, weight: filterIrritation != nil ? .semibold : .medium))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(Capsule().fill(filterIrritation != nil ? ShaveTheme.accentSoft : ShaveTheme.subtleSurface(scheme)))
                                .foregroundStyle(filterIrritation != nil ? ShaveTheme.accent : .primary)
                                .contentShape(Capsule())
                        }
                        .menuStyle(.borderlessButton)

                        if hasActiveFilters {
                            Button {
                                searchText = ""
                                filterResult = nil
                                filterIrritation = nil
                            } label: {
                                Text(L10n.t("清除", "Clear"))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(ShaveTheme.accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()
                        Text(L10n.t("\(filteredEntries.count) 篇", "\(filteredEntries.count)"))
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)

                Divider()

                if filteredEntries.isEmpty {
                    VStack {
                        Spacer(minLength: 0)
                        ContentUnavailableView(
                            store.database.entries.isEmpty
                                ? L10n.t("还没有湿剃日记", "No Shave Entries")
                                : L10n.t("无匹配记录", "No Matching Entries"),
                            systemImage: "book.closed",
                            description: Text(
                                store.database.entries.isEmpty
                                    ? L10n.t("点击右上角「记一次 SOTD」开始记录", "Click New SOTD to log your first shave")
                                    : L10n.t("尝试更换关键词或清除筛选", "Try another keyword or clear filters")
                            )
                        )
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(filteredEntries) { entry in
                                    EntryRowCard(
                                        entry: entry,
                                        isSelected: activeEntry?.id == entry.id
                                    )
                                    .id(entry.id)
                                    .onTapGesture(count: 2) {
                                        selectedEntryID = entry.id
                                        editingEntry = entry
                                    }
                                    .onTapGesture(count: 1) {
                                        selectedEntryID = entry.id
                                    }
                                    .contextMenu {
                                        Button {
                                            selectedEntryID = entry.id
                                            editingEntry = entry
                                        } label: {
                                            Label(L10n.t("编辑", "Edit"), systemImage: "pencil")
                                        }
                                        Button {
                                            copySOTD(entry)
                                        } label: {
                                            Label(L10n.t("复制 SOTD", "Copy SOTD"), systemImage: "doc.on.doc")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            entryToDelete = entry
                                        } label: {
                                            Label(L10n.t("删除", "Delete"), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(14)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: scrollRequestToken) { _, _ in
                            guard let targetID = scrollTargetID else { return }
                            DispatchQueue.main.async {
                                withAnimation(.easeInOut(duration: 0.24)) {
                                    proxy.scrollTo(targetID, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: .infinity, alignment: .top)

            // 右侧：SOTD 详情面板
            if let entry = activeEntry {
                EntryDetailPane(
                    entry: entry,
                    onCopySOTD: { copySOTD(entry) },
                    onEdit: { editingEntry = entry },
                    onDelete: { entryToDelete = entry }
                )
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    ContentUnavailableView {
                        Label(
                            store.database.entries.isEmpty
                                ? L10n.t("湿剃日记", "WetShave Journal")
                                : L10n.t("选择一篇日记", "Select an Entry"),
                            systemImage: "text.book.closed"
                        )
                    } actions: {
                        Button {
                            onCreateNew()
                        } label: {
                            Label(L10n.t("记一次 SOTD", "New SOTD"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaveTheme.accent)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editingEntry) { entry in
            EntryEditorSheet(editingEntry: entry)
                .environmentObject(store)
        }
        .sheet(item: $backfillDateTarget) { target in
            EntryEditorSheet(editingEntry: nil, initialDate: target.date) { saved in
                if hasActiveFilters {
                    searchText = ""
                    filterResult = nil
                    filterIrritation = nil
                }
                selectedEntryID = saved.id
                scrollTargetID = saved.id
                scrollRequestToken = UUID()
            }
            .environmentObject(store)
        }
        .alert(L10n.t("删除这篇 SOTD 日记？", "Delete this SOTD entry?"), isPresented: Binding(
            get: { entryToDelete != nil },
            set: { if !$0 { entryToDelete = nil } }
        )) {
            Button(L10n.t("取消", "Cancel"), role: .cancel) { entryToDelete = nil }
            Button(L10n.t("删除", "Delete"), role: .destructive) {
                if let e = entryToDelete {
                    if case .success = store.deleteEntry(e), selectedEntryID == e.id {
                        selectedEntryID = nil
                    }
                }
                entryToDelete = nil
            }
        } message: {
            Text(L10n.t("删除后仅从本地日记移除，不影响 Apple 备忘录原件。", "This removes the entry locally without affecting Apple Notes."))
        }
    }

    private func jumpToRecordedDate(_ isoDate: String, dayEntries: [JournalEntry]) {
        guard !dayEntries.isEmpty else { return }
        selectedEmptyDateISO = nil

        let visibleIDs = Set(filteredEntries.map(\.id))
        let hasVisibleMatch = dayEntries.contains { visibleIDs.contains($0.id) }
        if !hasVisibleMatch && hasActiveFilters {
            searchText = ""
            filterResult = nil
            filterIrritation = nil
            store.showToast(
                L10n.t("已清除冲突筛选并定位到 \(isoDate)", "Cleared filters and jumped to \(isoDate)"),
                isLoading: false
            )
        }

        let target: JournalEntry
        if dayEntries.count > 1,
           let currentID = selectedEntryID,
           let currentIdx = dayEntries.firstIndex(where: { $0.id == currentID }) {
            target = dayEntries[(currentIdx + 1) % dayEntries.count]
        } else {
            target = dayEntries[0]
        }

        selectedEntryID = target.id
        scrollTargetID = target.id
        scrollRequestToken = UUID()
    }

    private func copySOTD(_ entry: JournalEntry) {
        let text = store.formatSOTDForSharing(entry)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.showToast(L10n.t("已复制 SOTD 到剪贴板", "SOTD copied to clipboard"), isLoading: false)
    }
}

private struct EntryRowCard: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let entry: JournalEntry
    let isSelected: Bool

    private struct RowGearSlot: Identifiable {
        let id: String
        let category: GearCategory
        let brand: String
        let shortName: String
        let fullLabel: String
    }

    private func buildGearSlots() -> [RowGearSlot] {
        var slots: [RowGearSlot] = []

        func appendSlot(category: GearCategory, rawValue: String) {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "无", trimmed != "-" else { return }
            let (_, ov) = store.resolveGear(category: category, rawValue: trimmed)
            let displayModel = ov.displayModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortName = displayModel.isEmpty ? ov.name : displayModel
            let brandText = L10n.brandDisplay(ov.brand)
            let isGenericBrand = ov.brand.isEmpty || ov.brand == "品牌未注明" || ov.brand == "无品牌" || ov.brand == "仿刀"
            let fullLabel: String
            if isGenericBrand || shortName.lowercased().hasPrefix(brandText.lowercased()) {
                fullLabel = "\(category.singularName)：\(shortName)"
            } else {
                fullLabel = "\(category.singularName)：\(brandText) \(shortName)"
            }
            slots.append(
                RowGearSlot(
                    id: category.rawValue,
                    category: category,
                    brand: ov.brand,
                    shortName: shortName,
                    fullLabel: fullLabel
                )
            )
        }

        appendSlot(category: .razor, rawValue: entry.primaryRazor)
        appendSlot(category: .brush, rawValue: entry.brush)
        appendSlot(category: .soap, rawValue: entry.soap)
        appendSlot(category: .afterShave, rawValue: entry.afterShave)
        return slots
    }

    var body: some View {
        let proc = store.parsedProcess(for: entry)
        let gearSlots = buildGearSlots()

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(entry.date)
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(isSelected ? ShaveTheme.accent.opacity(0.85) : .secondary.opacity(0.85))
                if entry.hasSyncConflict == true {
                    TagPill(text: L10n.t("同步冲突", "Conflict"), color: ShaveTheme.crimson)
                } else if entry.suspectedDuplicate == true {
                    TagPill(text: L10n.t("疑似重复", "Dup?"), color: ShaveTheme.amber)
                }
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    if let irr = proc.irritation {
                        TagPill(text: irr.displayName, color: ShaveTheme.irritationColor(irr))
                    }
                    if let res = proc.result {
                        TagPill(text: res.displayName, color: ShaveTheme.forest, filled: res == .bbs)
                    }
                }
            }

            if gearSlots.isEmpty {
                Text(L10n.t("未记录装备", "No gear recorded"))
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(minimum: 0), spacing: 8, alignment: .leading),
                        GridItem(.flexible(minimum: 0), spacing: 8, alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(gearSlots) { slot in
                        HStack(spacing: 6) {
                            BrandAvatarView(brand: slot.brand, size: 17, category: slot.category)
                            Text(slot.shortName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(slot.fullLabel)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? ShaveTheme.accentSoft : ShaveTheme.cardBackground(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? ShaveTheme.accent.opacity(0.50) : ShaveTheme.cardBorder(scheme), lineWidth: isSelected ? 1.4 : 1)
        )
        .contentShape(Rectangle())
    }
}

private struct EntryDetailPane: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let entry: JournalEntry
    let onCopySOTD: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var setupGridWidth: CGFloat = 600

    private struct SetupTileEntry: Identifiable {
        let id: String
        let category: GearCategory
        let rawValue: String
    }

    /// 按「剃须刀/刀片、剃须刷/剃须皂、须前/须后、剃须碗」双列配对顺序编排本日装备
    private func buildPairedSetupTiles() -> [SetupTileEntry] {
        var list: [SetupTileEntry] = []
        let razors = entry.fieldValues(matching: ["剃须刀"])
        let blades = entry.fieldValues(matching: ["刀片"])
        let maxPair = max(razors.count, blades.count)
        for idx in 0..<maxPair {
            if idx < razors.count {
                list.append(SetupTileEntry(id: "razor-\(idx)-\(razors[idx])", category: .razor, rawValue: razors[idx]))
            }
            if idx < blades.count {
                list.append(SetupTileEntry(id: "blade-\(idx)-\(blades[idx])", category: .blade, rawValue: blades[idx]))
            }
        }
        if !entry.brush.isEmpty {
            list.append(SetupTileEntry(id: "brush-\(entry.brush)", category: .brush, rawValue: entry.brush))
        }
        if !entry.soap.isEmpty {
            list.append(SetupTileEntry(id: "soap-\(entry.soap)", category: .soap, rawValue: entry.soap))
        }
        if !entry.preShave.isEmpty && entry.preShave != "无" {
            list.append(SetupTileEntry(id: "preshave-\(entry.preShave)", category: .preShave, rawValue: entry.preShave))
        }
        if !entry.afterShave.isEmpty && entry.afterShave != "无" {
            list.append(SetupTileEntry(id: "aftershave-\(entry.afterShave)", category: .afterShave, rawValue: entry.afterShave))
        }
        if !entry.bowl.isEmpty {
            list.append(SetupTileEntry(id: "bowl-\(entry.bowl)", category: .bowl, rawValue: entry.bowl))
        }
        return list
    }

    var body: some View {
        let proc = store.parsedProcess(for: entry)
        let setupTiles = buildPairedSetupTiles()
        let setupColumnCount = setupGridWidth >= 480 ? 2 : 1
        let setupColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: setupColumnCount)

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 顶部标题栏 + 复制 SOTD / 编辑 / 删除
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SOTD · \(entry.date)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            if let res = proc.result {
                                TagPill(text: res.fullDescription, color: ShaveTheme.forest, filled: true)
                            }
                            if let irr = proc.irritation {
                                TagPill(text: irr.displayName, color: ShaveTheme.irritationColor(irr))
                            }
                            if entry.hotTowel {
                                TagPill(text: L10n.t("热敷", "Hot Towel"), neutral: true)
                            }
                            if entry.afterShower.hasPrefix("是") {
                                TagPill(text: L10n.t("浴后", "Post-Shower"), neutral: true)
                            }
                            if entry.alum.hasPrefix("是") {
                                TagPill(text: L10n.t("明矾", "Alum"), neutral: true)
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button(action: onCopySOTD) {
                            Label(L10n.t("复制 SOTD", "Copy SOTD"), systemImage: "doc.on.doc")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)

                        Button(action: onEdit) {
                            Label(L10n.t("编辑", "Edit"), systemImage: "pencil")
                                .font(.system(size: 13.5, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isReadOnlyProtected)

                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.isReadOnlyProtected)
                    }
                }

                // 器材组合双列配对网格（窄窗自动回退单列）
                SectionCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(L10n.t("本日装备", "Setup"))
                            .font(.system(size: 16, weight: .semibold))

                        if setupTiles.isEmpty {
                            Text(L10n.t("本篇未记录装备信息", "No gear recorded for this entry"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVGrid(columns: setupColumns, spacing: 12) {
                                ForEach(setupTiles) { tile in
                                    GearMiniTile(category: tile.category, rawValue: tile.rawValue)
                                }
                            }
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .onAppear { setupGridWidth = geo.size.width }
                                        .onChange(of: geo.size.width) { _, newWidth in
                                            setupGridWidth = newWidth
                                        }
                                }
                            )
                        }
                    }
                }

                // 剃须流程与过程卡片
                SectionCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.t("流程与过程", "Shave Details"))
                            .font(.system(size: 16, weight: .semibold))

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ProcessStatPill(
                                title: L10n.t("取皂", "Loading"),
                                value: entry.loadingMethod.isEmpty ? "—" : L10n.loadingDisplay(entry.loadingMethod)
                            )
                            ProcessStatPill(
                                title: L10n.t("起泡", "Lather"),
                                value: entry.pureLatheringMethod.isEmpty ? "—" : L10n.latheringDisplay(entry.pureLatheringMethod)
                            )
                            ProcessStatPill(
                                title: L10n.t("热敷", "Hot Towel"),
                                value: entry.hotTowel ? L10n.t("是", "Yes") : L10n.t("否", "No")
                            )
                            ProcessStatPill(
                                title: L10n.t("浴后 / 明矾", "Shower / Alum"),
                                value: "\(entry.afterShower.hasPrefix("是") ? L10n.t("浴后", "Shower") : L10n.t("非浴后", "No Shower")) · \(entry.alum.hasPrefix("是") ? L10n.t("明矾", "Alum") : L10n.t("无明矾", "No Alum"))"
                            )
                        }

                        if !proc.passes.isEmpty || !proc.note.isEmpty {
                            Divider()
                        }

                        if !proc.passes.isEmpty {
                            HStack(alignment: .center, spacing: 10) {
                                Text(L10n.t("步骤", "Passes"))
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                FlowLayout(spacing: 8, lineSpacing: 8) {
                                    ForEach(proc.passes) { step in
                                        HStack(spacing: 5) {
                                            Text(step.pass.displayName)
                                                .font(.system(size: 13.5, weight: .semibold))
                                            if !step.setting.isEmpty {
                                                Text(L10n.isEnglish ? "#\(step.setting)" : "\(step.setting)档")
                                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Capsule().fill(ShaveTheme.accentSoft))
                                                    .foregroundStyle(ShaveTheme.accent)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6.5)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
                                    }
                                }
                            }
                        }

                        if !proc.note.isEmpty {
                            Text(proc.note)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

private struct GearMiniTile: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let category: GearCategory
    let rawValue: String

    var body: some View {
        let (_, ov) = store.resolveGear(category: category, rawValue: rawValue)
        let bladeParsed = category == .blade ? GearKnowledgeBase.parseBladeUsage(rawValue) : (rawValue, nil)
        let specTags = GearSpecFormatter.specTags(category: category, override: ov, includeSampleTag: true)
        let resolvedRazorType = category == .razor
            ? (ov.razorType ?? GearKnowledgeBase.inferRazorType(from: ov.name))
            : nil
        let resolvedBladeType = category == .blade
            ? (ov.bladeType ?? GearKnowledgeBase.inferBladeType(from: ov.name))
            : nil

        ZStack(alignment: .bottomTrailing) {
            GearSilhouetteView(
                category: category,
                razorType: resolvedRazorType,
                bladeType: resolvedBladeType,
                size: 70
            )
            .padding(.trailing, 6)
            .padding(.bottom, 2)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(category.singularName)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let use = bladeParsed.1 {
                        TagPill(text: L10n.isEnglish ? L10n.ordinal(use) : "第 \(use) 次", color: ShaveTheme.accent)
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    BrandAvatarView(brand: ov.brand, size: 22, category: category)
                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 5) {
                            Text(L10n.brandDisplay(ov.brand))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if category == .brush, let hb = ov.handleBrand, !hb.isEmpty {
                                Text("×")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                Text(L10n.handleTag(hb))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(ov.displayModel)
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if category == .brush, let ks = ov.knotSize, !ks.isEmpty {
                                Text(ks)
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(ShaveTheme.accentSoft))
                                    .foregroundStyle(ShaveTheme.accent)
                            }
                        }
                    }
                }
                .padding(.trailing, 34)

                if !specTags.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(Array(specTags.enumerated()), id: \.offset) { _, tag in
                            TagPill(text: tag, neutral: true)
                        }
                    }
                    .padding(.trailing, 30)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, minHeight: 92, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(ShaveTheme.subtleSurface(scheme))
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

private struct ProcessStatPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
