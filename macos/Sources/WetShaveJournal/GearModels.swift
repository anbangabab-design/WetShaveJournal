import Foundation

// MARK: - 器材分类与属性枚举（持久化键 rawValue 与界面显示文案 displayName 完全解耦）

enum GearCategory: String, Codable, CaseIterable, Identifiable {
    case razor = "剃须刀"
    case blade = "刀片"
    case brush = "剃须刷"
    case soap = "剃须皂"
    case preShave = "须前"
    case afterShave = "须后"
    case bowl = "剃须碗"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .razor: return L10n.t("剃须刀", "Razors")
        case .blade: return L10n.t("刀片", "Blades")
        case .brush: return L10n.t("剃须刷", "Brushes")
        case .soap: return L10n.t("剃须皂", "Soaps")
        case .preShave: return L10n.t("须前", "Pre-Shave")
        case .afterShave: return L10n.t("须后", "Aftershave")
        case .bowl: return L10n.t("剃须碗", "Bowls")
        }
    }

    var singularName: String {
        switch self {
        case .razor: return L10n.t("剃须刀", "Razor")
        case .blade: return L10n.t("刀片", "Blade")
        case .brush: return L10n.t("剃须刷", "Brush")
        case .soap: return L10n.t("剃须皂", "Soap")
        case .preShave: return L10n.t("须前", "Pre-Shave")
        case .afterShave: return L10n.t("须后", "Aftershave")
        case .bowl: return L10n.t("剃须碗", "Bowl")
        }
    }

    var supportsSample: Bool {
        self == .soap || self == .afterShave
    }

    var icon: String {
        switch self {
        case .razor: return "scissors"
        case .blade: return "rectangle.split.2x1"
        case .brush: return "paintbrush.pointed.fill"
        case .soap: return "bubbles.and.sparkles.fill"
        case .preShave: return "drop.fill"
        case .afterShave: return "sparkles"
        case .bowl: return "cup.and.saucer.fill"
        }
    }
}

enum BladeType: String, Codable, CaseIterable, Identifiable {
    case de = "DE"
    case ac = "AC"
    case gem = "GEM"
    case injector = "Injector"
    case cartridge = "盒刀头"
    case other = "其他"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .de: return "DE"
        case .ac: return "AC"
        case .gem: return "GEM"
        case .injector: return "Injector"
        case .cartridge: return L10n.t("盒刀头", "Cartridge")
        case .other: return L10n.t("其他", "Other")
        }
    }
}

enum RazorType: String, Codable, CaseIterable, Identifiable {
    case de = "Double Edge (DE)"
    case seAC = "Single Edge (AC)"
    case seGEM = "Single Edge (GEM)"
    case seInjector = "Single Edge (Injector)"
    case seHalfDE = "Single Edge (半DE)"
    case cartridge = "盒刀"
    case twinBlade = "Twin Blade"
    case straight = "直剃"
    case shavette = "替刃"
    case other = "其他"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .de: return "Double Edge (DE)"
        case .seAC: return "Single Edge (AC)"
        case .seGEM: return "Single Edge (GEM)"
        case .seInjector: return "Single Edge (Injector)"
        case .seHalfDE: return L10n.t("Single Edge (半DE)", "Single Edge (Half DE)")
        case .cartridge: return L10n.t("盒刀", "Cartridge")
        case .twinBlade: return "Twin Blade"
        case .straight: return L10n.t("直剃", "Straight Razor")
        case .shavette: return L10n.t("替刃", "Shavette")
        case .other: return L10n.t("其他", "Other")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "剃刃":
            self = .shavette
        case "Single Edge (其他)":
            self = .other
        default:
            self = RazorType(rawValue: raw) ?? .other
        }
    }

    var shortLabel: String {
        switch self {
        case .de: return "DE"
        case .seAC: return "SE · AC"
        case .seGEM: return "SE · GEM"
        case .seInjector: return "SE · Injector"
        case .seHalfDE: return L10n.t("SE · 半DE", "SE · Half DE")
        case .cartridge: return L10n.t("盒刀", "Cartridge")
        case .twinBlade: return "Twin Blade"
        case .straight: return L10n.t("直剃", "Straight")
        case .shavette: return L10n.t("替刃", "Shavette")
        case .other: return L10n.t("其他", "Other")
        }
    }

    var groupLabel: String {
        switch self {
        case .de: return "Double Edge"
        case .seAC, .seGEM, .seInjector, .seHalfDE: return "Single Edge"
        case .cartridge: return L10n.t("盒刀", "Cartridge")
        case .twinBlade: return "Twin Blade"
        case .straight: return L10n.t("直剃", "Straight")
        case .shavette: return L10n.t("替刃", "Shavette")
        case .other: return L10n.t("其他", "Other")
        }
    }

    var matchingBladeType: BladeType? {
        switch self {
        case .de, .seHalfDE, .twinBlade: return .de
        case .seAC, .shavette: return .ac
        case .seGEM: return .gem
        case .seInjector: return .injector
        case .cartridge: return .cartridge
        case .straight, .other: return nil
        }
    }

    var requiresBlade: Bool {
        self != .straight
    }
}

