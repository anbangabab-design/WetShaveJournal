import SwiftUI
import Charts
import AppKit

struct StatsView: View {
    @EnvironmentObject var store: JournalStore
    @Environment(\.colorScheme) private var scheme

    @State private var selectedBrandCategory: GearCategory = .razor
    @State private var comboFilter: ComboRankMode = .best

    // AI 功能 ④：个人湿剃复盘诊断
    @State private var isGeneratingDiagnosis: Bool = false
    @State private var diagnosisText: String = ""
    @State private var diagnosisModel: String = ""
    @State private var diagnosisNotice: String? = nil

    enum ComboRankMode: String, CaseIterable, Identifiable {
        case best = "黄金搭配"
        case warning = "避雷/易刺激"
        case mostUsed = "最常用组合"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .best: return L10n.t("黄金搭配", "Top Combos")
            case .warning: return L10n.t("易刺激", "Irritation")
            case .mostUsed: return L10n.t("最常用", "Most Used")
            }
        }
    }

    private var entries: [JournalEntry] { store.database.entries }
    private var snapshot: StatisticsSnapshot { store.statisticsSnapshot }

    private var bbsRate: Double { snapshot.bbsRate }
    private var painlessRate: Double { snapshot.painlessRate }
    private var avgIntervalDays: Double { snapshot.avgIntervalDays }

    struct MonthlyPoint: Identifiable {
        let id: String
        let monthLabel: String
        let count: Int
    }

    private var monthlySeries: [MonthlyPoint] {
        snapshot.monthlyTrend.map { pt in
            let parts = pt.month.split(separator: "-")
            let label = parts.count == 2 ? "\(parts[0].suffix(2))/\(parts[1])" : pt.month
            return MonthlyPoint(id: pt.month, monthLabel: label, count: pt.count)
        }
    }

    struct SliceDatum: Identifiable {
        let id: String
        let label: String
        let count: Int
    }

    private var razorTypeDistribution: [SliceDatum] {
        let razors = store.gearItems(for: .razor)
        var map: [String: Int] = [:]
        for r in razors where r.count > 0 {
            let label = r.razorType?.groupLabel ?? L10n.t("未分类", "Other")
            map[label, default: 0] += r.count
        }
        return map.map { SliceDatum(id: $0.key, label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var razorMaterialDistribution: [SliceDatum] {
        let razors = store.gearItems(for: .razor)
        var map: [String: Int] = [:]
        for r in razors where r.count > 0 {
            let mat = r.material.map(L10n.materialDisplay) ?? L10n.t("未标注", "Unknown")
            map[mat, default: 0] += r.count
        }
        return map.map { SliceDatum(id: $0.key, label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(8)
            .map { $0 }
    }

    private var brushMaterialDistribution: [SliceDatum] {
        let brushes = store.gearItems(for: .brush)
        var map: [String: Int] = [:]
        for b in brushes where b.count > 0 {
            var label = b.brushMaterial?.displayName ?? L10n.t("未标注", "Unknown")
            if b.brushMaterial == .badger, let tr = b.badgerTreatment {
                label = "\(b.brushMaterial!.displayName) · \(tr.displayName)"
            }
            map[label, default: 0] += b.count
        }
        return map.map { SliceDatum(id: $0.key, label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var topBrands: [SliceDatum] {
        store.brandGroups(for: selectedBrandCategory)
            .filter { $0.totalUses > 0 }
            .prefix(10)
            .map { SliceDatum(id: $0.brand, label: L10n.brandDisplay($0.brand), count: $0.totalUses) }
    }

    private var irritationDistribution: [SliceDatum] {
        let map = snapshot.irritationCountsByLevel
        return IrritationLevel.allCases.map {
            SliceDatum(id: $0.rawValue, label: $0.displayName, count: map[$0] ?? 0)
        }
    }

    private var comboRanking: [RazorBladeComboStat] {
        let all = snapshot.comboStats
        switch comboFilter {
        case .best:
            return all.filter { $0.uses >= 2 }
                .sorted { a, b in
                    if abs(a.comfortScore - b.comfortScore) > 0.05 { return a.comfortScore > b.comfortScore }
                    return a.uses > b.uses
                }
                .prefix(8).map { $0 }
        case .warning:
            return all.filter { $0.stingingCount > 0 || ($0.mildCount > 0 && $0.painlessCount == 0) }
                .sorted { a, b in
                    if a.stingingCount != b.stingingCount { return a.stingingCount > b.stingingCount }
                    return a.stingingRate > b.stingingRate
                }
                .prefix(8).map { $0 }
        case .mostUsed:
            return all.prefix(8).map { $0 }
        }
    }

    var body: some View {
        let _ = store.language
        if entries.isEmpty {
            VStack {
                Spacer(minLength: 0)
                ContentUnavailableView(
                    L10n.t("暂无统计数据", "No Statistics Yet"),
                    systemImage: "chart.xyaxis.line",
                    description: Text(L10n.t("记录第一篇 SOTD 或同步备忘录后将自动生成图表", "Log your first SOTD or sync Apple Notes to see insights"))
                )
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 顶部标题 + AI 复盘按钮
                    HStack(alignment: .center) {
                        Text(L10n.t("数据统计", "Statistics"))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Spacer()
                        Button {
                            Task { await runAIDiagnosis() }
                        } label: {
                            HStack(spacing: 6) {
                                if isGeneratingDiagnosis { ProgressView().controlSize(.small) }
                                Label(
                                    isGeneratingDiagnosis ? L10n.t("分析中...", "Analyzing...") : L10n.t("生成 AI 复盘", "AI Review"),
                                    systemImage: "sparkles"
                                )
                                .font(.system(size: 13.5, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ShaveTheme.accent)
                        .disabled(isGeneratingDiagnosis)
                    }

                    if let notice = diagnosisNotice {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(ShaveTheme.amber)
                            Text(notice)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { diagnosisNotice = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(13)
                        .background(RoundedRectangle(cornerRadius: 11).fill(ShaveTheme.cardBackground(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(ShaveTheme.amber.opacity(0.45), lineWidth: 1))
                    }

                    if !diagnosisText.isEmpty {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Label(L10n.t("AI 个人湿剃复盘诊断", "AI Personal Shave Diagnosis"), systemImage: "sparkles")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(ShaveTheme.accent)
                                    if !diagnosisModel.isEmpty {
                                        TagPill(text: diagnosisModel, neutral: true)
                                    }
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(diagnosisText, forType: .string)
                                        store.showToast(L10n.t("已复制 AI 复盘报告", "Copied AI review to clipboard"), isLoading: false)
                                    } label: {
                                        Label(L10n.t("复制", "Copy"), systemImage: "doc.on.doc")
                                            .font(.system(size: 12.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    Button {
                                        Task { await runAIDiagnosis() }
                                    } label: {
                                        Label(L10n.t("重新生成", "Regenerate"), systemImage: "arrow.clockwise")
                                            .font(.system(size: 12.5))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(isGeneratingDiagnosis)
                                }

                                Text(diagnosisText)
                                    .font(.system(size: 14))
                                    .lineSpacing(4)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    // 第一排：自适应 KPI 卡片
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 185, maximum: 280), spacing: 16)],
                        spacing: 16
                    ) {
                        KPICard(title: L10n.t("总刮剃", "Total Shaves"), value: "\(entries.count)")
                        KPICard(title: L10n.t("BBS 率", "BBS Rate"), value: "\(Int(bbsRate * 100))%")
                        KPICard(title: L10n.t("无痛率", "Painless Rate"), value: "\(Int(painlessRate * 100))%")
                        KPICard(title: L10n.t("平均间隔", "Avg Interval"), value: String(format: L10n.isEnglish ? "%.1f d" : "%.1f 天", avgIntervalDays))
                        KPICard(title: L10n.t("剃须刀", "Razors"), value: "\(store.gearItems(for: .razor).count)")
                    }

                    // 第二排：月度刮剃频次趋势 + 活跃热力日历
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 420), spacing: 18)],
                        spacing: 18
                    ) {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("近 12 个月刮剃频次", "Monthly Shaves (12M)"))
                                    .font(.system(size: 16, weight: .semibold))

                                Chart(monthlySeries) { pt in
                                    BarMark(
                                        x: .value("Month", pt.monthLabel),
                                        y: .value("Count", pt.count)
                                    )
                                    .foregroundStyle(ShaveTheme.accent.opacity(0.78).gradient)
                                    .cornerRadius(5)

                                    LineMark(
                                        x: .value("Month", pt.monthLabel),
                                        y: .value("Count", pt.count)
                                    )
                                    .foregroundStyle(Color.primary.opacity(0.5))
                                    .interpolationMethod(.catmullRom)
                                    .lineStyle(StrokeStyle(lineWidth: 2))

                                    PointMark(
                                        x: .value("Month", pt.monthLabel),
                                        y: .value("Count", pt.count)
                                    )
                                    .foregroundStyle(ShaveTheme.accent)
                                    .symbolSize(24)
                                }
                                .frame(height: 220)
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }

                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("活跃热力日历", "Activity Heatmap"))
                                    .font(.system(size: 16, weight: .semibold))
                                ShaveHeatmapGrid(entriesByDate: snapshot.entriesByDate)
                                    .frame(minHeight: 220, maxHeight: .infinity)
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    }

                    // 第三排：刀型 + 刷毛 + 肤感
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 18)],
                        spacing: 18
                    ) {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("剃须刀类型", "Razor Types"))
                                    .font(.system(size: 16, weight: .semibold))
                                Chart(razorTypeDistribution) { item in
                                    SectorMark(
                                        angle: .value("Count", item.count),
                                        innerRadius: .ratio(0.56),
                                        angularInset: 2
                                    )
                                    .cornerRadius(4)
                                    .foregroundStyle(by: .value("Type", item.label))
                                }
                                .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                                .frame(height: 220)
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }

                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("剃须刷材质", "Brush Hair"))
                                    .font(.system(size: 16, weight: .semibold))
                                Chart(brushMaterialDistribution) { item in
                                    SectorMark(
                                        angle: .value("Count", item.count),
                                        innerRadius: .ratio(0.56),
                                        angularInset: 2
                                    )
                                    .cornerRadius(4)
                                    .foregroundStyle(by: .value("Hair", item.label))
                                }
                                .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                                .frame(height: 220)
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }

                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("肤感分布", "Comfort"))
                                    .font(.system(size: 16, weight: .semibold))
                                Chart(irritationDistribution) { item in
                                    BarMark(
                                        x: .value("Level", item.label),
                                        y: .value("Count", item.count)
                                    )
                                    .foregroundStyle(colorForIrritationID(item.id).gradient)
                                    .cornerRadius(7)
                                    .annotation(position: .top) {
                                        Text("\(item.count)")
                                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(height: 220)
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    }

                    // 第四排：品牌排行 + 剃须刀材质排行
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 420), spacing: 18)],
                        spacing: 18
                    ) {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 10) {
                                    Text(L10n.t("品牌 TOP 10", "Top Brands"))
                                        .font(.system(size: 16, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Picker("Category", selection: $selectedBrandCategory) {
                                        ForEach([GearCategory.razor, .brush, .soap, .blade], id: \.self) { cat in
                                            Text(cat.displayName).tag(cat)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(maxWidth: 265)
                                }

                                HorizontalRankingBarList(
                                    items: topBrands,
                                    barColor: ShaveTheme.accent,
                                    labelWidth: 118,
                                    valueWidth: 38
                                )
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }

                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text(L10n.t("剃须刀材质", "Razor Materials"))
                                    .font(.system(size: 16, weight: .semibold))
                                HorizontalRankingBarList(
                                    items: razorMaterialDistribution,
                                    barColor: ShaveTheme.forest,
                                    labelWidth: 100,
                                    valueWidth: 38
                                )
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    }

                    // 第五排：刀+刀片搭配 + 刀片寿命
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 420), spacing: 18)],
                        spacing: 18
                    ) {
                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 10) {
                                    Text(L10n.t("刀 + 刀片搭配", "Razor + Blade Combos"))
                                        .font(.system(size: 16, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Picker("Mode", selection: $comboFilter) {
                                        ForEach(ComboRankMode.allCases) { m in
                                            Text(m.displayName).tag(m)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(maxWidth: 270)
                                }

                                if comboRanking.isEmpty {
                                    Text(L10n.t("暂无数据", "No data"))
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 20)
                                } else {
                                    VStack(spacing: 9) {
                                        ForEach(Array(comboRanking.enumerated()), id: \.element.id) { idx, stat in
                                            let fullComboTitle = "\(stat.razorName) + \(stat.bladeName)"
                                            HStack(spacing: 10) {
                                                Text("#\(idx + 1)")
                                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .frame(width: 26, alignment: .leading)

                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(fullComboTitle)
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                        .lineLimit(1)
                                                        .truncationMode(.tail)
                                                        .help(fullComboTitle)
                                                    Text(L10n.t(
                                                        "\(stat.uses) 次 · 无痛 \(stat.painlessCount) · 微痛 \(stat.mildCount) · 刺痛 \(stat.stingingCount)",
                                                        "\(stat.uses)x · Painless \(stat.painlessCount) · Mild \(stat.mildCount) · Stinging \(stat.stingingCount)"
                                                    ))
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                                HStack(spacing: 5) {
                                                    TagPill(text: "BBS \(Int(stat.bbsRate * 100))%", color: ShaveTheme.forest)
                                                    TagPill(
                                                        text: L10n.t("无痛 \(Int(stat.painlessRate * 100))%", "\(Int(stat.painlessRate * 100))%"),
                                                        color: stat.stingingCount > 0 ? ShaveTheme.crimson : ShaveTheme.accent
                                                    )
                                                }
                                                .fixedSize()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .background(RoundedRectangle(cornerRadius: 9).fill(ShaveTheme.subtleSurface(scheme)))
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }

                        SectionCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 8) {
                                    Text(L10n.t("刀片寿命", "Blade Longevity"))
                                        .font(.system(size: 16, weight: .semibold))
                                    TagPill(text: L10n.t("序号估算", "Est."), neutral: true)
                                        .help(L10n.t(
                                            "基于日记中记录的刀片使用序号推算平均周期，不含物理刀片编号，仅供参考",
                                            "Estimated from recorded ordinal blade counts without physical blade IDs"
                                        ))
                                }

                                let blades = Array(snapshot.bladeLongevityStats.prefix(8))
                                if blades.isEmpty {
                                    Text(L10n.t("暂无数据", "No data"))
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, 20)
                                } else {
                                    VStack(spacing: 9) {
                                        ForEach(blades) { b in
                                            HStack(spacing: 10) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(b.bladeName)
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                        .lineLimit(1)
                                                        .truncationMode(.tail)
                                                        .help(b.bladeName)
                                                    Text(L10n.t(
                                                        "累计 \(b.totalShaves) 次 · 单片最高 \(b.maxUseCount) 次",
                                                        "\(b.totalShaves) shaves · Max \(b.maxUseCount)/blade"
                                                    ))
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)

                                                Text(String(format: L10n.isEnglish ? "%.1f / blade" : "均 %.1f 次", b.avgCycleUses))
                                                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(ShaveTheme.accent)
                                                    .fixedSize()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .background(RoundedRectangle(cornerRadius: 9).fill(ShaveTheme.subtleSurface(scheme)))
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .padding(28)
            }
        }
    }

    private func runAIDiagnosis() async {
        guard store.aiConfig.isReady else {
            diagnosisNotice = L10n.t("请先在「外观与设置 → AI 识别接口」中启用并填写 API Key，即可生成个人湿剃复盘报告。", "Enable and configure your AI API key in Settings to generate a personal shave diagnosis.")
            return
        }

        isGeneratingDiagnosis = true
        diagnosisNotice = nil
        defer { isGeneratingDiagnosis = false }

        do {
            let summary = store.buildDiagnosisStatsSummary()
            let (report, model) = try await WebGearRecognizer.shared.generateShaveDiagnosis(
                statsSummary: summary,
                aiConfig: store.aiConfig
            )
            diagnosisText = report
            diagnosisModel = model
        } catch {
            diagnosisNotice = L10n.t("AI 复盘生成失败：\(error.localizedDescription)", "AI review failed: \(error.localizedDescription)")
        }
    }

    private func colorForIrritationID(_ rawID: String) -> Color {
        switch rawID {
        case "无痛": return ShaveTheme.forest
        case "微痛": return ShaveTheme.amber
        case "刺痛": return ShaveTheme.crimson
        default: return .secondary
        }
    }
}

private struct KPICard: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(ShaveTheme.cardBackground(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1))
    }
}

