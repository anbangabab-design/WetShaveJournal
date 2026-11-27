import SwiftUI

/// 紧凑 1:1 正方形器材卡片（v1.4.2）：
/// - 严格锁定 1:1 宽高比（边长约 165–185pt），内容永不撑破正方形比例
/// - 顶部：左原形品牌 Logo（38pt 高，宽标自适应）+ 右使用次数角标与状态小圆点
/// - 中部：品牌小字（混搭刷展示「毛结 × 手柄」）+ 醒目型号主标题（最多 2 行截断，悬浮显示完整信息）
/// - 底部：精简核心属性胶囊单行自动收敛（自动隐藏放不下的尾标，绝不溢出）
struct GearCardView: View {
    @Environment(\.colorScheme) private var scheme
    let item: GearItem

    private struct CompactPill: Identifiable {
        let id: String
        let text: String
        let tint: Color?
    }

    private var hybridHandle: String? {
        guard item.category == .brush,
              let hb = item.handleBrand?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hb.isEmpty,
              hb.lowercased() != item.brand.lowercased() else { return nil }
        return hb
    }

    private var brushKnotSize: String? {
        guard item.category == .brush,
              let ks = item.knotSize?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ks.isEmpty else { return nil }
        return ks
    }

    private var brandSubtitle: String {
        let brandText = L10n.brandDisplay(item.brand)
        if let hb = hybridHandle {
            return "\(brandText) × \(L10n.handleTag(hb))"
        }
        return brandText
    }

    private var bottomPills: [CompactPill] {
        var result: [CompactPill] = []
        if let ks = brushKnotSize {
            result.append(CompactPill(id: "knot-\(ks)", text: ks, tint: ShaveTheme.accent))
        }
        if item.category.supportsSample && item.isSample {
            result.append(CompactPill(id: "sample", text: L10n.t("小样", "Sample"), tint: ShaveTheme.slate))
        }
        let specs = GearSpecFormatter.specTags(for: item)
        for (idx, tag) in specs.prefix(4).enumerated() {
            result.append(CompactPill(id: "spec-\(idx)-\(tag)", text: tag, tint: nil))
        }
        return result
    }