enum PlateType: String, Codable, CaseIterable, Identifiable {
    case sb = "SB"
    case oc = "OC"
    case dc = "DC"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "SB", "Slant":
            self = .sb
        case "OC", "Slant OC":
            self = .oc
        case "DC":
            self = .dc
        default:
            self = .sb
        }
    }

    var displayName: String {
        switch self {
        case .sb: return L10n.t("SB 闭齿", "SB (Safety Bar)")
        case .oc: return L10n.t("OC 开齿", "OC (Open Comb)")
        case .dc: return L10n.t("DC 双面", "DC (Dual Comb)")
        }
    }
}

enum BrushMaterial: String, Codable, CaseIterable, Identifiable {
    case badger = "獾毛"
    case synthetic = "人造丝"
    case boar = "猪鬃"
    case horse = "马毛"
    case wool = "羊毛"
    case mixed = "混毛"
    case other = "其他"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .badger: return L10n.t("獾毛", "Badger")
        case .synthetic: return L10n.t("人造丝", "Synthetic")
        case .boar: return L10n.t("猪鬃", "Boar")
        case .horse: return L10n.t("马毛", "Horse")
        case .wool: return L10n.t("羊毛", "Wool")
        case .mixed: return L10n.t("混毛", "Mixed")
        case .other: return L10n.t("其他", "Other")
        }
    }
}

enum BadgerTreatment: String, Codable, CaseIterable, Identifiable {
    case unbleached = "无漂"
    case gelTip = "漂尖"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unbleached: return L10n.t("无漂", "Unbleached")
        case .gelTip: return L10n.t("漂尖", "Gel Tip")
        }
    }
}

enum BadgerBand: String, Codable, CaseIterable, Identifiable {
    case twoBand = "二段"
    case threeBand = "三段"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoBand: return L10n.t("二段", "2-Band")
        case .threeBand: return L10n.t("三段", "3-Band")
        }
    }
}

enum BrushKnotShape: String, Codable, CaseIterable, Identifiable {
    case fan = "Fan"
    case bulb = "Bulb"
    case hybrid = "Hybrid"

    var id: String { rawValue }

    var displayName: String { rawValue }
}

enum GearStatus: String, Codable, CaseIterable, Identifiable {
    case active = "在用"
    case borrowed = "借用"
    case sold = "已出"
    case inStock = "有"
    case outOfStock = "无"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return L10n.t("在用", "Active")
        case .borrowed: return L10n.t("借用", "Borrowed")
        case .sold: return L10n.t("已出", "Sold")
        case .inStock: return L10n.t("有", "In Stock")
        case .outOfStock: return L10n.t("无", "Out of Stock")
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "在用", "闲置":
            self = .active
        case "借用":
            self = .borrowed
        case "已出", "空瓶":
            self = .sold
        case "有":
            self = .inStock
        case "无":
            self = .outOfStock
        default:
            self = .active
        }
    }

    static func options(for category: GearCategory) -> [GearStatus] {
        if category == .blade {
            return [.inStock, .outOfStock]
        }
        return [.active, .borrowed, .sold]
    }

    static func normalized(_ status: GearStatus?, for category: GearCategory) -> GearStatus {
        guard let st = status else {
            return category == .blade ? .inStock : .active
        }
        if category == .blade {
            switch st {
            case .inStock, .active, .borrowed: return .inStock
            case .outOfStock, .sold: return .outOfStock
            }
        } else {
            switch st {
            case .active, .inStock: return .active
            case .borrowed: return .borrowed
            case .sold, .outOfStock: return .sold
            }
        }
    }

    var searchPriority: Int {
        switch self {
        case .active, .inStock: return 0
        case .borrowed: return 1
        case .sold, .outOfStock: return 2
        }
    }

    var isDefaultNormal: Bool {
        self == .active || self == .inStock
    }
}

