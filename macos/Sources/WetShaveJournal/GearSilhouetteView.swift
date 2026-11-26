import SwiftUI

/// 器材品类/子类扁平矢量水印剪影（纯 SwiftUI Path，自适应浅色/深色模式）
struct GearSilhouetteView: View {
    @Environment(\.colorScheme) private var scheme

    let category: GearCategory
    var razorType: RazorType? = nil
    var bladeType: BladeType? = nil
    var size: CGFloat = 68

    var body: some View {
        GearSilhouetteShape(
            category: category,
            razorType: razorType,
            bladeType: bladeType
        )
        .fill(
            scheme == .dark ? Color.white.opacity(0.075) : Color.primary.opacity(0.055),
            style: FillStyle(eoFill: true)
        )
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GearSilhouetteShape: Shape {
    let category: GearCategory
    let razorType: RazorType?
    let bladeType: BladeType?

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 100.0
        let sy = rect.height / 100.0
        let scale = min(sx, sy)
        let ox = rect.minX + (rect.width - 100.0 * scale) * 0.5
        let oy = rect.minY + (rect.height - 100.0 * scale) * 0.5

        let raw: Path
        switch category {
        case .blade:
            raw = bladePath(type: bladeType)
        case .razor:
            raw = razorPath(type: razorType)
        case .brush:
            raw = brushPath()
        case .soap:
            raw = soapPath()
        case .preShave:
            raw = preShavePath()
        case .afterShave:
            raw = afterShavePath()
        case .bowl:
            raw = bowlPath()
        }

        let transform = CGAffineTransform(translationX: ox, y: oy)
            .scaledBy(x: scale, y: scale)
        return raw.applying(transform)
    }

    // MARK: - 刀片子类（DE / AC / GEM / Injector / 盒刀头 / 其他）

    private func bladePath(type: BladeType?) -> Path {
        switch type {
        case .ac:
            return acBladePath()
        case .gem:
            return gemBladePath()
        case .injector:
            return injectorBladePath()
        case .cartridge:
            return cartridgeBladePath()
        case .other:
            return genericSingleEdgeBladePath()
        case .de, .none:
            return deBladePath()
        }
    }

    /// DE 双面刀片：经典四角缺口 + 中央镂空槽（even-odd 挖空）
    private func deBladePath() -> Path {
        var p = Path()
        // 外轮廓（带四角内切与左右端凹口）
        p.move(to: CGPoint(x: 16, y: 27))
        p.addLine(to: CGPoint(x: 84, y: 27))
        p.addLine(to: CGPoint(x: 84, y: 34))
        p.addLine(to: CGPoint(x: 91, y: 34))
        p.addLine(to: CGPoint(x: 91, y: 44))
        p.addLine(to: CGPoint(x: 87, y: 44))
        p.addLine(to: CGPoint(x: 87, y: 56))
        p.addLine(to: CGPoint(x: 91, y: 56))
        p.addLine(to: CGPoint(x: 91, y: 66))
        p.addLine(to: CGPoint(x: 84, y: 66))
        p.addLine(to: CGPoint(x: 84, y: 73))
        p.addLine(to: CGPoint(x: 16, y: 73))
        p.addLine(to: CGPoint(x: 16, y: 66))
        p.addLine(to: CGPoint(x: 9, y: 66))
        p.addLine(to: CGPoint(x: 9, y: 56))
        p.addLine(to: CGPoint(x: 13, y: 56))
        p.addLine(to: CGPoint(x: 13, y: 44))
        p.addLine(to: CGPoint(x: 9, y: 44))
        p.addLine(to: CGPoint(x: 9, y: 34))
        p.addLine(to: CGPoint(x: 16, y: 34))
        p.closeSubpath()

        // 中央镂空主槽（横向连槽 + 左右定位圆 + 中央菱形柱孔）
        p.addRoundedRect(in: CGRect(x: 24, y: 47, width: 52, height: 6), cornerSize: CGSize(width: 3, height: 3))
        p.addEllipse(in: CGRect(x: 26, y: 43, width: 14, height: 14))
        p.addEllipse(in: CGRect(x: 60, y: 43, width: 14, height: 14))
        p.addRoundedRect(in: CGRect(x: 45, y: 41, width: 10, height: 18), cornerSize: CGSize(width: 3, height: 3))
        return p
    }

    /// AC 艺术家单刃刀片：细长修身 + 三个定位孔
    private func acBladePath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 10, y: 39))
        p.addQuadCurve(to: CGPoint(x: 16, y: 36), control: CGPoint(x: 10, y: 36))
        p.addLine(to: CGPoint(x: 84, y: 36))
        p.addQuadCurve(to: CGPoint(x: 90, y: 39), control: CGPoint(x: 90, y: 36))
        p.addLine(to: CGPoint(x: 92, y: 63))
        p.addLine(to: CGPoint(x: 8, y: 63))
        p.closeSubpath()

        // 三个定位孔/槽
        p.addRoundedRect(in: CGRect(x: 21, y: 45, width: 10, height: 6), cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: CGRect(x: 43, y: 45, width: 14, height: 6), cornerSize: CGSize(width: 3, height: 3))
        p.addRoundedRect(in: CGRect(x: 69, y: 45, width: 10, height: 6), cornerSize: CGSize(width: 3, height: 3))
        return p
    }

    /// GEM 单刃刀片：顶部厚背脊包边 + 梯形侧肩缺口
    private func gemBladePath() -> Path {
        var p = Path()
        // 厚背脊包边
        p.addRoundedRect(in: CGRect(x: 11, y: 27, width: 78, height: 13), cornerSize: CGSize(width: 3, height: 3))
        // 刀身主体（带两侧定位缺口与底部刃口）
        p.move(to: CGPoint(x: 15, y: 42))
        p.addLine(to: CGPoint(x: 85, y: 42))
        p.addLine(to: CGPoint(x: 85, y: 50))
        p.addLine(to: CGPoint(x: 80, y: 50))
        p.addLine(to: CGPoint(x: 80, y: 57))
        p.addLine(to: CGPoint(x: 87, y: 57))
        p.addLine(to: CGPoint(x: 89, y: 73))
        p.addLine(to: CGPoint(x: 11, y: 73))
        p.addLine(to: CGPoint(x: 13, y: 57))
        p.addLine(to: CGPoint(x: 20, y: 57))
        p.addLine(to: CGPoint(x: 20, y: 50))
        p.addLine(to: CGPoint(x: 15, y: 50))
        p.closeSubpath()

        // 中央小定位孔
        p.addEllipse(in: CGRect(x: 46, y: 50, width: 8, height: 8))
        return p
    }

    /// Injector 注射式单刃刀片：窄长条 + 纵向狭长定位槽
    private func injectorBladePath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 10, y: 41))
        p.addLine(to: CGPoint(x: 90, y: 41))
        p.addLine(to: CGPoint(x: 92, y: 47))
        p.addLine(to: CGPoint(x: 88, y: 47))
        p.addLine(to: CGPoint(x: 88, y: 53))
        p.addLine(to: CGPoint(x: 92, y: 53))
        p.addLine(to: CGPoint(x: 90, y: 60))
        p.addLine(to: CGPoint(x: 10, y: 60))
        p.addLine(to: CGPoint(x: 8, y: 53))
        p.addLine(to: CGPoint(x: 12, y: 53))
        p.addLine(to: CGPoint(x: 12, y: 47))
        p.addLine(to: CGPoint(x: 8, y: 47))
        p.closeSubpath()

        p.addRoundedRect(in: CGRect(x: 26, y: 48, width: 48, height: 4.5), cornerSize: CGSize(width: 2.25, height: 2.25))
        return p
    }

    /// 盒刀头：多刃平行刀缝 + 底部卡扣接口
    private func cartridgeBladePath() -> Path {
        var p = Path()
        p.addRoundedRect(in: CGRect(x: 13, y: 26, width: 74, height: 39), cornerSize: CGSize(width: 8, height: 8))
        // 三道刀片镂空缝
        p.addRoundedRect(in: CGRect(x: 21, y: 34, width: 58, height: 4.5), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 21, y: 43, width: 58, height: 4.5), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: 21, y: 52, width: 58, height: 4.5), cornerSize: CGSize(width: 2, height: 2))
        // 底部连接卡扣
        p.addRoundedRect(in: CGRect(x: 41, y: 67, width: 18, height: 10), cornerSize: CGSize(width: 3, height: 3))
        return p
    }

    /// 其他单刃刀片
    private func genericSingleEdgeBladePath() -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 16, y: 34))
        p.addLine(to: CGPoint(x: 84, y: 34))
        p.addLine(to: CGPoint(x: 90, y: 66))
        p.addLine(to: CGPoint(x: 10, y: 66))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 45, y: 45, width: 10, height: 10))
        return p
    }

    // MARK: - 剃须刀子类（安全刀 T 形 / 直剃与替刃 / 盒刀）

    private func razorPath(type: RazorType?) -> Path {
        switch type {
        case .straight, .shavette:
            return straightRazorPath()
        case .cartridge:
            return cartridgeRazorPath()
        default:
            return safetyRazorPath()
        }
    }

    /// 经典 T 字形安全剃须刀
    private func safetyRazorPath() -> Path {
        var p = Path()
        // 顶盖弧形刀头
        p.move(to: CGPoint(x: 17, y: 20))
        p.addQuadCurve(to: CGPoint(x: 83, y: 20), control: CGPoint(x: 50, y: 9))
        p.addLine(to: CGPoint(x: 85, y: 26))
        p.addQuadCurve(to: CGPoint(x: 80, y: 31), control: CGPoint(x: 85, y: 31))
        p.addLine(to: CGPoint(x: 20, y: 31))
        p.addQuadCurve(to: CGPoint(x: 15, y: 26), control: CGPoint(x: 15, y: 31))
        p.closeSubpath()

        // 刀头颈部过渡
        p.addRoundedRect(in: CGRect(x: 41, y: 33, width: 18, height: 6), cornerSize: CGSize(width: 2.5, height: 2.5))

        // 手柄主体（微收腰 + 底部配重尾帽）
        p.move(to: CGPoint(x: 44, y: 41))
        p.addLine(to: CGPoint(x: 56, y: 41))
        p.addLine(to: CGPoint(x: 57.5, y: 82))
        p.addQuadCurve(to: CGPoint(x: 59, y: 88), control: CGPoint(x: 59.5, y: 85))
        p.addQuadCurve(to: CGPoint(x: 50, y: 93), control: CGPoint(x: 58, y: 93))
        p.addQuadCurve(to: CGPoint(x: 41, y: 88), control: CGPoint(x: 42, y: 93))
        p.addQuadCurve(to: CGPoint(x: 42.5, y: 82), control: CGPoint(x: 40.5, y: 85))
        p.closeSubpath()
        return p
    }

    /// 折叠直剃 / 替刃（展开呈 V 角度：上方刀身 + 下方刀柄）
    private func straightRazorPath() -> Path {
        var p = Path()
        // 上方刀身（含尾柄唐勾与厚背刀刃）
        p.move(to: CGPoint(x: 10, y: 40))
        p.addQuadCurve(to: CGPoint(x: 22, y: 45), control: CGPoint(x: 14, y: 48))
        p.addLine(to: CGPoint(x: 34, y: 39))
        p.addLine(to: CGPoint(x: 84, y: 17))
        p.addQuadCurve(to: CGPoint(x: 90, y: 24), control: CGPoint(x: 90, y: 18))
        p.addLine(to: CGPoint(x: 91, y: 31))
        p.addLine(to: CGPoint(x: 39, y: 50))
        p.addQuadCurve(to: CGPoint(x: 24, y: 51), control: CGPoint(x: 31, y: 53))
        p.addLine(to: CGPoint(x: 12, y: 45))
        p.closeSubpath()

        // 下方护柄（向右下展开，带枢轴圆孔）
        p.move(to: CGPoint(x: 24, y: 55))
        p.addQuadCurve(to: CGPoint(x: 33, y: 53), control: CGPoint(x: 27, y: 51))
        p.addLine(to: CGPoint(x: 86, y: 74))
        p.addQuadCurve(to: CGPoint(x: 82, y: 87), control: CGPoint(x: 92, y: 81))
        p.addLine(to: CGPoint(x: 25, y: 63))
        p.addQuadCurve(to: CGPoint(x: 24, y: 55), control: CGPoint(x: 20, y: 59))
        p.closeSubpath()

        // 枢轴定位铆钉孔
        p.addEllipse(in: CGRect(x: 26, y: 55.5, width: 4.5, height: 4.5))
        return p
    }

    /// 现代盒刀（倾角宽刀头 + 曲线人体工学手柄）
    private func cartridgeRazorPath() -> Path {
        var p = Path()
        // 宽多刃刀头
        p.addRoundedRect(in: CGRect(x: 22, y: 14, width: 56, height: 20), cornerSize: CGSize(width: 5, height: 5))
        // 刀头内两道刃缝
        p.addRoundedRect(in: CGRect(x: 28, y: 20, width: 44, height: 3), cornerSize: CGSize(width: 1.5, height: 1.5))
        p.addRoundedRect(in: CGRect(x: 28, y: 26, width: 44, height: 3), cornerSize: CGSize(width: 1.5, height: 1.5))

        // 摆动连接叉 + 曲线手柄
        p.move(to: CGPoint(x: 42, y: 36))
        p.addLine(to: CGPoint(x: 58, y: 36))
        p.addLine(to: CGPoint(x: 55, y: 48))
        p.addCurve(to: CGPoint(x: 58, y: 82), control1: CGPoint(x: 59, y: 60), control2: CGPoint(x: 60, y: 72))
        p.addQuadCurve(to: CGPoint(x: 50, y: 92), control: CGPoint(x: 56, y: 92))
        p.addQuadCurve(to: CGPoint(x: 42, y: 82), control: CGPoint(x: 44, y: 92))
        p.addCurve(to: CGPoint(x: 45, y: 48), control1: CGPoint(x: 40, y: 72), control2: CGPoint(x: 41, y: 60))
        p.closeSubpath()
        return p
    }

    // MARK: - 剃须刷 / 剃须皂 / 须前 / 须后 / 剃须碗

    /// 剃须刷：饱满圆拱刷毛 + 束腰手柄底座
    private func brushPath() -> Path {
        var p = Path()
        // 蓬松圆拱毛结
        p.move(to: CGPoint(x: 31, y: 50))
        p.addCurve(
            to: CGPoint(x: 50, y: 11),
            control1: CGPoint(x: 16, y: 35),
            control2: CGPoint(x: 26, y: 11)
        )
        p.addCurve(
            to: CGPoint(x: 69, y: 50),
            control1: CGPoint(x: 74, y: 11),
            control2: CGPoint(x: 84, y: 35)
        )
        p.closeSubpath()

        // 束腰经典手柄
        p.move(to: CGPoint(x: 33, y: 54))
        p.addLine(to: CGPoint(x: 67, y: 54))
        p.addCurve(
            to: CGPoint(x: 68, y: 88),
            control1: CGPoint(x: 59, y: 66),
            control2: CGPoint(x: 72, y: 76)
        )
        p.addQuadCurve(to: CGPoint(x: 64, y: 91), control: CGPoint(x: 68, y: 91))
        p.addLine(to: CGPoint(x: 36, y: 91))
        p.addQuadCurve(to: CGPoint(x: 32, y: 88), control: CGPoint(x: 32, y: 91))
        p.addCurve(
            to: CGPoint(x: 33, y: 54),
            control1: CGPoint(x: 28, y: 76),
            control2: CGPoint(x: 41, y: 66)
        )
        p.closeSubpath()
        return p
    }

    /// 剃须皂：矮胖圆形皂罐 + 顶部柔和泡沫圆晕
    private func soapPath() -> Path {
        var p = Path()
        // 顶部轻盈泡沫气泡剪影
        p.addEllipse(in: CGRect(x: 34, y: 17, width: 22, height: 15))
        p.addEllipse(in: CGRect(x: 50, y: 21, width: 16, height: 12))
        p.addEllipse(in: CGRect(x: 26, y: 23, width: 14, height: 10))
        // 皂罐盖沿
        p.addRoundedRect(in: CGRect(x: 13, y: 36, width: 74, height: 11), cornerSize: CGSize(width: 5, height: 5))
        // 皂罐主体
        p.addRoundedRect(in: CGRect(x: 16, y: 50, width: 68, height: 34), cornerSize: CGSize(width: 9, height: 9))
        // 罐身微标牌镂空
        p.addRoundedRect(in: CGRect(x: 33, y: 61, width: 34, height: 12), cornerSize: CGSize(width: 4, height: 4))
        return p
    }

    /// 须前：药剂滴管精油瓶
    private func preShavePath() -> Path {
        var p = Path()
        // 滴管胶头
        p.addRoundedRect(in: CGRect(x: 44, y: 11, width: 12, height: 16), cornerSize: CGSize(width: 6, height: 6))
        // 瓶盖螺纹环
        p.addRoundedRect(in: CGRect(x: 38, y: 29, width: 24, height: 8), cornerSize: CGSize(width: 3, height: 3))
        // 圆肩瓶身
        p.move(to: CGPoint(x: 41, y: 39))
        p.addLine(to: CGPoint(x: 59, y: 39))
        p.addCurve(to: CGPoint(x: 72, y: 56), control1: CGPoint(x: 68, y: 42), control2: CGPoint(x: 72, y: 48))
        p.addLine(to: CGPoint(x: 72, y: 84))
        p.addQuadCurve(to: CGPoint(x: 65, y: 90), control: CGPoint(x: 72, y: 90))
        p.addLine(to: CGPoint(x: 35, y: 90))
        p.addQuadCurve(to: CGPoint(x: 28, y: 84), control: CGPoint(x: 28, y: 90))
        p.addLine(to: CGPoint(x: 28, y: 56))
        p.addCurve(to: CGPoint(x: 41, y: 39), control1: CGPoint(x: 28, y: 48), control2: CGPoint(x: 32, y: 42))
        p.closeSubpath()

        // 瓶身水滴镂空
        p.move(to: CGPoint(x: 50, y: 56))
        p.addCurve(to: CGPoint(x: 58, y: 70), control1: CGPoint(x: 55, y: 63), control2: CGPoint(x: 58, y: 66))
        p.addArc(center: CGPoint(x: 50, y: 70), radius: 8, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addCurve(to: CGPoint(x: 50, y: 56), control1: CGPoint(x: 42, y: 66), control2: CGPoint(x: 45, y: 63))
        p.closeSubpath()
        return p
    }

    /// 须后：经典方肩复古须后水瓶
    private func afterShavePath() -> Path {
        var p = Path()
        // 瓶塞盖帽
        p.addRoundedRect(in: CGRect(x: 39, y: 12, width: 22, height: 13), cornerSize: CGSize(width: 4, height: 4))
        // 细颈
        p.addRect(CGRect(x: 43, y: 27, width: 14, height: 9))
        // 方肩酒壶形瓶身
        p.addRoundedRect(in: CGRect(x: 23, y: 37, width: 54, height: 53), cornerSize: CGSize(width: 10, height: 10))
        // 正面复古标签镂空框
        p.addRoundedRect(in: CGRect(x: 34, y: 52, width: 32, height: 22), cornerSize: CGSize(width: 4, height: 4))
        return p
    }

    /// 剃须碗：宽口弧形起泡碗 + 侧耳小握把 + 碗足
    private func bowlPath() -> Path {
        var p = Path()
        // 碗口沿
        p.addRoundedRect(in: CGRect(x: 11, y: 36, width: 68, height: 7), cornerSize: CGSize(width: 3.5, height: 3.5))
        // 深弧形碗身
        p.move(to: CGPoint(x: 15, y: 45))
        p.addLine(to: CGPoint(x: 75, y: 45))
        p.addCurve(to: CGPoint(x: 61, y: 76), control1: CGPoint(x: 74, y: 62), control2: CGPoint(x: 68, y: 72))
        p.addLine(to: CGPoint(x: 29, y: 76))
        p.addCurve(to: CGPoint(x: 15, y: 45), control1: CGPoint(x: 22, y: 72), control2: CGPoint(x: 16, y: 62))
        p.closeSubpath()
        // 碗底圈足
        p.addRoundedRect(in: CGRect(x: 31, y: 78, width: 28, height: 6), cornerSize: CGSize(width: 3, height: 3))
        // 右侧小指环握耳（环形镂空）
        p.addEllipse(in: CGRect(x: 73, y: 47, width: 17, height: 19))
        p.addEllipse(in: CGRect(x: 77.5, y: 51.5, width: 8, height: 10))
        return p
    }
}