private struct ShaveHeatmapGrid: View {
    @Environment(\.colorScheme) private var scheme
    let entriesByDate: [String: [JournalEntry]]

    private var weeks: [[Date]] {
        let cal = Calendar.current
        let anchor: Date = {
            if let latestKey = entriesByDate.keys.max(),
               let parsed = JournalDateFormatter.isoDay.date(from: latestKey) {
                return parsed
            }
            return Date()
        }()
        let totalWeeks = 22
        let endOfWeek = cal.date(byAdding: .day, value: (7 - cal.component(.weekday, from: anchor)), to: anchor) ?? anchor
        let start = cal.date(byAdding: .day, value: -(totalWeeks * 7 - 1), to: endOfWeek) ?? anchor

        var grid: [[Date]] = []
        var cur = start
        for _ in 0..<totalWeeks {
            var week: [Date] = []
            for _ in 0..<7 {
                week.append(cur)
                cur = cal.date(byAdding: .day, value: 1, to: cur) ?? cur
            }
            grid.append(week)
        }
        return grid
    }

    var body: some View {
        let weekCount = CGFloat(max(1, weeks.count))

        GeometryReader { geo in
            let spacing: CGFloat = 4
            let rawCell = (geo.size.width - spacing * (weekCount - 1)) / weekCount
            let cellSize = max(8, min(16, floor(rawCell)))

            VStack(alignment: .leading, spacing: 14) {
                Spacer(minLength: 0)

                HStack(spacing: spacing) {
                    ForEach(0..<weeks.count, id: \.self) { wIdx in
                        VStack(spacing: spacing) {
                            ForEach(0..<7, id: \.self) { dIdx in
                                let day = weeks[wIdx][dIdx]
                                let key = JournalDateFormatter.isoDay.string(from: day)
                                let cnt = entriesByDate[key]?.count ?? 0
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(cellColor(cnt))
                                    .frame(width: cellSize, height: cellSize)
                                    .help("\(key): \(cnt)")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 6) {
                    Spacer()
                    Text(L10n.t("少", "Less")).font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach([0, 1, 2], id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(cellColor(level))
                            .frame(width: 11, height: 11)
                    }
                    Text(L10n.t("多", "More")).font(.system(size: 12)).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cellColor(_ count: Int) -> Color {
        if count == 0 {
            return scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
        }
        if count == 1 {
            return ShaveTheme.forest.opacity(0.75)
        }
        return ShaveTheme.accent
    }
}

private struct HorizontalRankingBarList: View {
    @Environment(\.colorScheme) private var scheme
    let items: [StatsView.SliceDatum]
    let barColor: Color
    var labelWidth: CGFloat = 112
    var valueWidth: CGFloat = 38

    private var maxCount: Int {
        max(1, items.map(\.count).max() ?? 1)
    }

    var body: some View {
        if items.isEmpty {
            Text(L10n.t("暂无数据", "No data"))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    let ratio = CGFloat(item.count) / CGFloat(maxCount)
                    HStack(spacing: 10) {
                        Text(item.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: labelWidth, alignment: .trailing)
                            .help(item.label)

                        GeometryReader { geo in
                            let trackWidth = max(0, geo.size.width)
                            let fillWidth = item.count > 0 ? max(8, trackWidth * ratio) : 0
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(ShaveTheme.subtleSurface(scheme))
                                    .frame(height: 12)
                                Capsule()
                                    .fill(barColor.opacity(0.84).gradient)
                                    .frame(width: fillWidth, height: 12)
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 18)

                        Text("\(item.count)")
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: valueWidth, alignment: .trailing)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}