// MARK: - 器材持久化覆写与撤销快照

struct GearOverride: Codable, Hashable {
    var brand: String
    var name: String
    // 结构化字段（全部可选，100% 向后兼容旧版 JSON）
    var model: String?
    var razorType: RazorType?
    var isAdjustable: Bool?
    var isSlant: Bool?
    var material: String?
    var plateType: PlateType?
    var gapOrSpec: String?
    var bladeType: BladeType?
    var handleBrand: String?
    var brushMaterial: BrushMaterial?
    var badgerTreatment: BadgerTreatment?
    var badgerBand: BadgerBand?
    var knotSize: String?
    var knotShape: BrushKnotShape?
    /// 剃须皂 / 须后是否为小样（默认 nil / false）
    var isSample: Bool?
    var status: GearStatus?
    var notes: String?
    var recognizedSource: String?
    /// 用户是否在编辑弹窗中手动确认保存过（为 true 时禁止 AI 静默覆盖已有字段）
    var isManuallyConfirmed: Bool?
    /// 云盘双端同步最后修改时间（ISO8601 UTC 字符串，可选，100% 向后兼容旧版 JSON）
    var updatedAt: String?

    init(
        brand: String,
        name: String,
        model: String? = nil,
        razorType: RazorType? = nil,
        isAdjustable: Bool? = nil,
        isSlant: Bool? = nil,
        material: String? = nil,
        plateType: PlateType? = nil,
        gapOrSpec: String? = nil,
        bladeType: BladeType? = nil,
        handleBrand: String? = nil,
        brushMaterial: BrushMaterial? = nil,
        badgerTreatment: BadgerTreatment? = nil,
        badgerBand: BadgerBand? = nil,
        knotSize: String? = nil,
        knotShape: BrushKnotShape? = nil,
        isSample: Bool? = nil,
        status: GearStatus? = nil,
        notes: String? = nil,
        recognizedSource: String? = nil,
        isManuallyConfirmed: Bool? = nil,
        updatedAt: String? = nil
    ) {
        self.brand = brand
        self.name = name
        self.model = model
        self.razorType = razorType
        self.isAdjustable = isAdjustable
        self.isSlant = isSlant
        self.material = material
        self.plateType = plateType
        self.gapOrSpec = gapOrSpec
        self.bladeType = bladeType
        self.handleBrand = handleBrand
        self.brushMaterial = brushMaterial
        self.badgerTreatment = badgerTreatment
        self.badgerBand = badgerBand
        self.knotSize = knotSize
        self.knotShape = knotShape
        self.isSample = isSample
        self.status = status
        self.notes = notes
        self.recognizedSource = recognizedSource
        self.isManuallyConfirmed = isManuallyConfirmed
        self.updatedAt = updatedAt
    }

    /// 统一从聚合 GearItem 构造 GearOverride（消除合并、拆分、AI 体检多处手写 20 个字段拷贝的漂移风险）
    static func from(
        item: GearItem,
        isManuallyConfirmed: Bool? = nil,
        recognizedSource: String? = nil
    ) -> GearOverride {
        GearOverride(
            brand: item.brand,
            name: item.name,
            model: item.model.isEmpty ? nil : item.model,
            razorType: item.razorType,
            isAdjustable: item.isAdjustable ? true : nil,
            isSlant: item.isSlant ? true : nil,
            material: item.material,
            plateType: item.plateType,
            gapOrSpec: item.gapOrSpec,
            bladeType: item.bladeType,
            handleBrand: item.handleBrand,
            brushMaterial: item.brushMaterial,
            badgerTreatment: item.badgerTreatment,
            badgerBand: item.badgerBand,
            knotSize: item.knotSize,
            knotShape: item.knotShape,
            isSample: item.isSample ? true : nil,
            status: item.status,
            notes: item.notes,
            recognizedSource: recognizedSource ?? item.recognizedSource,
            isManuallyConfirmed: isManuallyConfirmed ?? (item.isManuallyConfirmed ? true : nil)
        )
    }

