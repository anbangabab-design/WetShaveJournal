import SwiftUI

/// 日历定位弹窗（R07 拆出独立组件，复用 JournalStore.parsedProcess(for:) 缓存避免重复正则解析）
struct JournalCalendarPopover: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    let entriesByDate: [String: [JournalEntry]]
    let activeDateISO: String?
    @Binding var displayedMonth: Date
    @Binding var selectedEmptyDateISO: String?
    let onSelectRecordedDate: (String, [JournalEntry]) -> Void
    let onRequestBackfill: (String, Date) -> Void

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        return cal
    }

    private var weekdaySymbols: [String] {
        L10n.isEnglish
            ? ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
            : ["日", "一", "二", "三", "四", "五", "六"]
    }

    private var currentYear: Int {
        calendar.component(.year, from: displayedMonth)
    }

    private var currentMonth: Int {
        calendar.component(.month, from: displayedMonth)
    }

    private var availableYears: [Int] {
        let nowYear = calendar.component(.year, from: Date())
        let entryYears = entriesByDate.keys.compactMap { Int($0.prefix(4)) }
        let minY = min(entryYears.min() ?? nowYear, min(nowYear - 1, currentYear))
        let maxY = max(entryYears.max() ?? nowYear, max(nowYear + 1, currentYear))
        return Array(minY...maxY).reversed()
    }

    private var todayISO: String {
        JournalDateFormatter.isoDay.string(from: Date())
    }

    private struct DayCell: Identifiable {
        let id: String
        let dayNumber: Int?
        let date: Date?
        let isoDate: String?
    }

    private var monthCells: [DayCell] {
        var comps = DateComponents()
        comps.year = currentYear
        comps.month = currentMonth
        comps.day = 1
        guard let firstOfMonth = calendar.date(from: comps),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let leadingBlanks = max(0, firstWeekday - 1)
        var cells: [DayCell] = []

        for idx in 0..<leadingBlanks {
            cells.append(DayCell(id: "blank-\(idx)", dayNumber: nil, date: nil, isoDate: nil))
        }

        for day in dayRange {
            var dComps = comps
            dComps.day = day
            if let d = calendar.date(from: dComps) {
                let iso = JournalDateFormatter.isoDay.string(from: d)
                cells.append(DayCell(id: iso, dayNumber: day, date: d, isoDate: iso))
            }
        }
        return cells
    }

    private func monthShortName(_ month: Int) -> String {
        guard L10n.isEnglish else { return "\(month)月" }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return (1...12).contains(month) ? names[month - 1] : "\(month)"
    }

    private func monthMenuName(_ month: Int) -> String {
        guard L10n.isEnglish else { return "\(month)月" }
        let names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        return (1...12).contains(month) ? names[month - 1] : "\(month)"
    }

    private func dotColor(for entry: JournalEntry) -> Color {
        let parsed = store.parsedProcess(for: entry)
        let text = entry.processText.lowercased()
        let hasCut = text.contains("刮伤") || text.contains("出血") || text.contains("破皮")
            || text.contains("cut") || text.contains("nick") || text.contains("bleed") || text.contains("weeper")
        if parsed.irritation == .stinging || hasCut {
            return ShaveTheme.crimson
        }
        if parsed.irritation == .mild {
            return ShaveTheme.amber
        }
        return ShaveTheme.forest
    }

    private func setMonth(year: Int, month: Int) {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        if let newDate = calendar.date(from: comps) {
            displayedMonth = newDate
        }
    }

    private func shiftMonth(by delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = next
        }
    }

    private func jumpToToday() {
        let now = Date()
        displayedMonth = now
        let iso = todayISO
        if let todayEntries = entriesByDate[iso], !todayEntries.isEmpty {
            onSelectRecordedDate(iso, todayEntries)
        } else {
            selectedEmptyDateISO = iso
        }
    }

    var body: some View {
        let _ = store.language
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    shiftMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("上个月", "Previous Month"))

                HStack(spacing: 4) {
                    if L10n.isEnglish {
                        monthMenu
                        yearMenu
                    } else {
                        yearMenu
                        monthMenu
                    }
                }

                Button {
                    shiftMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("下个月", "Next Month"))

                Spacer(minLength: 4)

                Button {
                    jumpToToday()
                } label: {
                    Text(L10n.t("今天", "Today"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ShaveTheme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(ShaveTheme.accentSoft))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, sym in
                    Text(sym)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(monthCells) { cell in
                    if let day = cell.dayNumber, let iso = cell.isoDate {
                        let dayEntries = entriesByDate[iso] ?? []
                        let isActive = activeDateISO == iso
                        let isToday = todayISO == iso
                        let isSelectedEmpty = selectedEmptyDateISO == iso && dayEntries.isEmpty

                        Button {
                            if !dayEntries.isEmpty {
                                onSelectRecordedDate(iso, dayEntries)
                            } else {
                                selectedEmptyDateISO = iso
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 3) {
                                    Text("\(day)")
                                        .font(.system(size: 12.5, weight: (isActive || isToday || !dayEntries.isEmpty) ? .semibold : .regular, design: .rounded))
                                        .foregroundStyle(
                                            isActive
                                                ? Color.white
                                                : (isToday ? ShaveTheme.accent : (dayEntries.isEmpty ? .secondary : .primary))
                                        )

                                    if !dayEntries.isEmpty {
                                        HStack(spacing: 2.5) {
                                            ForEach(Array(dayEntries.prefix(2).enumerated()), id: \.offset) { _, entry in
                                                Circle()
                                                    .fill(isActive ? Color.white.opacity(0.92) : dotColor(for: entry))
                                                    .frame(width: dayEntries.count > 1 ? 4.5 : 5, height: dayEntries.count > 1 ? 4.5 : 5)
                                            }
                                        }
                                        .frame(height: 6)
                                    } else {
                                        Color.clear.frame(height: 6)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(
                                            isActive
                                                ? ShaveTheme.accent
                                                : (isSelectedEmpty ? ShaveTheme.accentSoft : Color.clear)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            isActive
                                                ? Color.clear
                                                : (isSelectedEmpty
                                                    ? ShaveTheme.accent.opacity(0.55)
                                                    : (isToday ? ShaveTheme.accent.opacity(0.6) : Color.clear)),
                                            lineWidth: 1.2
                                        )
                                )

                                if dayEntries.count > 1 {
                                    Text("\(dayEntries.count)")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(isActive ? Color.white.opacity(0.95) : ShaveTheme.accent)
                                        .padding(.trailing, 3)
                                        .padding(.top, 1.5)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(tooltipText(iso: iso, entries: dayEntries))
                    } else {
                        Color.clear
                            .frame(height: 36)
                    }
                }
            }

            Divider()

            HStack(spacing: 10) {
                legendItem(color: ShaveTheme.forest, label: L10n.t("无痛", "Painless"))
                legendItem(color: ShaveTheme.amber, label: L10n.t("微痛", "Mild"))
                legendItem(color: ShaveTheme.crimson, label: L10n.t("刺痛/刮伤", "Sting/Cut"))
                Spacer()
                Text(L10n.t("本月 \(monthRecordCount) 次", "\(monthRecordCount) this mo"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let emptyISO = selectedEmptyDateISO,
               let emptyDate = JournalDateFormatter.isoDay.date(from: emptyISO),
               (entriesByDate[emptyISO] ?? []).isEmpty {
                HStack(spacing: 8) {
                    Text(L10n.t("\(emptyISO) 暂无记录", "No entry on \(emptyISO)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        onRequestBackfill(emptyISO, emptyDate)
                    } label: {
                        Label(L10n.t("补记这一天", "Log This Day"), systemImage: "plus.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(ShaveTheme.accent)
                    .controlSize(.small)
                    .disabled(store.isReadOnlyProtected)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
            } else if let activeISO = activeDateISO,
                      let activeDayEntries = entriesByDate[activeISO],
                      activeDayEntries.count > 1 {
                Text(L10n.t(
                    "\(activeISO) 当天共有 \(activeDayEntries.count) 条记录，再次点击该日期可依次切换",
                    "\(activeDayEntries.count) entries on \(activeISO) — click the date again to cycle"
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 312)
    }

    private var monthRecordCount: Int {
        let prefix = String(format: "%04d-%02d-", currentYear, currentMonth)
        return entriesByDate
            .filter { $0.key.hasPrefix(prefix) }
            .values
            .reduce(0) { $0 + $1.count }
    }

    private var yearMenu: some View {
        Menu {
            ForEach(availableYears, id: \.self) { yr in
                Button(L10n.isEnglish ? "\(yr)" : "\(yr)年") {
                    setMonth(year: yr, month: currentMonth)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(L10n.isEnglish ? "\(currentYear)" : "\(currentYear)年")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var monthMenu: some View {
        Menu {
            ForEach(1...12, id: \.self) { m in
                Button(monthMenuName(m)) {
                    setMonth(year: currentYear, month: m)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(monthShortName(currentMonth))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ShaveTheme.subtleSurface(scheme)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func tooltipText(iso: String, entries: [JournalEntry]) -> String {
        guard !entries.isEmpty else {
            return L10n.t("\(iso) · 暂无记录", "\(iso) · No entry")
        }
        if entries.count == 1 {
            let e = entries[0]
            let r = e.primaryRazor.isEmpty ? L10n.t("未记录剃须刀", "No razor") : e.primaryRazor
            return "\(iso) · \(r)"
        }
        return L10n.t("\(iso) · 共 \(entries.count) 条记录", "\(iso) · \(entries.count) entries")
    }
}
