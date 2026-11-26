import SwiftUI

/// Apple 原生极简视觉系统：克制留白、黑白灰基底 + 单一强调色 + 低饱和状态微底色卡片
enum ShaveTheme {
    // 单一克制强调色（Apple 钛蓝灰）
    static let accent = Color(red: 0.16, green: 0.45, blue: 0.80)
    static let accentSoft = Color(red: 0.16, green: 0.45, blue: 0.80).opacity(0.11)

    // 关键状态语义色（仅用于关键状态反馈与图表区分）
    static let forest = Color(red: 0.18, green: 0.56, blue: 0.36)      // 无痛 / BBS / 在用 / 有
    static let amber = Color(red: 0.82, green: 0.52, blue: 0.12)       // 微痛 / 待确认
    static let crimson = Color(red: 0.80, green: 0.24, blue: 0.24)     // 刺痛 / 错误
    static let slate = Color(red: 0.32, green: 0.50, blue: 0.72)       // 借用雾蓝

    // Apple 原生动态黑白灰背景
    static func canvasBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.095, green: 0.098, blue: 0.106)
            : Color(red: 0.962, green: 0.965, blue: 0.972)
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.145, green: 0.149, blue: 0.160)
            : Color.white
    }

    static func subtleSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.065)
            : Color.black.opacity(0.038)
    }

    static func neutralPillBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.05)
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.095)
            : Color.black.opacity(0.075)
    }

    // 器材状态分色卡片（深浅色自适应、极低饱和不刺眼）
    static func gearCardBackground(status: GearStatus, scheme: ColorScheme) -> Color {
        switch status {
        case .active, .inStock:
            return cardBackground(scheme)
        case .borrowed:
            return scheme == .dark
                ? Color(red: 0.135, green: 0.165, blue: 0.215)
                : Color(red: 0.945, green: 0.968, blue: 0.996)
        case .sold, .outOfStock:
            return scheme == .dark
                ? Color(red: 0.122, green: 0.125, blue: 0.134)
                : Color(red: 0.944, green: 0.947, blue: 0.954)
        }
    }

    static func gearCardBorder(status: GearStatus, isPending: Bool, scheme: ColorScheme) -> Color {
        if isPending {
            return amber.opacity(scheme == .dark ? 0.62 : 0.56)
        }
        switch status {
        case .borrowed:
            return slate.opacity(scheme == .dark ? 0.42 : 0.34)
        case .sold, .outOfStock:
            return scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.065)
        case .active, .inStock:
            return cardBorder(scheme)
        }
    }

    static func gearCardContentOpacity(status: GearStatus) -> Double {
        switch status {
        case .sold, .outOfStock: return 0.72
        default: return 1.0
        }
    }

    // 品牌徽章低饱和稳定色彩
    static func brandColor(for brand: String) -> Color {
        if brand == "仿刀" { return Color(red: 0.48, green: 0.48, blue: 0.52) }
        if brand == "品牌未注明" || brand == "无品牌" { return Color.secondary }
        let palette: [Color] = [
            Color(red: 0.24, green: 0.45, blue: 0.70),
            Color(red: 0.24, green: 0.52, blue: 0.46),
            Color(red: 0.44, green: 0.42, blue: 0.64),
            Color(red: 0.60, green: 0.42, blue: 0.28),
            Color(red: 0.54, green: 0.38, blue: 0.48),
            Color(red: 0.34, green: 0.50, blue: 0.56),
            Color(red: 0.54, green: 0.48, blue: 0.26),
            Color(red: 0.58, green: 0.36, blue: 0.36)
        ]
        var hash = 5381
        for scalar in brand.lowercased().unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ Int(scalar.value)
        }
        return palette[abs(hash) % palette.count]
    }

    static func statusColor(for status: GearStatus) -> Color {
        switch status {
        case .active, .inStock: return forest
        case .borrowed: return slate
        case .sold, .outOfStock: return .secondary
        }
    }

    static func irritationColor(_ level: IrritationLevel?) -> Color {
        switch level {
        case .painless: return forest
        case .mild: return amber
        case .stinging: return crimson
        case nil: return .secondary
        }
    }
}

/// 语义或中性属性胶囊
struct TagPill: View {
    @Environment(\.colorScheme) private var scheme

    let text: String
    var color: Color = .secondary
    var filled: Bool = false
    var neutral: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8.5)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(
                        neutral
                            ? ShaveTheme.neutralPillBackground(scheme)
                            : (filled ? color : color.opacity(0.13))
                    )
            )
            .foregroundStyle(
                neutral
                    ? Color.primary.opacity(0.78)
                    : (filled ? Color.white : color)
            )
    }
}

/// 全宽圆角卡片容器（加宽内边距，提供 Apple 原生呼吸感）
struct SectionCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(ShaveTheme.cardBackground(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 1)
            )
    }
}

/// 原生自动换行流式布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, currentX - spacing)
        }
        return CGSize(width: min(maxWidth, totalWidth), height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