    enum CodingKeys: String, CodingKey {
        case brand, name, model, razorType, isAdjustable, isSlant, material, plateType, gapOrSpec
        case bladeType, handleBrand, knotBrand, brushMaterial, badgerTreatment, badgerBand, knotSize, knotShape
        case isSample, status, notes, recognizedSource, isManuallyConfirmed, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var decodedBrand = try c.decode(String.self, forKey: .brand)
        name = try c.decode(String.self, forKey: .name)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        razorType = try c.decodeIfPresent(RazorType.self, forKey: .razorType)
        isAdjustable = try c.decodeIfPresent(Bool.self, forKey: .isAdjustable)
        var decodedSlant = try c.decodeIfPresent(Bool.self, forKey: .isSlant)
        material = try c.decodeIfPresent(String.self, forKey: .material)

        if let rawPlate = try c.decodeIfPresent(String.self, forKey: .plateType) {
            switch rawPlate {
            case "Slant":
                plateType = .sb
                if decodedSlant == nil { decodedSlant = true }
            case "Slant OC":
                plateType = .oc
                if decodedSlant == nil { decodedSlant = true }
            default:
                plateType = PlateType(rawValue: rawPlate)
            }
        } else {
            plateType = nil
        }
        isSlant = decodedSlant

        gapOrSpec = try c.decodeIfPresent(String.self, forKey: .gapOrSpec)
        bladeType = try c.decodeIfPresent(BladeType.self, forKey: .bladeType)

        var decodedHandle = try c.decodeIfPresent(String.self, forKey: .handleBrand)
        if decodedHandle == nil,
           let legacyKnot = try c.decodeIfPresent(String.self, forKey: .knotBrand)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyKnot.isEmpty {
            if decodedBrand.lowercased() != legacyKnot.lowercased() {
                decodedHandle = decodedBrand
            }
            decodedBrand = legacyKnot
        }
        brand = decodedBrand
        if let hb = decodedHandle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hb.isEmpty,
           hb.lowercased() != decodedBrand.lowercased() {
            handleBrand = hb
        } else {
            handleBrand = nil
        }

        brushMaterial = try c.decodeIfPresent(BrushMaterial.self, forKey: .brushMaterial)
        badgerTreatment = try c.decodeIfPresent(BadgerTreatment.self, forKey: .badgerTreatment)
        badgerBand = try c.decodeIfPresent(BadgerBand.self, forKey: .badgerBand)
        knotSize = try c.decodeIfPresent(String.self, forKey: .knotSize)
        knotShape = try c.decodeIfPresent(BrushKnotShape.self, forKey: .knotShape)
        isSample = try c.decodeIfPresent(Bool.self, forKey: .isSample)
        status = try c.decodeIfPresent(GearStatus.self, forKey: .status)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        recognizedSource = try c.decodeIfPresent(String.self, forKey: .recognizedSource)
        isManuallyConfirmed = try c.decodeIfPresent(Bool.self, forKey: .isManuallyConfirmed)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(brand, forKey: .brand)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(razorType, forKey: .razorType)
        try c.encodeIfPresent(isAdjustable, forKey: .isAdjustable)
        try c.encodeIfPresent(isSlant, forKey: .isSlant)
        try c.encodeIfPresent(material, forKey: .material)
        try c.encodeIfPresent(plateType, forKey: .plateType)
        try c.encodeIfPresent(gapOrSpec, forKey: .gapOrSpec)
        try c.encodeIfPresent(bladeType, forKey: .bladeType)
        try c.encodeIfPresent(handleBrand, forKey: .handleBrand)
        try c.encodeIfPresent(brushMaterial, forKey: .brushMaterial)
        try c.encodeIfPresent(badgerTreatment, forKey: .badgerTreatment)
        try c.encodeIfPresent(badgerBand, forKey: .badgerBand)
        try c.encodeIfPresent(knotSize, forKey: .knotSize)
        try c.encodeIfPresent(knotShape, forKey: .knotShape)
        if isSample == true {
            try c.encode(true, forKey: .isSample)
        }
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(recognizedSource, forKey: .recognizedSource)
        if isManuallyConfirmed == true {
            try c.encode(true, forKey: .isManuallyConfirmed)
        }
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    var displayModel: String {
        if let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            return m
        }
        let b = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty, b != "品牌未注明", b != "仿刀", n.lowercased().hasPrefix(b.lowercased()) {
            let stripped = n.dropFirst(b.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return stripped }
        }
        return n
    }

