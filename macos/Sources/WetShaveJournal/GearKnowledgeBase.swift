import Foundation

enum GearKnowledgeBase {
    static let standardRazorMaterials: [String] = [
        "不锈钢", "钛合金", "黄铜", "红铜", "青铜", "磷青铜", "铝合金", "锌合金"
    ]

    // MARK: - 归一化与拼写纠错

    static func normalizeKey(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bladeUsageRegex = try! NSRegularExpression(pattern: #"(?i)\s*(\d+)\s*(?:st|nd|rd|th)\s*$"#)
    private static let knotSizeRegex = try! NSRegularExpression(pattern: #"(\d{2}(?:\.\d)?)\s*mm"#)
    private static let copperTokenRegex = try! NSRegularExpression(pattern: #"(?:^|[\s\d])cu(?:$|[\s])"#)
    private static let titaniumTokenRegex = try! NSRegularExpression(pattern: #"(?:^|[\s\d])ti(?:$|[\s])"#)
    private static let aluminumTokenRegex = try! NSRegularExpression(pattern: #"(?:^|\s)al(?:$|\s)"#)
    private static let stainlessTokenRegex = try! NSRegularExpression(pattern: #"(?:^|[\s\d])ss(?:$|[\s])"#)

    private static func matchesRegex(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func parseBladeUsage(_ raw: String) -> (baseName: String, useCount: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }
        if let match = bladeUsageRegex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let countRange = Range(match.range(at: 1), in: trimmed),
           let fullRange = Range(match.range(at: 0), in: trimmed) {
            let count = Int(trimmed[countRange])
            let base = String(trimmed[..<fullRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (base.isEmpty ? trimmed : base, count)
        }
        return (trimmed, nil)
    }

    static func extractBowlName(from lathering: String) -> String? {
        let trimmed = lathering.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "脸起" || trimmed == "手起" || trimmed == "碗起" || trimmed == "无" { return nil }
        if trimmed.hasSuffix("碗起") {
            let base = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? nil : base
        }
        return trimmed
    }

    static func quickSpellCorrect(_ raw: String, category: GearCategory) -> (corrected: String, wasCorrected: Bool) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = text
        let replacements: [(String, String)] = [
            ("Blackbrid", "Blackbird"),
            ("blackbrid", "Blackbird"),
            ("Twofaca", "Twoface"),
            ("twofaca", "Twoface"),
            ("Alysworth", "Aylsworth"),
            ("alysworth", "Aylsworth"),
            ("Darkkant", "Drakkant"),
            ("Seamgue", "Semogue"),
            ("seamgue", "Semogue"),
            ("Tayers", "Thayers"),
            ("Thyers", "Thayers"),
            ("Blve Astra", "Astra Blue"),
            ("DOROC", "Dorco"),
            ("AMONTURA", "Amonatura"),
            ("Razorock", "RazoRock"),
            ("RAZOROCK", "RazoRock")
        ]
        for (wrong, right) in replacements {
            if text.contains(wrong) {
                text = text.replacingOccurrences(of: wrong, with: right)
            }
        }
        return (text, text != original)
    }

    // MARK: - 知名湿剃品牌词库

    static let knownBrands: [(prefix: String, canonical: String)] = [
        ("above the tie", "Above The Tie"),
        ("atelier durdan", "Atelier Durdan"),
        ("ad ", "Atelier Durdan"),
        ("alpha ", "Alpha"),
        ("ascender", "Ascender"),
        ("aylsworth", "Aylsworth"),
        ("alysworth", "Aylsworth"),
        ("blackland", "Blackland"),
        ("blutt", "Blutt"),
        ("colonial", "Colonial"),
        ("gillette", "Gillette"),
        ("hls", "HLS"),
        ("homelike", "HLS"),
        ("karve", "Karve"),
        ("lambda", "Lambda"),
        ("maxwell june", "Maxwell June"),
        ("muhle", "Mühle"),
        ("mühle", "Mühle"),
        ("razorock", "RazoRock"),
        ("rr ", "RazoRock"),
        ("rex ", "Rex Supply Co."),
        ("rocnel", "Rocnel"),
        ("tatara", "Tatara"),
        ("trowell", "Trowell"),
        ("twoface", "Twoface"),
        ("twofaca", "Twoface"),
        ("wolfman", "Wolfman"),
        ("yaqi", "Yaqi"),
        ("frank shaving", "Frank Shaving"),
        ("fs ", "Frank Shaving"),
        ("fs", "Frank Shaving"),
        ("feather", "Feather"),
        ("kai", "Kai"),
        ("schick", "Schick"),
        ("personna", "Personna"),
        ("astra", "Astra"),
        ("dorco", "Dorco"),
        ("doroc", "Dorco"),
        ("super iridium", "Wizamet"),
        ("iridium super", "Wizamet"),
        ("wizamet", "Wizamet"),
        ("wald", "Wald"),
        ("oumo", "Oumo"),
        ("arno", "Arno"),
        ("boti", "Boti"),
        ("bobby", "Bobby"),
        ("paladin", "Paladin"),
        ("simpson", "Simpson"),
        ("semogue", "Semogue"),
        ("seamgue", "Semogue"),
        ("shavemac", "Shavemac"),
        ("longshaving", "Longshaving"),
        ("maggard", "Maggard"),
        ("rooney", "Rooney"),
        ("brad sears", "Brad Sears"),
        ("omega", "Omega"),
        ("dg ", "Declaration Grooming"),
        ("dg", "Declaration Grooming"),
        ("declaration", "Declaration Grooming"),
        ("tns ", "Turn-N-Shave"),
        ("turn-n-shave", "Turn-N-Shave"),
        ("c&h", "Chisel & Hound"),
        ("chisel & hound", "Chisel & Hound"),
        ("rv×", "RV"),
        ("rvx", "RV"),
        ("rv ", "RV"),
        ("mdc", "Martin de Candre"),
        ("martin de candre", "Martin de Candre"),
        ("sv1945", "Saponificio Varesino"),
        ("sv ", "Saponificio Varesino"),
        ("sv80", "Saponificio Varesino"),
        ("sv阿甘", "Saponificio Varesino"),
        ("sv沙漠", "Saponificio Varesino"),
        ("saponificio", "Saponificio Varesino"),
        ("ethos", "Ethos Grooming"),
        ("phoenix", "Phoenix Artisan Accoutrements"),
        ("paa ", "Phoenix Artisan Accoutrements"),
        ("macduff", "MacDuffs Soap Company"),
        ("stirling", "Stirling Soap Co."),
        ("moon", "Moon Soaps"),
        ("mammoth", "House of Mammoth"),
        ("house of mammoth", "House of Mammoth"),
        ("pantarei", "PantaRei"),
        ("elysian", "Elysian Soap Shop"),
        ("hags", "HAGS"),
        ("westman", "WestMan Shaving"),
        ("zingari", "Zingari Man"),
        ("cella", "Cella"),
        ("proraso", "Proraso"),
        ("thayers", "Thayers"),
        ("tayers", "Thayers"),
        ("thyers", "Thayers"),
        ("old spice", "Old Spice"),
        ("clubman", "Clubman Pinaud"),
        ("cerave", "CeraVe"),
        ("amonatura", "Amonatura"),
        ("amontura", "Amonatura"),
        ("lpl", "Le Père Lucien"),
        ("ae ", "Ariana & Evans"),
        ("ariana", "Ariana & Evans"),
        ("laxo", "Laxo"),
        ("华研", "华研"),
        ("哼哈", "哼哈"),
        ("双面", "Twoface"),
        ("rokyhows", "Rokyhows"),
        ("fizz", "Fizz"),
        ("cayuen", "Cayuen"),
        ("aka", "AKA"),
        ("trc", "The Razor Company"),
        ("arko", "Arko"),
        ("fine", "Fine Accoutrements"),
        ("nomad theory", "Nomad Theory"),
        ("s.ghost", "S.ghost"),
        ("帝诗", "帝诗"),
        ("树皮", "树皮"),
        ("阳森", "阳森"),
        ("图腾", "图腾")
    ]

    static let knownAdjustableKeywords: [String] = [
        "可调", "muramasa", "taiga", "elbrus", "ambassador", "konsul",
        "fatboy", "slim", "black beauty", "super adjustable", "progress",
        "futur", "variant", "horizon", "trowell t8", "t8", "osprey",
        "rockwell t2", "model t", "flexi", "gibbs", "rex", "adjustable"
    ]

    static func isCloneRazor(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("仿") || lower.contains("舜平") || lower.contains("clone") || lower.contains("复刻")
            || lower.contains("橙子or1") || lower.contains("橙子 or1") || lower.contains("队可调斜")
    }

    static func simplifyMaterial(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return inferMaterial(from: raw) ?? raw
    }

    static func inferMaterial(from text: String) -> String? {
        let lower = " " + text.lowercased() + " "
        if lower.contains("磷青铜") || lower.contains("phosphor bronze") { return "磷青铜" }
        if lower.contains("青铜") || lower.contains("bronze") { return "青铜" }
        if lower.contains("红铜") || lower.contains("紫铜") || lower.contains("copper") || matchesRegex(copperTokenRegex, in: lower) { return "红铜" }
        if lower.contains("黄铜") || lower.contains("brass") { return "黄铜" }
        if lower.contains("钛") || lower.contains("titanium") || lower.contains("grade 5") || lower.contains("grade 2") || matchesRegex(titaniumTokenRegex, in: lower) { return "钛合金" }
        if lower.contains("铝") || lower.contains("aluminum") || lower.contains("aluminium") || lower.contains("6061") || lower.contains("7075") || matchesRegex(aluminumTokenRegex, in: lower) { return "铝合金" }
        if lower.contains("316l") || lower.contains("316") || lower.contains("304") || lower.contains("303") || lower.contains("17-4") || lower.contains("不锈钢") || lower.contains("stainless") || lower.contains("steel") || matchesRegex(stainlessTokenRegex, in: lower) {
            return "不锈钢"
        }
        if lower.contains("锌合金") || lower.contains("zamak") || lower.contains("zamac") || lower.contains("zinc") || lower.contains("chrome") { return "锌合金" }
        return nil
    }

    static func inferIsSlant(from text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("slant") || lower.contains("斜") || lower.contains("wunderbar")
            || lower.contains("konsul") || lower.contains("l2") || lower.contains("l3")
    }

    static func inferPlateType(from text: String) -> PlateType? {
        let lower = text.lowercased()
        let isOC = lower.contains(" oc") || lower.hasSuffix("oc") || lower.contains("open comb") || lower.contains("开齿") || lower.contains("r41")
        let isDC = lower.contains(" dc") || lower.hasSuffix("dc") || lower.contains("dual comb") || lower.contains("双面齿")
        let isSB = lower.contains(" sb") || lower.hasSuffix("sb") || lower.contains(" cc") || lower.hasSuffix("cc") || lower.contains("safety bar") || lower.contains("closed comb") || lower.contains("闭齿")

        if isOC { return .oc }
        if isDC { return .dc }
        if isSB { return .sb }
        return nil
    }

    static func inferRazorType(from text: String) -> RazorType? {
        let lower = text.lowercased()
        if lower.contains("极光") || lower.contains("gillette lab") || lower.contains("gillette blue") || lower.contains("mach3") || lower.contains("fusion") || lower.contains("盒刀") || lower.contains("cartridge") {
            return .cartridge
        }
        if lower.contains("twin blade") || lower.contains("maxwell june") || lower.contains(" tb") || lower.hasSuffix("tb") {
            return .twinBlade
        }
        if lower.contains("shavette") || lower.contains("替刃") || lower.contains("剃刃") || lower.contains("artist club ss") || lower.contains("feather dx") {
            return .shavette
        }
        if lower.contains("straight") || lower.contains("直剃") {
            return .straight
        }
        if lower.contains("树皮") || lower.contains("半de") || lower.contains("half de") || lower.contains("twig") || lower.contains("thorn") || lower.contains("proof razor") {
            return .seHalfDE
        }
        if lower.contains("injector") || lower.contains("schick type") || lower.contains("supply se") {
            return .seInjector
        }
        if lower.contains("vestige") || lower.contains("batch 004") || lower.contains("gem") || lower.contains("sabre") || lower.contains("micromatic") {
            return .seGEM
        }
        if lower.contains("vector") || lower.contains("hawk") || lower.contains("general") || lower.contains("amakuni") || lower.contains("天国") || lower.contains("horizon") || lower.contains("se1") || lower.contains("se2") || lower.contains("tf-1") || lower.contains("artist club") || lower.contains(" ac ") {
            return .seAC
        }
        return nil
    }

    static func inferBladeType(from text: String) -> BladeType? {
        let lower = text.lowercased()
        if lower.contains("极光") || lower.contains("gillette lab") || lower.contains("gillette blue") || lower.contains("mach3") || lower.contains("fusion") || lower.contains("盒刀") || lower.contains("cartridge") {
            return .cartridge
        }
        if lower.contains("62-0178") || lower.contains("ptfe") {
            return .gem
        }
        if lower.contains("injector") || lower.contains("b-20") {
            return .injector
        }
        if lower.contains("ctm") || lower.contains("captain") || lower.contains("ps-20") || lower.contains("pro super") || lower.contains("p-30") || lower.contains("p30") || lower.contains("proline") || lower.contains("protouch") || lower.contains("premiumguard") || lower.contains("artist club") || lower.contains(" ac") {
            return .ac
        }
        if lower.contains("de") || lower.contains("74-0002") || lower.contains("60-0257") || lower.contains("nacet") || lower.contains("astra") || lower.contains("wizamet") || lower.contains("iridium") || lower.contains("dorco") || lower.contains("俄纸") || lower.contains("德产红") || lower.contains("365") || lower.contains("碳素钢") {
            return .de
        }
        return nil
    }

    static func inferBrushAttributes(from text: String) -> (
        material: BrushMaterial?,
        treatment: BadgerTreatment?,
        band: BadgerBand?,
        knotSize: String?,
        knotShape: BrushKnotShape?
    ) {
        let lower = text.lowercased()
        var knotSize: String? = nil
        if let match = knotSizeRegex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let r = Range(match.range(at: 1), in: lower) {
            knotSize = "\(lower[r])mm"
        }

        var knotShape: BrushKnotShape? = nil
        if lower.contains("hybrid") { knotShape = .hybrid }
        else if lower.contains("fan") { knotShape = .fan }
        else if lower.contains("bulb") { knotShape = .bulb }

        var material: BrushMaterial? = nil
        var treatment: BadgerTreatment? = nil
        var band: BadgerBand? = nil

        if lower.contains("羊毛") || lower.contains("wool") {
            material = .wool
        } else if lower.contains("猪鬃") || lower.contains("boar") || lower.contains("10048") || lower.contains("soc taj") || lower.contains("pigsy") {
            material = .boar
        } else if lower.contains("马毛") || lower.contains("horse") {
            material = .horse
        } else if lower.contains("人造") || lower.contains("synthetic") || lower.contains("wald") || lower.contains("pur-tech") || lower.contains("g5") || lower.contains("st3") || lower.contains("st-3") || lower.contains("st-2") || lower.contains("cloudline") || lower.contains("云线") || lower.contains("云尾") || lower.contains("slg") || lower.contains("star100") || lower.contains("star 86") || lower.contains("流云") || lower.contains("twoface gs") {
            material = .synthetic
        } else if lower.contains("獾") || lower.contains("badger") || lower.contains("2band") || lower.contains("3band") || lower.contains("2-band") || lower.contains("3-band") || lower.contains("二段") || lower.contains("二路") || lower.contains("三段") || lower.contains("三路") || lower.contains("满洲") || lower.contains("manchurian") || lower.contains("d01") || lower.contains("shd") || lower.contains("silvertip") || lower.contains("finest") || lower.contains("脊背毛") || lower.contains("漂尖") || lower.contains("老毛") || lower.contains("特路") || lower.contains("paladin") || lower.contains("shavemac") || lower.contains("rooney") || lower.contains("brad sears") || lower.contains("dg b") || lower.contains("tns ") || lower.contains("reserve") || lower.contains("epoch") || lower.contains("kirin") || lower.contains("麒麟") {
            material = .badger
        }

        if material == .badger {
            if lower.contains("漂尖") || lower.contains("gel") || lower.contains("bleached") || lower.contains("shd") {
                treatment = .gelTip
            } else if lower.contains("无漂") || lower.contains("unbleached") || lower.contains("脊背") || lower.contains("满洲") || lower.contains("d01") || lower.contains("finest") {
                treatment = .unbleached
            }

            if lower.contains("3band") || lower.contains("三段") || lower.contains("三路") || lower.contains("3-band") {
                band = .threeBand
            } else if lower.contains("2band") || lower.contains("二段") || lower.contains("二路") || lower.contains("2-band") || lower.contains("满洲") || lower.contains("finest") || lower.contains("shd") || lower.contains("脊背") {
                band = .twoBand
            }
        }

        return (material, treatment, band, knotSize, knotShape)
    }

    static func inferDefaultOverride(rawName: String, category: GearCategory) -> GearOverride {
        let (corrected, _) = quickSpellCorrect(rawName, category: category)
        let lower = corrected.lowercased()

        var brand = "品牌未注明"
        var handleBrand: String? = nil

        if category == .razor && isCloneRazor(corrected) {
            brand = "仿刀"
        } else {
            for item in knownBrands {
                if lower.hasPrefix(item.prefix) {
                    brand = item.canonical
                    break
                }
            }
        }

        // 剃须刷以刷节（毛结）品牌为主 brand，手柄品牌为可选附属 handleBrand
        if category == .brush, corrected.contains("×") || lower.contains(" x ") {
            let sep = corrected.contains("×") ? "×" : " x "
            let parts = corrected.components(separatedBy: sep)
            if parts.count >= 2 {
                let firstRaw = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let secondRaw = parts[1].trimmingCharacters(in: .whitespaces).lowercased()

                var detectedHandle: String? = nil
                var detectedKnot: String? = nil

                for item in knownBrands {
                    let p = item.prefix.trimmingCharacters(in: .whitespaces)
                    if detectedHandle == nil && firstRaw.hasPrefix(p) {
                        detectedHandle = item.canonical
                    }
                    if detectedKnot == nil && secondRaw.hasPrefix(p) {
                        detectedKnot = item.canonical
                    }
                }
                if detectedKnot == nil {
                    if secondRaw.hasPrefix("long") { detectedKnot = "Longshaving" }
                    else if secondRaw.hasPrefix("maggard") { detectedKnot = "Maggard" }
                }

                if let knot = detectedKnot {
                    brand = knot
                    if let h = detectedHandle, h.lowercased() != knot.lowercased() {
                        handleBrand = h
                    }
                }
            }
        }

        let defaultStatus: GearStatus = category == .blade ? .inStock : .active
        var override = GearOverride(brand: brand, name: corrected, status: defaultStatus)

        if category == .razor {
            override.razorType = inferRazorType(from: corrected) ?? .de
            override.isAdjustable = knownAdjustableKeywords.contains(where: { lower.contains($0) })
            override.isSlant = inferIsSlant(from: corrected)
            override.material = inferMaterial(from: corrected)
            override.plateType = inferPlateType(from: corrected)
        } else if category == .blade {
            override.bladeType = inferBladeType(from: corrected)
        } else if category == .brush {
            let brushInfo = inferBrushAttributes(from: corrected)
            override.handleBrand = handleBrand
            override.brushMaterial = brushInfo.material
            override.badgerTreatment = brushInfo.treatment
            override.badgerBand = brushInfo.band
            override.knotSize = brushInfo.knotSize
            override.knotShape = brushInfo.knotShape
        }

        return override
    }
}

// MARK: - AI 与编辑器强制本地清洗器（Sanitizer）

enum GearSanitizer {
    private static let leadingGapRegex = try! NSRegularExpression(pattern: #"^(\d+(?:\.\d{1,2})?)\s*(mm)?(\+{1,2})?(?:\b|\s)"#, options: .caseInsensitive)

    static let allowedRazorMaterials: Set<String> = Set(GearKnowledgeBase.standardRazorMaterials)
    static let maxCardSpecLength: Int = 12

    /// 严格清洗材质：自动映射英文/牌号（316L / 304 / Stainless Steel / Grade 5 Ti 等），不在 8 种标准中文材质内则返回 nil
    static func sanitizeMaterialStrict(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if allowedRazorMaterials.contains(trimmed) {
            return trimmed
        }
        if let mapped = GearKnowledgeBase.inferMaterial(from: trimmed), allowedRazorMaterials.contains(mapped) {
            return mapped
        }
        return nil
    }

    /// 判断是否为卡片允许展示的极简短规格（如 0.99、1.12+、Standard、Lite、E）
    static func isShortGapSpec(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxCardSpecLength else { return false }
        let lower = trimmed.lowercased()
        let forbiddenTokens = [
            "blade", "exposure", "gap", "positive", "negative", "neutral",
            "weight", "gram", "grams", "克重", "露刃", "刀隙",
            ",", "，", ";", "；", "/", "(", "（"
        ]
        for token in forbiddenTokens {
            if lower.contains(token) { return false }
        }
        return true
    }

    /// 将不合规的超长 gapOrSpec 自动迁移至 notes（详细参数），并尽可能提取极简短规格（≤10 字符）
    static func sanitizeGapAndNotes(
        gapOrSpec rawGap: String?,
        existingNotes: String?,
        extraNotes: String? = nil
    ) -> (gapOrSpec: String?, notes: String?) {
        var noteParts: [String] = []
        if let ex = existingNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !ex.isEmpty {
            noteParts.append(ex)
        }
        if let extra = extraNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            if !noteParts.contains(where: { $0.localizedCaseInsensitiveContains(extra) }) {
                noteParts.append(extra)
            }
        }

        var finalGap: String? = nil
        if let trimmedGap = rawGap?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedGap.isEmpty {
            if isShortGapSpec(trimmedGap) {
                finalGap = trimmedGap
            } else {
                // 超长或含 blade exposure / blade gap 说明：完整原文移入 notes
                if !noteParts.contains(where: { $0.localizedCaseInsensitiveContains(trimmedGap) }) {
                    noteParts.append(trimmedGap)
                }
                // 若开头含清晰简短数字刀隙（如 "0.71mm blade gap..." 或 "1.12 mm blade gap..."），提取极简短值
                if let match = leadingGapRegex.firstMatch(in: trimmedGap, range: NSRange(trimmedGap.startIndex..., in: trimmedGap)),
                   let numRange = Range(match.range(at: 1), in: trimmedGap) {
                    let num = String(trimmedGap[numRange])
                    let plus: String = {
                        if let pr = Range(match.range(at: 3), in: trimmedGap) { return String(trimmedGap[pr]) }
                        return ""
                    }()
                    let mm: String = {
                        if plus.isEmpty, Range(match.range(at: 2), in: trimmedGap) != nil { return "mm" }
                        return ""
                    }()
                    let candidate = "\(num)\(mm)\(plus)"
                    if candidate.count <= 10 && isShortGapSpec(candidate) {
                        finalGap = candidate
                    }
                }
            }
        }

        let mergedNotes = noteParts.isEmpty ? nil : noteParts.joined(separator: "；")
        return (finalGap, mergedNotes)
    }

    /// 清理型号中多余的尾部材质/底板后缀（仅剥离 SS/Ti/Cu/OC/SB/DC，保留 112+ / 150++ / MR112+ / WR1 0.74 / BR-1 等子型号）
    static func sanitizeModel(_ rawModel: String?, fallback: String? = nil) -> String? {
        guard var text = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return fallback
        }
        // 仅在尾部作为独立词出现时剥离材质后缀（不触碰 L2++ / 112+ / 0.74 / BR-1 等子型号）
        let suffixPatterns = [
            #"(?i)\s+(?:316l|304|stainless\s+steel|stainless|titanium|brass|copper|bronze|aluminum|aluminium|zamak)$"#,
            #"(?i)\s+(?:ss|ti|cu|al)$"#
        ]
        for pat in suffixPatterns {
            let next = text.replacingOccurrences(of: pat, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !next.isEmpty { text = next }
        }
        return text.isEmpty ? fallback : text
    }

    /// 规范化品牌常见冗长后缀，防止 AI 拆散同一品牌分组
    static func sanitizeBrand(_ rawBrand: String?) -> String? {
        guard let trimmed = rawBrand?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case "karve shaving co.", "karve shaving co", "karve shaving":
            return "Karve"
        case "lambda razors":
            return "Lambda"
        case "blutt rasur":
            return "Blutt"
        case "blackland razors":
            return "Blackland"
        case "wolfman razors":
            return "Wolfman"
        case "tatara razors":
            return "Tatara"
        case "aylsworth razors":
            return "Aylsworth"
        default:
            return trimmed
        }
    }

    /// 对整条 GearOverride 做强制本地清洗（用于 AI 解码后与编辑器保存前）
    static func sanitizeOverride(_ override: GearOverride, category: GearCategory, extraNotes: String? = nil) -> GearOverride {
        var clean = override
        if let normalizedBrand = sanitizeBrand(clean.brand) {
            clean.brand = normalizedBrand
        }
        if category == .razor {
            clean.material = sanitizeMaterialStrict(clean.material)
            clean.model = sanitizeModel(clean.model)
            let (gap, mergedNotes) = sanitizeGapAndNotes(
                gapOrSpec: clean.gapOrSpec,
                existingNotes: clean.notes,
                extraNotes: extraNotes
            )
            clean.gapOrSpec = gap
            clean.notes = mergedNotes
        } else {
            clean.gapOrSpec = nil
            if let extra = extraNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
                let existing = clean.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if existing.isEmpty {
                    clean.notes = extra
                } else if !existing.localizedCaseInsensitiveContains(extra) {
                    clean.notes = "\(existing)；\(extra)"
                }
            }
        }
        if category == .brush {
            if let hb = clean.handleBrand?.trimmingCharacters(in: .whitespacesAndNewlines),
               !hb.isEmpty,
               hb.lowercased() != clean.brand.lowercased() {
                clean.handleBrand = hb
            } else {
                clean.handleBrand = nil
            }
            if let ks = clean.knotSize?.trimmingCharacters(in: .whitespacesAndNewlines) {
                clean.knotSize = ks.isEmpty ? nil : ks
            }
        } else {
            clean.handleBrand = nil
        }
        clean.status = GearStatus.normalized(clean.status, for: category)
        return clean
    }
}
