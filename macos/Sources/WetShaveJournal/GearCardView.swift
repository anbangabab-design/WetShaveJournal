import SwiftUI

/// 极简分色状态器材卡片：
/// - 品牌 Logo 保持 28×28 精致尺寸
/// - 剃须刷主信息行醒目展示等宽刷节尺寸徽章（26mm/28mm/32mm）及毛柄均衡的「毛结 × 手柄」混搭标识
/// - 剃须皂/须后仅在小样时展示「小样 / Sample」标签，正装隐藏不占空间
/// - 底部属性胶囊统一经 GearSpecFormatter 过滤，绝不出现超长参数胶囊
struct GearCardView: View {
    @Environment(\.colorScheme) private var scheme
    let item: GearItem

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

    var body: some View {
        let tags = GearSpecFormatter.specTags(for: item)
        let contentOpacity = ShaveTheme.gearCardContentOpacity(status: item.status)

        VStack(alignment: .leading, spacing: 12) {
            // 第一行：品牌（28px 徽章 + 混搭刷均衡展示「毛结品牌 × 手柄品牌」）+ 状态 + 次数
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 8) {
                    BrandAvatarView(brand: item.brand, size: 28, category: item.category)
                    Text(L10n.brandDisplay(item.brand))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(hybridHandle != nil ? .primary : .secondary)
                        .lineLimit(1)

                    if let hb = hybridHandle {
                        Text("×")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 4) {
                            Image(systemName: "paintbrush.pointed")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                            Text(L10n.handleTag(hb))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.85))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(ShaveTheme.neutralPillBackground(scheme))
                        )
                    }
                }

                if !item.status.isDefaultNormal {
                    TagPill(text: item.status.displayName, color: ShaveTheme.statusColor(for: item.status))
                }

                if item.isPending {
                    TagPill(text: L10n.t("待确认", "Pending"), color: ShaveTheme.amber, filled: true)
                }

                Spacer(minLength: 4)

                Text(L10n.t("\(item.count) 次", "\(item.count)"))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            // 第二行：型号主标题 + 剃须刷醒目等宽结径徽章（+ 皂/须后小样标签）
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.model)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let ks = brushKnotSize {
                    Text(ks)
                        .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8.5)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(ShaveTheme.accentSoft)
                        )
                        .overlay(
                            Capsule()
                                .stroke(ShaveTheme.accent.opacity(0.32), lineWidth: 1)
                        )
                        .foregroundStyle(ShaveTheme.accent)
                        .fixedSize()
                }

                if item.category.supportsSample && item.isSample {
                    TagPill(text: L10n.t("小样", "Sample"), color: ShaveTheme.slate)
                        .fixedSize()
                }

                Spacer(minLength: 0)
            }

            // 第三行：中性浅灰极简短属性胶囊
            if !tags.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                        TagPill(text: tag, neutral: true)
                    }
                }
            }

            Spacer(minLength: 2)

            // 第四行：克制的最近使用日期
            if !item.lastUsedDate.isEmpty {
                Text(L10n.t("最近 \(item.lastUsedDate)", "Last \(item.lastUsedDate)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                Text(L10n.t("尚未使用", "Unused"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(contentOpacity)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(ShaveTheme.gearCardBackground(status: item.status, scheme: scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(
                    ShaveTheme.gearCardBorder(status: item.status, isPending: item.isPending, scheme: scheme),
                    lineWidth: (item.isPending || item.status == .borrowed) ? 1.25 : 1
                )
        )
        .contentShape(Rectangle())
    }
}