    static func formatCanonicalDisplayName(brand: String, model: String, fallbackName: String) -> String {
        let cleanBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveModel = cleanModel.isEmpty ? cleanFallback : cleanModel
        guard !effectiveModel.isEmpty else { return cleanBrand }

        let isGenericBrand = cleanBrand.isEmpty
            || cleanBrand == "品牌未注明"
            || cleanBrand == "无品牌"
            || cleanBrand == "仿刀"
        if isGenericBrand {
            return effectiveModel
        }
        if effectiveModel.lowercased().hasPrefix(cleanBrand.lowercased()) {
            return effectiveModel
        }
        return "\(cleanBrand) \(effectiveModel)"
    }

    /// 规范显示名（所见即所得，与联想下拉显示的「品牌 + 型号」保持一致，如 `Feather New Hi-Stainless`）
    var canonicalDisplayName: String {
        Self.formatCanonicalDisplayName(brand: brand, model: displayModel, fallbackName: name)
    }

    /// 确定性属性指纹（用于异步 AI 请求返回前的并发修改核对）
    var fingerprint: String {
        let parts: [String] = [
            brand, name, model ?? "",
            razorType?.rawValue ?? "",
            isAdjustable == true ? "1" : "0",
            isSlant == true ? "1" : "0",
            material ?? "",
            plateType?.rawValue ?? "",
            gapOrSpec ?? "",
            bladeType?.rawValue ?? "",
            handleBrand ?? "",
            brushMaterial?.rawValue ?? "",
            badgerTreatment?.rawValue ?? "",
            badgerBand?.rawValue ?? "",
            knotSize ?? "",
            knotShape?.rawValue ?? "",
            isSample == true ? "1" : "0",
            status?.rawValue ?? "",
            notes ?? "",
            isManuallyConfirmed == true ? "1" : "0"
        ]
        return StableHash.fnv1a64Hex(parts.joined(separator: "\u{1F}"))
    }
}

/// 删除器材并同步清理日记引用时记录的受影响日记字段快照，用于撤销时精确恢复（S06）
struct GearEntryFieldSnapshot: Codable, Hashable {
    var entryID: String
    var previousFields: [JournalField]
    var previousLocallyModified: Bool?
    /// 清理后的日记内容指纹：撤销时比对当前日记指纹，若用户随后又编辑过该日记则避免静默覆盖新编辑
    var postMutationFingerprint: String
}

/// 器材撤销快照：同时记录 overrides、pending 以及受影响的日记字段快照，100% 向后兼容旧版 history 格式
struct GearHistorySnapshot: Codable, Hashable {
    var overrides: [String: GearOverride]
    var pending: [String]?
    var entrySnapshots: [GearEntryFieldSnapshot]?

    init(
        overrides: [String: GearOverride],
        pending: [String]? = nil,
        entrySnapshots: [GearEntryFieldSnapshot]? = nil
    ) {
        self.overrides = overrides
        self.pending = pending
        self.entrySnapshots = entrySnapshots
    }

    enum CodingKeys: String, CodingKey {
        case overrides
        case pending
        case entrySnapshots
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           container.contains(.overrides),
           let decodedOverrides = try? container.decode([String: GearOverride].self, forKey: .overrides) {
            self.overrides = decodedOverrides
            self.pending = try container.decodeIfPresent([String].self, forKey: .pending)
            self.entrySnapshots = try container.decodeIfPresent([GearEntryFieldSnapshot].self, forKey: .entrySnapshots)
            return
        }
        let single = try decoder.singleValueContainer()
        self.overrides = try single.decode([String: GearOverride].self)
        self.pending = nil
        self.entrySnapshots = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(overrides, forKey: .overrides)
        try container.encodeIfPresent(pending, forKey: .pending)
        try container.encodeIfPresent(entrySnapshots, forKey: .entrySnapshots)
    }
}