    private var fullHoverSummary: String {
        var lines: [String] = []
        let brandText = L10n.brandDisplay(item.brand)
        let isGenericBrand = item.brand.isEmpty || item.brand == "品牌未注明" || item.brand == "无品牌" || item.brand == "仿刀"
        let titleLine: String
        if isGenericBrand || item.model.lowercased().hasPrefix(brandText.lowercased()) {
            titleLine = item.model
        } else {
            titleLine = "\(brandText) \(item.model)"
        }
        if let hb = hybridHandle {
            lines.append("\(titleLine)（\(L10n.handleTag(hb))）")
        } else {
            lines.append(titleLine)
        }

        var specParts: [String] = []
        if let ks = brushKnotSize { specParts.append(ks) }
        if item.category.supportsSample && item.isSample { specParts.append(L10n.t("小样", "Sample")) }
        specParts.append(contentsOf: GearSpecFormatter.specTags(for: item))
        if !specParts.isEmpty {
            lines.append(specParts.joined(separator: " · "))
        }

        var metaParts: [String] = [item.status.displayName]
        if item.isPending {
            metaParts.append(L10n.t("待确认", "Pending"))
        }
        metaParts.append(L10n.t("使用 \(item.count) 次", "\(item.count) uses"))
        if !item.lastUsedDate.isEmpty {
            metaParts.append(L10n.t("最近 \(item.lastUsedDate)", "Last \(item.lastUsedDate)"))
        }
        lines.append(metaParts.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let pills = bottomPills
        let contentOpacity = ShaveTheme.gearCardContentOpacity(status: item.status)

        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                VStack(alignment: .leading, spacing: 0) {
                    // 顶部：左原形 Logo（38pt 高）+ 右使用次数角标与状态小圆点
                    HStack(alignment: .top, spacing: 6) {
                        BrandAvatarView(
                            brand: item.brand,
                            size: 38,
                            maxWidth: 68,
                            category: item.category,
                            alignment: .leading
                        )

                        Spacer(minLength: 4)

                        HStack(alignment: .center, spacing: 5) {
                            if item.isPending {
                                Circle()
                                    .fill(ShaveTheme.amber)
                                    .frame(width: 7, height: 7)
                                    .help(L10n.t("待确认", "Pending"))
                            }

                            Circle()
                                .fill(ShaveTheme.statusColor(for: item.status))
                                .frame(width: 7, height: 7)
                                .help(item.status.displayName)

                            Text(L10n.t("\(item.count)次", "\(item.count)"))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 2.5)
                                .background(
                                    Capsule()
                                        .fill(ShaveTheme.subtleSurface(scheme))
                                )
                        }
                    }

                    Spacer(minLength: 8)

                    // 中部：品牌小字 + 醒目型号主标题（最多 2 行截断）
                    VStack(alignment: .leading, spacing: 3) {
                        Text(brandSubtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(item.model)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 6)

                    // 底部：精简核心属性胶囊（单行自动收敛不溢出）；无属性时展示克制的最近使用日期
                    if !pills.isEmpty {
                        SingleLineFittingTagRow(spacing: 4) {
                            ForEach(pills) { pill in
                                CompactSpecCapsule(text: pill.text, tint: pill.tint)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(
                            item.lastUsedDate.isEmpty
                                ? L10n.t("尚未使用", "Unused")
                                : L10n.t("最近 \(item.lastUsedDate)", "Last \(item.lastUsedDate)")
                        )
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    }
                }
                .opacity(contentOpacity)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ShaveTheme.gearCardBackground(status: item.status, scheme: scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        ShaveTheme.gearCardBorder(status: item.status, isPending: item.isPending, scheme: scheme),
                        lineWidth: (item.isPending || item.status == .borrowed) ? 1.25 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .help(fullHoverSummary)
    }
}

private struct CompactSpecCapsule: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: tint != nil ? .semibold : .medium, design: tint == ShaveTheme.accent ? .monospaced : .default))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6.5)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(
                        tint != nil
                            ? tint!.opacity(0.13)
                            : ShaveTheme.neutralPillBackground(scheme)
                    )
            )
            .foregroundStyle(
                tint ?? Color.primary.opacity(0.76)
            )
    }
}

/// 单行自适应收敛胶囊布局：只摆放当前宽度内容得下的胶囊，放不下的自动隐藏，绝不换行撑破 1:1 正方形或半截裁切
private struct SingleLineFittingTagRow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var usedWidth: CGFloat = 0
        var maxHeight: CGFloat = 0
        var placedCount = 0

        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let needed = placedCount == 0 ? min(natural.width, maxWidth) : (usedWidth + spacing + natural.width)
            if placedCount > 0 && needed > maxWidth {
                break
            }
            usedWidth = needed
            maxHeight = max(maxHeight, natural.height)
            placedCount += 1
        }
        return CGSize(width: min(maxWidth, usedWidth), height: maxHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var placedCount = 0

        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            if placedCount == 0 {
                let width = min(natural.width, bounds.width)
                let y = bounds.midY - natural.height / 2
                subview.place(
                    at: CGPoint(x: currentX, y: y),
                    proposal: ProposedViewSize(width: width, height: natural.height)
                )
                currentX += width + spacing
                placedCount += 1
            } else if currentX + natural.width <= bounds.maxX + 0.5 {
                let y = bounds.midY - natural.height / 2
                subview.place(
                    at: CGPoint(x: currentX, y: y),
                    proposal: ProposedViewSize(width: natural.width, height: natural.height)
                )
                currentX += natural.width + spacing
                placedCount += 1
            } else {
                // 超出单行空间的尾标移出可见区域并置零尺寸，防止溢出或半截截断
                subview.place(
                    at: CGPoint(x: bounds.maxX + 1000, y: bounds.minY),
                    proposal: ProposedViewSize(width: 0, height: 0)
                )
            }
        }
    }
}