// MARK: - 运行时聚合器材项

struct GearItem: Identifiable, Hashable, Codable {
    var id: String
    var category: GearCategory
    var canonicalKey: String
    var brand: String
    var name: String
    var model: String
    var count: Int
    var lastUsedDate: String
    var rawKeys: [String]
    var isPending: Bool

    // 结构化属性
    var razorType: RazorType?
    var isAdjustable: Bool
    var isSlant: Bool
    var material: String?
    var plateType: PlateType?
    var gapOrSpec: String?
    var bladeType: BladeType?
    var handleBrand: String?
    var brushMaterial: BrushMaterial?
    var badgerTreatment: BadgerTreatment?
    var badgerBand: BadgerBand?
    var knotSize: String?
    var knotShape: BrushKnotShape?
    var isSample: Bool
    var status: GearStatus
    var notes: String?
    var recognizedSource: String?
    var isManuallyConfirmed: Bool = false

    /// 规范显示名（所见即所得，与联想列表展示一致）
    var canonicalDisplayName: String {
        GearOverride.formatCanonicalDisplayName(brand: brand, model: model, fallbackName: name)
    }

    var snapshotFingerprint: String {
        let parts: [String] = [
            category.rawValue, brand, name, model,
            rawKeys.sorted().joined(separator: ","),
            isPending ? "1" : "0",
            razorType?.rawValue ?? "",
            isAdjustable ? "1" : "0",
            isSlant ? "1" : "0",
            material ?? "",
            plateType?.rawValue ?? "",
            gapOrSpec ?? "",
            bladeType?.rawValue ?? "",
            handleBrand ?? "",
            brushMaterial?.rawValue ?? "",
            badgerTreatment?.rawValue ?? "",
            badgerBand?.rawValue ?? "",
            knotSize ?? "",
            knotShape?.rawValue ?? "",
            isSample ? "1" : "0",
            status.rawValue,
            notes ?? "",
            isManuallyConfirmed ? "1" : "0"
        ]
        return StableHash.fnv1a64Hex(parts.joined(separator: "\u{1F}"))
    }
}

/// 合并安全护栏：禁止合并关键物理规格（材质、底板、刀隙、Slant、结径、毛型、刷毛、手柄、正装/小样）不同的器材
enum GearMergeGuard {
    private static func normSpec(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    static func conflictReason(source: GearItem, target: GearItem) -> String? {
        if source.id == target.id {
            return L10n.t("源器材与目标器材相同", "Source and target are the same item")
        }
        if source.category != target.category {
            return L10n.t("分类不同，禁止合并", "Category mismatch")
        }

        switch source.category {
        case .razor:
            if let m1 = normSpec(source.material), let m2 = normSpec(target.material), m1 != m2 {
                return L10n.t("材质不同（\(source.material!) vs \(target.material!)）", "Different materials (\(source.material!) vs \(target.material!))")
            }
            if let p1 = source.plateType, let p2 = target.plateType, p1 != p2 {
                return L10n.t("底板形制不同（\(p1.rawValue) vs \(p2.rawValue)）", "Different baseplates (\(p1.rawValue) vs \(p2.rawValue))")
            }
            if let g1 = normSpec(source.gapOrSpec), let g2 = normSpec(target.gapOrSpec), g1 != g2 {
                return L10n.t("刀隙/规格不同（\(source.gapOrSpec!) vs \(target.gapOrSpec!)）", "Different gap/spec (\(source.gapOrSpec!) vs \(target.gapOrSpec!))")
            }
            if source.isSlant != target.isSlant {
                return L10n.t("Slant 斜头属性不同", "Different Slant geometry")
            }
        case .brush:
            if let k1 = normSpec(source.knotSize), let k2 = normSpec(target.knotSize), k1 != k2 {
                return L10n.t("结径不同（\(source.knotSize!) vs \(target.knotSize!)）", "Different knot sizes (\(source.knotSize!) vs \(target.knotSize!))")
            }
            if let s1 = source.knotShape, let s2 = target.knotShape, s1 != s2 {
                return L10n.t("毛型不同（\(s1.rawValue) vs \(s2.rawValue)）", "Different knot shapes (\(s1.rawValue) vs \(s2.rawValue))")
            }
            if let b1 = source.brushMaterial, let b2 = target.brushMaterial, b1 != b2 {
                return L10n.t("刷毛材质不同（\(b1.displayName) vs \(b2.displayName)）", "Different hair materials")
            }
            if let h1 = normSpec(source.handleBrand), let h2 = normSpec(target.handleBrand), h1 != h2 {
                return L10n.t("手柄品牌不同（\(source.handleBrand!) vs \(target.handleBrand!)）", "Different handle brands")
            }
        case .soap, .afterShave:
            if source.isSample != target.isSample {
                return L10n.t("正装与小样属性不同", "Full-size vs Sample mismatch")
            }
        default:
            break
        }
        return nil
    }
}

struct BrandGroup: Identifiable, Hashable {
    var id: String { brand }
    var brand: String
    var items: [GearItem]
    var totalUses: Int
    var latestDate: String
}

// MARK: - 统一器材短标签格式化

enum GearSpecFormatter {
    static func shortSpecTag(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return GearSanitizer.isShortGapSpec(trimmed) ? trimmed : nil
    }

    static func specTags(for item: GearItem) -> [String] {
        var list: [String] = []
        switch item.category {
        case .razor:
            if let rt = item.razorType { list.append(rt.shortLabel) }
            if item.isAdjustable { list.append(L10n.t("可调", "Adjustable")) }
            if item.isSlant { list.append("Slant") }
            if let pt = item.plateType { list.append(pt.rawValue) }
            if let gap = shortSpecTag(item.gapOrSpec) { list.append(gap) }
            if let mat = item.material?.trimmingCharacters(in: .whitespacesAndNewlines), !mat.isEmpty {
                list.append(L10n.materialDisplay(mat))
            }
        case .blade:
            if let bt = item.bladeType { list.append(bt.displayName) }
        case .brush:
            if let bm = item.brushMaterial { list.append(bm.displayName) }
            if item.brushMaterial == .badger {
                if let bt = item.badgerTreatment { list.append(bt.displayName) }
                if let bb = item.badgerBand { list.append(bb.displayName) }
            }
            if let sh = item.knotShape { list.append(sh.displayName) }
        default:
            break
        }
        return list
    }

    static func specTags(category: GearCategory, override ov: GearOverride, includeSampleTag: Bool = false) -> [String] {
        var tags: [String] = []
        switch category {
        case .razor:
            if let rt = ov.razorType { tags.append(rt.shortLabel) }
            if ov.isAdjustable == true { tags.append(L10n.t("可调", "Adjustable")) }
            if ov.isSlant == true { tags.append("Slant") }
            if let pt = ov.plateType { tags.append(pt.rawValue) }
            if let gap = shortSpecTag(ov.gapOrSpec) { tags.append(gap) }
            if let mat = ov.material?.trimmingCharacters(in: .whitespacesAndNewlines), !mat.isEmpty {
                tags.append(L10n.materialDisplay(mat))
            }
        case .blade:
            if let bt = ov.bladeType { tags.append(bt.displayName) }
        case .brush:
            if let bm = ov.brushMaterial { tags.append(bm.displayName) }
            if ov.brushMaterial == .badger {
                if let bt = ov.badgerTreatment { tags.append(bt.displayName) }
                if let bb = ov.badgerBand { tags.append(bb.displayName) }
            }
            if let sh = ov.knotShape { tags.append(sh.displayName) }
        case .soap, .afterShave:
            if includeSampleTag && ov.isSample == true {
                tags.append(L10n.t("小样", "Sample"))
            }
        default:
            break
        }
        return tags
    }
}

// MARK: - 确定性哈希工具（FNV-1a 64-bit，无进程随机种子）

enum StableHash {
    static func fnv1a64Hex(_ input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
