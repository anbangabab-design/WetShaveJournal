import SwiftUI
import AppKit

/// 品牌 Logo 检索与多级缓存服务（v1.4.2 内置精选图包 + 高命中抓取版）：
/// 0) `CustomLogos/`（用户手动上传永久图标，最高优先级，永不被清理或覆盖）
/// 1) `BrandLogos/`（App 内置精选图包，离线秒开、永不退回字母圈）
/// 2) `LogoCache/`（白名单官网自动抓取缓存：apple-touch-icon → 高清 icon → og:image → /favicon.ico → Google Favicon sz=128 稳定回退）
/// 3) 无图/非白名单品牌平滑回退极简圆形首字母/首字徽章（严禁对未知品牌瞎猜 `<品牌>.com` 或抓取 Etsy 等平台站标）
@MainActor
final class BrandLogoCache: ObservableObject {
    static let shared = BrandLogoCache()
    static let customLogoDidChangeNotification = Notification.Name("WetShaveJournal.CustomLogoDidChange")
    nonisolated static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "ico", "bmp", "heic", "tiff"
    ]

    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var cacheRevision: Int = 0

    private struct PendingFetchRequest {
        let key: String
        let canonicalKey: String
        let canonicalASCIIKey: String
        let brand: String
        let knownDomain: String
        let diskURL: URL
    }

    private let maxConcurrentFetches: Int = 3
    private let failedCooldownInterval: TimeInterval = 24 * 3600
    private var activeFetchCount: Int = 0
    private var fetchGeneration: Int = 0
    private var inFlight: Set<String> = []
    private var queuedKeys: Set<String> = []
    private var pendingQueue: [PendingFetchRequest] = []
    private var failedCooldowns: [String: TimeInterval] = [:]

    private let appSupportRoot: URL
    private let cacheDirectory: URL          // 自动抓取缓存：LogoCache/
    private let customDirectory: URL         // 用户手动上传：CustomLogos/
    private let legacyDirectory: URL         // 旧版用户目录：BrandLogos/
    private let bundledLogosDirectory: URL?  // App 内置精选图包：.app/Contents/Resources/BrandLogos/
    private let cooldownFileURL: URL         // 失败冷却缓存：LogoCache/failed_cooldown.json

    // 同步索引与只读内存缓存（不触发 SwiftUI view-update 期间的 @Published 写入，确保首帧即秒开）
    private var customIndex: [String: URL] = [:]
    private var bundledIndex: [String: URL] = [:]
    private var localImageCache: [String: NSImage] = [:]
    private var darkInvertCache: [ObjectIdentifier: Bool] = [:]
    private var lightInvertCache: [ObjectIdentifier: Bool] = [:]

    private nonisolated static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 14
        config.httpMaximumConnectionsPerHost = 3
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    /// 严格禁止作为品牌 Logo 来源的平台域名黑名单（注意放行 Shopify 静态图 CDN `cdn.shopify.com`）
    nonisolated static let blacklistedDomains: [String] = [
        "etsy.com",
        "etsystatic.com",
        "amazon.",
        "ebay.",
        "aliexpress.",
        "taobao.",
        "tmall.",
        "jd.com",
        "reddit.com",
        "instagram.com",
        "facebook.com",
        "youtube.com",
        "badgerandblade.com",
        "damnfineshave.com",
        "wikipedia.org",
        "pinterest.",
        "twitter.com",
        "x.com",
        "tiktok.com",
        "google.com",
        "gstatic.com",
        "bing.com",
        "duckduckgo.com",
        "wixsite.com",
        "blogspot.",
        "wordpress.com"
    ]

    /// 仅作为平台主站禁止、但不拦截其静态资源子域（如 cdn.shopify.com）的域名
    nonisolated static let exactBlacklistedHosts: Set<String> = [
        "shopify.com",
        "www.shopify.com",
        "apps.shopify.com",
        "accounts.shopify.com"
    ]

    /// 品牌中英文/简称/子线别名归一化表（小写精确与去符号/去重音匹配均支持）
    nonisolated static let brandAliases: [String: String] = [
        "华研": "Terry's Soap",
        "华研手工皂": "Terry's Soap",
        "hwayeon": "Terry's Soap",
        "hwayeon soap": "Terry's Soap",
        "hwayeon soap co": "Terry's Soap",
        "hwayeon soap co.": "Terry's Soap",
        "terrys soap": "Terry's Soap",
        "terry soap": "Terry's Soap",
        "terry's soap": "Terry's Soap",
        "帝诗": "DSCosmetic",
        "dscosmetic": "DSCosmetic",
        "ds cosmetic": "DSCosmetic",
        "wolfman": "Wolfman",
        "wolfman razors": "Wolfman",
        "狼人": "Wolfman",
        "karve": "Karve",
        "karve shaving": "Karve",
        "karve shaving co": "Karve",
        "karve shaving co.": "Karve",
        "stirling": "Stirling Soap Co.",
        "stirling soap": "Stirling Soap Co.",
        "stirling soap co": "Stirling Soap Co.",
        "stirling soap co.": "Stirling Soap Co.",
        "斯特林": "Stirling Soap Co.",
        "dg": "Declaration Grooming",
        "declaration": "Declaration Grooming",
        "declaration grooming": "Declaration Grooming",
        "hom": "House of Mammoth",
        "mammoth": "House of Mammoth",
        "house of mammoth": "House of Mammoth",
        "猛犸象": "House of Mammoth",
        "paa": "Phoenix Artisan Accoutrements",
        "phoenix": "Phoenix Artisan Accoutrements",
        "phoenix shaving": "Phoenix Artisan Accoutrements",
        "phoenix artisan": "Phoenix Artisan Accoutrements",
        "phoenix artisan accoutrements": "Phoenix Artisan Accoutrements",
        "moon": "Moon Soaps",
        "moon soaps": "Moon Soaps",
        "ae": "Ariana & Evans",
        "a&e": "Ariana & Evans",
        "ariana & evans": "Ariana & Evans",
        "ariana and evans": "Ariana & Evans",
        "the club": "Ariana & Evans",
        "c&h": "Chisel & Hound",
        "chisel & hound": "Chisel & Hound",
        "chisel and hound": "Chisel & Hound",
        "paladin": "Paladin",
        "paladin shaving": "Paladin",
        "tns": "Turn-N-Shave",
        "turn-n-shave": "Turn-N-Shave",
        "turn n shave": "Turn-N-Shave",
        "turnnshave": "Turn-N-Shave",
        "brad sears": "Brad Sears",
        "brad sears shave works": "Brad Sears",
        "yaqi": "Yaqi",
        "yaqi shaving": "Yaqi",
        "yaqi brush": "Yaqi",
        "雅琪": "Yaqi",
        "aka": "AKA",
        "aka brushworx": "AKA",
        "aka_brushworx": "AKA",
        "arno": "Arno",
        "arno brush": "Arno",
        "arnobrush": "Arno",
        "amonatura": "Amonatura",
        "laxo": "LAXO",
        "aura laxo": "LAXO",
        "aura_laxo": "LAXO",
        "twoface": "TwoFace Brothers",
        "twoface brothers": "TwoFace Brothers",
        "twoface_brothers": "TwoFace Brothers",
        "rokyhows": "ROKYHOWS",
        "aylsworth": "Aylsworth",
        "aylsworth razors": "Aylsworth",
        "alysworth": "Aylsworth",
        "rocnel": "Rocnel",
        "lambda": "Lambda",
        "lambda razors": "Lambda",
        "westman": "WestMan Shaving",
        "westman shaving": "WestMan Shaving",
        "semogue": "Semogue",
        "soc": "Semogue",
        "semogue owners club": "Semogue",
        "cayuen": "Cayuen",
        "cayuen workshop": "Cayuen",
        "the cayuen workshop": "Cayuen",
        "att": "Above The Tie",
        "above the tie": "Above The Tie",
        "ad": "Atelier Durdan",
        "atelier durdan": "Atelier Durdan",
        "alpha": "Alpha",
        "alpha shaving": "Alpha",
        "alpha shaving works": "Alpha",
        "astra": "Astra",
        "astra sp": "Astra",
        "astra blue": "Astra",
        "astra green": "Astra",
        "b&m": "Barrister and Mann",
        "barrister & mann": "Barrister and Mann",
        "barrister and mann": "Barrister and Mann",
        "blackland": "Blackland",
        "blackland razors": "Blackland",
        "黑鸟": "Blackland",
        "blutt": "Blutt",
        "blutt rasur": "Blutt",
        "cella": "Cella",
        "cella milano": "Cella",
        "clubman": "Clubman Pinaud",
        "pinaud": "Clubman Pinaud",
        "clubman pinaud": "Clubman Pinaud",
        "colonial": "Colonial",
        "colonial razors": "Colonial",
        "dorco": "Dorco",
        "doroc": "Dorco",
        "elysian": "Elysian Soap Shop",
        "elysian soap shop": "Elysian Soap Shop",
        "ethos": "Ethos Grooming",
        "ethos grooming": "Ethos Grooming",
        "ethos grooming essentials": "Ethos Grooming",
        "fine": "Fine Accoutrements",
        "fine accoutrements": "Fine Accoutrements",
        "fs": "Frank Shaving",
        "frank shaving": "Frank Shaving",
        "feather": "Feather",
        "羽毛": "Feather",
        "nod": "Gentleman's Nod",
        "gentlemans nod": "Gentleman's Nod",
        "gentleman's nod": "Gentleman's Nod",
        "gillette": "Gillette",
        "吉列": "Gillette",
        "hags": "HAGS",
        "have a great shave": "HAGS",
        "henson": "Henson",
        "henson shaving": "Henson",
        "hls": "HLS",
        "homelike": "HLS",
        "homelikeshaving": "HLS",
        "homelike shaving": "HLS",
        "kai": "Kai",
        "贝印": "Kai",
        "lpl": "Le Père Lucien",
        "le pere lucien": "Le Père Lucien",
        "le père lucien": "Le Père Lucien",
        "macduff": "MacDuffs Soap Company",
        "macduffs": "MacDuffs Soap Company",
        "macduff's soap company": "MacDuffs Soap Company",
        "macduffs soap company": "MacDuffs Soap Company",
        "maggard": "Maggard",
        "maggard razors": "Maggard",
        "mdc": "Martin de Candre",
        "martin de candre": "Martin de Candre",
        "mj": "Maxwell June",
        "maxwell june": "Maxwell June",
        "muhle": "Mühle",
        "muehle": "Mühle",
        "mühle": "Mühle",
        "穆乐": "Mühle",
        "merkur": "Merkur",
        "默克尔": "Merkur",
        "mwf": "Mitchell's Wool Fat",
        "noble otter": "Noble Otter",
        "水獭": "Noble Otter",
        "nord": "Nord Razors",
        "nord razors": "Nord Razors",
        "nord shaving": "Nord Razors",
        "nordic shaving": "Nordic Shaving Company",
        "oumo": "Oumo",
        "欧慕": "Oumo",
        "boti": "Boti",
        "博蒂": "Boti",
        "proraso": "Proraso",
        "博拉索": "Proraso",
        "rr": "RazoRock",
        "razorock": "RazoRock",
        "italian barber": "RazoRock",
        "rex": "Rex Supply Co.",
        "rex supply": "Rex Supply Co.",
        "rex supply co": "Rex Supply Co.",
        "rex supply co.": "Rex Supply Co.",
        "sv": "Saponificio Varesino",
        "sv1945": "Saponificio Varesino",
        "saponificio varesino": "Saponificio Varesino",
        "schick": "Schick",
        "舒适": "Schick",
        "simpson": "Simpson",
        "simpsons": "Simpson",
        "辛普森": "Simpson",
        "tatara": "Tatara",
        "tatara razors": "Tatara",
        "tobs": "Taylor of Old Bond Street",
        "tgs": "The Goodfellas' Smile",
        "trc": "The Razor Company",
        "thayers": "Thayers",
        "津尔氏": "Thayers",
        "timeless": "Timeless",
        "timeless razor": "Timeless",
        "wald": "Wald",
        "wald shaving": "Wald",
        "wilkinson": "Wilkinson Sword",
        "wizamet": "Wizamet",
        "wizamet super iridium": "Wizamet",
        "super iridium": "Wizamet",
        "iridium super": "Wizamet",
        "polsilver": "Wizamet",
        "zm": "Zingari Man",
        "zingari": "Zingari Man",
        "zingari man": "Zingari Man",
        "ej": "Edwin Jagger",
        "l'occitane": "L'Occitane",
        "loccitane": "L'Occitane",
        "欧舒丹": "L'Occitane",
        "dr harris": "D.R. Harris",
        "carbon": "Carbon Shaving",
        "carbon shaving": "Carbon Shaving",
        "ap shave co": "AP Shave Co"
    ]

    /// 经核实的湿剃品牌官方独立域名白名单（严禁在此表外盲猜 .com）
    nonisolated static let brandDomains: [String: String] = [
        "Above The Tie": "abovethetie.com",
        "Acqua di Parma": "acquadiparma.com",
        "AKA": "akabrushworx.com",
        "Alpha": "alphashaving.com",
        "Amonatura": "amonaturastore.com",
        "AP Shave Co": "apshaveco.com",
        "Ariana & Evans": "aegrooming.com",
        "Arko": "arkomen.com",
        "Arno": "arnoshavingbrush.com",
        "Ascender": "ascenderrazors.com",
        "Atelier Durdan": "atelierdurdan.com",
        "Aylsworth": "aylsworthrazors.com",
        "Barrister and Mann": "barristerandmann.com",
        "BIC": "bic.com",
        "Blackland": "blacklandrazors.com",
        "Blutt": "bluttrasur.ch",
        "Boti": "botibrush.com",
        "Brad Sears": "bradsearsshaveworks.com",
        "Captain's Choice": "captainschoicestore.com",
        "Carbon Shaving": "carbonshavingco.com",
        "Castle Forbes": "castleforbes.com",
        "Catie's Bubbles": "catiesbubbles.com",
        "Cayuen": "cayuenworkshop.com",
        "Cella": "cellamilano.it",
        "CeraVe": "cerave.com",
        "Charcoal Goods": "charcoalgoods.com",
        "Chisel & Hound": "chiselandhound.com",
        "Chiseled Face": "chiseledface.com",
        "Clubman Pinaud": "clubman.com",
        "Colonial": "colonialrazors.com",
        "D.R. Harris": "drharris.co.uk",
        "Declaration Grooming": "declarationgrooming.com",
        "Derby": "derbyrazorblades.com",
        "Dorco": "dorcousa.com",
        "DSCosmetic": "http://dscosmetic.com",
        "Edwin Jagger": "edwinjagger.com",
        "Elysian Soap Shop": "elysiansoapshop.com",
        "Ethos Grooming": "ethosgroomingessentials.com",
        "Fatip": "fatip.it",
        "Feather": "feather.co.jp",
        "Fine Accoutrements": "fineaccoutrements.com",
        "Frank Shaving": "frankshaving.com",
        "Gentleman's Nod": "gentlemansnod.com",
        "Geo. F. Trumper": "trumpers.com",
        "Gillette": "gillette.com",
        "Grooming Dept": "groomingdept.com",
        "HAGS": "hagsartisan.com",
        "Haslinger": "haslingerseifen.at",
        "Henson": "hensonshaving.com",
        "HLS": "homelikeshaving.ru",
        "House of Mammoth": "houseofmammoth.com",
        "Kai": "kai-group.com",
        "Karve": "karveshaving.com",
        "L'Occitane": "loccitane.com",
        "Lambda": "lambda-razors.com",
        "LAXO": "aura-craft.com/laxo/",
        "Le Père Lucien": "leperelucien.com",
        "Leaf": "leafshave.com",
        "Longshaving": "longshaving.com",
        "MacDuffs Soap Company": "macduffssoapcompany.com",
        "Maggard": "maggardrazors.com",
        "Martin de Candre": "martin-de-candre.com",
        "Maxwell June": "maxwelljune.com",
        "Merkur": "merkur-razors.com",
        "Mitchell's Wool Fat": "mitchellswoolfatsoap.co.uk",
        "Moon Soaps": "moonsoaps.com",
        "Mühle": "muehle-shaving.com",
        "Murphy and McNeil": "murphyandmcneil.com",
        "Nivea": "nivea.com",
        "Noble Otter": "nobleotter.com",
        "Nomad Theory": "nomadtheory.co.uk",
        "Nord Razors": "nordrazors.com",
        "Nordic Shaving Company": "nordicshaving.com",
        "Old Spice": "oldspice.com",
        "Omega": "omegabrush.com",
        "Osma": "osma-tradition.com",
        "Oumo": "oumoshavingbrush.com",
        "Paladin": "paladinshaving.com",
        "PantaRei": "pantareibrushes.it",
        "Parker": "parkershaving.com",
        "Personna": "personna.com",
        "Phoenix Artisan Accoutrements": "phoenixartisanaccoutrements.com",
        "Proraso": "proraso.com",
        "RazoRock": "italianbarber.com",
        "Rex Supply Co.": "rexsupplyco.com",
        "Rockwell": "getrockwell.com",
        "Rocnel": "rocnel.com",
        "Saponificio Varesino": "saponificiovaresino.com",
        "Schick": "schick.com",
        "Semogue": "portuguesefactory.com",
        "Shavemac": "shavemac.com",
        "Simpson": "simpsonshavingbrushes.com",
        "Southern Witchcrafts": "southernwitchcrafts.com",
        "Speick": "speick.de",
        "Stirling Soap Co.": "stirlingsoap.com",
        "Summer Break Soaps": "summerbreaksoaps.com",
        "Tabac": "tabac-original.com",
        "Tatara": "tatararazors.com",
        "Taylor of Old Bond Street": "tayloroldbondst.co.uk",
        "Terry's Soap": "hwayeon.co.kr",
        "Thayers": "thayers.com",
        "The Goodfellas' Smile": "rasoigoodfellas.com",
        "The Razor Company": "therazorcompany.com",
        "Timeless": "timelessrazor.com",
        "Treet": "treetonline.com",
        "Truefitt & Hill": "truefittandhill.co.uk",
        "Turn-N-Shave": "turnnshave.com",
        "Wald": "waldshaving.com",
        "WestMan Shaving": "westmanshaving.com",
        "Wholly Kaw": "whollykaw.com",
        "Wickham": "w-soap.co.uk",
        "Wilkinson Sword": "wilkinsonsword.com",
        "Wolfman": "wolfmanrazors.com",
        "Yaqi": "yaqibrush.com",
        "Yates": "yatesprecision.com",
        "Zenith": "pennellificiopandolfo.com",
        "Zingari Man": "zingariman.com"
    ]

    /// 规范品牌与简称/别名到 `Resources/BrandLogos/<stem>.png` 的精确文件名映射
    nonisolated static let bundledLogoFileKeys: [String: String] = [
        "Declaration Grooming": "dg",
        "declaration_grooming": "dg",
        "dg": "dg",
        "Phoenix Artisan Accoutrements": "phoenix_artisan_accoutrements",
        "phoenix_artisan_accoutrements": "phoenix_artisan_accoutrements",
        "phoenix": "phoenix_artisan_accoutrements",
        "paa": "phoenix_artisan_accoutrements",
        "House of Mammoth": "house_of_mammoth",
        "house_of_mammoth": "house_of_mammoth",
        "mammoth": "house_of_mammoth",
        "hom": "house_of_mammoth",
        "Ethos Grooming": "ethos",
        "ethos_grooming": "ethos",
        "ethos_grooming_essentials": "ethos",
        "ethos": "ethos",
        "LAXO": "laxo",
        "aura_laxo": "laxo",
        "laxo": "laxo",
        "Turn-N-Shave": "tns",
        "turn_n_shave": "tns",
        "tns": "tns",
        "TwoFace Brothers": "twoface",
        "twoface_brothers": "twoface",
        "twoface": "twoface",
        "AKA": "aka",
        "aka_brushworx": "aka",
        "aka": "aka",
        "Clubman Pinaud": "clubman",
        "clubman_pinaud": "clubman",
        "clubman": "clubman",
        "Wolfman": "wolfman",
        "wolfman_razors": "wolfman",
        "wolfman": "wolfman",
        "Karve": "karve",
        "karve_shaving": "karve",
        "karve": "karve",
        "Lambda": "lambda",
        "lambda_razors": "lambda",
        "lambda": "lambda",
        "WestMan Shaving": "westman",
        "westman_shaving": "westman",
        "westman": "westman",
        "ROKYHOWS": "rokyhows",
        "rokyhows": "rokyhows",
        "Astra": "astra",
        "astra": "astra",
        "Wizamet": "wizamet",
        "wizamet": "wizamet",
        "Chisel & Hound": "chisel_and_hound",
        "chisel_and_hound": "chisel_and_hound"
    ]

    private nonisolated static let compactCanonicalLookup: [String: String] = {
        var table: [String: String] = [:]
        for name in brandDomains.keys {
            table[compactAlnum(name)] = name
        }
        for (alias, canonical) in brandAliases {
            table[compactAlnum(alias)] = canonical
            table[compactAlnum(canonical)] = canonical
        }
        return table
    }()

    /// 将品牌名（含简称/别名/联名 `A × B`）归一化为规范品牌名（不要求必须存在线上域名）
    nonisolated static func canonicalBrandName(for rawBrand: String) -> String? {
        let trimmed = rawBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shouldSkipBrand(trimmed) else { return nil }

        func directCanonical(_ candidate: String) -> String? {
            let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            if brandDomains[clean] != nil {
                return clean
            }
            if let aliasTarget = brandAliases[clean.lowercased()] {
                return aliasTarget
            }
            let compact = compactAlnum(clean)
            if !compact.isEmpty, let hit = compactCanonicalLookup[compact] {
                return hit
            }
            return nil
        }

        if let hit = directCanonical(trimmed) {
            return hit
        }
        let separators = ["×", " x ", " X ", " / ", "/"]
        for sep in separators where trimmed.contains(sep) {
            let parts = trimmed
                .components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts {
                if let hit = directCanonical(part) {
                    return hit
                }
            }
        }
        return nil
    }

    private nonisolated static let compactDomainLookup: [String: (canonical: String, domain: String)] = {
        var table: [String: (String, String)] = [:]
        for (name, domain) in brandDomains {
            table[compactAlnum(name)] = (name, domain)
        }
        for (alias, canonical) in brandAliases {
            if let domain = brandDomains[canonical] {
                table[compactAlnum(alias)] = (canonical, domain)
            }
        }
        return table
    }()

    private nonisolated static func compactAlnum(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// 跳过占位/仿刀品牌
    nonisolated static func shouldSkipBrand(_ brand: String) -> Bool {
        let lower = brand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.isEmpty || ["仿刀", "品牌未注明", "无品牌", "未知", "unknown", "none", "n/a", "无", "-"].contains(lower)
    }

    /// 将品牌名（含中英文别名与混搭名 `A × B`）解析至规范品牌与核实官网域名；未在白名单则返回 nil
    nonisolated static func resolveWhitelistedBrand(_ rawBrand: String) -> (canonical: String, domain: String)? {
        let trimmed = rawBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shouldSkipBrand(trimmed) else { return nil }

        func directMatch(_ candidate: String) -> (String, String)? {
            let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            if let domain = brandDomains[clean] {
                return (clean, domain)
            }
            let lower = clean.lowercased()
            if let aliasTarget = brandAliases[lower], let domain = brandDomains[aliasTarget] {
                return (aliasTarget, domain)
            }
            let compact = compactAlnum(clean)
            if !compact.isEmpty, let hit = compactDomainLookup[compact] {
                return hit
            }
            return nil
        }

        if let hit = directMatch(trimmed) {
            return hit
        }

        // 混搭/联名品牌 `A × B` / `A x B` / `A / B`：优先匹配主品牌 A，未命中再回退 B
        let separators = ["×", " x ", " X ", " / ", "/"]
        for sep in separators where trimmed.contains(sep) {
            let parts = trimmed
                .components(separatedBy: sep)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for part in parts {
                if let hit = directMatch(part) {
                    return hit
                }
            }
        }
        return nil
    }

    private convenience init() {
        let bundleDir = Bundle.main.resourceURL?.appendingPathComponent("BrandLogos", isDirectory: true)
        self.init(
            appSupportRoot: JournalRepository.defaultAppSupportDirectory(),
            bundledLogosDirectory: bundleDir
        )
    }

    init(appSupportRoot: URL, bundledLogosDirectory: URL?) {
        self.appSupportRoot = appSupportRoot
        self.cacheDirectory = appSupportRoot.appendingPathComponent("LogoCache", isDirectory: true)
        self.customDirectory = appSupportRoot.appendingPathComponent("CustomLogos", isDirectory: true)
        self.legacyDirectory = appSupportRoot.appendingPathComponent("BrandLogos", isDirectory: true)
        self.bundledLogosDirectory = bundledLogosDirectory
        self.cooldownFileURL = cacheDirectory.appendingPathComponent("failed_cooldown.json")
        if FileManager.default.fileExists(atPath: appSupportRoot.path) || !appSupportRoot.path.contains("/Library/CloudStorage/") {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        }
        rebuildCustomIndex()
        rebuildBundledIndex()
        loadFailedCooldowns()
    }

    private func rebuildCustomIndex() {
        var idx: [String: URL] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for f in files {
                let ext = f.pathExtension.lowercased()
                guard Self.supportedImageExtensions.contains(ext) else { continue }
                let rawStem = f.deletingPathExtension().lastPathComponent
                let key = rawStem.precomposedStringWithCanonicalMapping.lowercased()
                let ascii = Self.asciiBrandKey(rawStem)
                if !key.isEmpty { idx[key] = f }
                if !ascii.isEmpty { idx[ascii] = f }
            }
        }
        customIndex = idx
    }

    private func rebuildBundledIndex() {
        var idx: [String: URL] = [:]
        if let dir = bundledLogosDirectory,
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for f in files {
                let ext = f.pathExtension.lowercased()
                guard Self.supportedImageExtensions.contains(ext) else { continue }
                let rawStem = f.deletingPathExtension().lastPathComponent
                let key = rawStem.precomposedStringWithCanonicalMapping.lowercased()
                let ascii = Self.asciiBrandKey(rawStem)
                if !key.isEmpty { idx[key] = f }
                if !ascii.isEmpty { idx[ascii] = f }
            }
        }
        bundledIndex = idx
    }

    private func loadFailedCooldowns() {
        guard let data = try? Data(contentsOf: cooldownFileURL),
              let decoded = try? JSONDecoder().decode([String: TimeInterval].self, from: data) else {
            return
        }
        let now = Date().timeIntervalSince1970
        failedCooldowns = decoded.filter { now - $0.value < failedCooldownInterval }
    }

    private func saveFailedCooldowns() {
        let now = Date().timeIntervalSince1970
        let active = failedCooldowns.filter { now - $0.value < failedCooldownInterval }
        failedCooldowns = active
        if let data = try? JSONEncoder().encode(active) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cooldownFileURL, options: .atomic)
        }
    }

    private func isInCooldown(brandKey: String, domain: String?) -> Bool {
        let now = Date().timeIntervalSince1970
        if let ts = failedCooldowns["brand:\(brandKey)"], now - ts < failedCooldownInterval {
            return true
        }
        if let dom = domain?.lowercased(), let ts = failedCooldowns["domain:\(dom)"], now - ts < failedCooldownInterval {
            return true
        }
        return false
    }

    private func markFailedCooldown(brandKey: String, domain: String?) {
        let now = Date().timeIntervalSince1970
        failedCooldowns["brand:\(brandKey)"] = now
        if let dom = domain?.lowercased(), !dom.isEmpty {
            failedCooldowns["domain:\(dom)"] = now
        }
        saveFailedCooldowns()
    }

    private func candidateKeys(for brand: String) -> (keys: [String], resolved: (canonical: String, domain: String)?) {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawKey = Self.normalizedBrandKey(trimmed)
        let rawASCII = Self.asciiBrandKey(trimmed)
        let resolved = Self.resolveWhitelistedBrand(trimmed)
        let canonicalName = resolved?.canonical ?? Self.canonicalBrandName(for: trimmed)

        var keys: [String] = []
        func appendUnique(_ k: String?) {
            guard let k = k, !k.isEmpty, !keys.contains(k) else { return }
            keys.append(k)
        }
        appendUnique(rawKey)
        appendUnique(rawASCII)
        appendUnique(Self.bundledLogoFileKeys[trimmed])
        appendUnique(Self.bundledLogoFileKeys[rawASCII])
        if let canon = canonicalName {
            let canonKey = Self.normalizedBrandKey(canon)
            let canonASCII = Self.asciiBrandKey(canon)
            appendUnique(Self.bundledLogoFileKeys[canon])
            appendUnique(Self.bundledLogoFileKeys[canonASCII])
            appendUnique(canonKey)
            appendUnique(canonASCII)
        }
        return (keys, resolved)
    }

    private func loadLocalFileImage(at url: URL) -> NSImage? {
        let cacheKey = url.standardizedFileURL.path
        if let cached = localImageCache[cacheKey] {
            return cached
        }
        guard let data = try? Data(contentsOf: url),
              let img = NSImage(data: data) else {
            return nil
        }
        localImageCache[cacheKey] = img
        return img
    }

    private func resolveCustomLogoURL(for keys: [String]) -> URL? {
        for k in keys {
            if let hit = customIndex[k], FileManager.default.fileExists(atPath: hit.path) {
                return hit
            }
        }
        return nil
    }

    private func resolveBundledLogoURL(for keys: [String]) -> URL? {
        for k in keys {
            if let hit = bundledIndex[k], FileManager.default.fileExists(atPath: hit.path) {
                return hit
            }
        }
        return nil
    }

    private func resolveDiskCacheLogoURL(for keys: [String]) -> URL? {
        for k in keys {
            let candidate = cacheDirectory.appendingPathComponent("\(k).png")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 统一 Logo 读取优先级：CustomLogos/ > BrandLogos/（内置精选图包） > LogoCache/（联网缓存） > nil（字母兜底）
    func logoImage(for brand: String) -> NSImage? {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.shouldSkipBrand(trimmed) else { return nil }

        let (keys, _) = candidateKeys(for: trimmed)

        // Tier 0: 用户手动上传的永久图标（CustomLogos/）
        if let customURL = resolveCustomLogoURL(for: keys),
           let img = loadLocalFileImage(at: customURL) {
            return img
        }

        // Tier 1: App 内置精选图包（BrandLogos/，离线秒开）
        if let bundledURL = resolveBundledLogoURL(for: keys),
           let img = loadLocalFileImage(at: bundledURL) {
            return img
        }

        // Tier 2: 已加载至内存的联网缓存（LogoCache/）
        for k in keys {
            if let hit = images[k] {
                return hit
            }
        }

        // 同步兜底读取已存在的磁盘 LogoCache/，避免切换视图或列表滚动时闪回字母圈
        if let cachedURL = resolveDiskCacheLogoURL(for: keys),
           let img = loadLocalFileImage(at: cachedURL),
           Self.isValidIcon(img, minDimension: 16) {
            return img
        }

        return nil
    }

    /// 检测深色模式下是否需要反相（仅针对透明底纯黑/深灰单色字标与线条徽章，彩标与实底标绝不反转）
    func shouldInvertInDarkMode(image: NSImage) -> Bool {
        let oid = ObjectIdentifier(image)
        if let cached = darkInvertCache[oid] {
            return cached
        }
        let result = Self.computeMonochromeTransparencyKind(image) == .dark
        darkInvertCache[oid] = result
        return result
    }

    /// 检测浅色模式下是否需要反相（仅针对透明底纯白单色线稿标如 House of Mammoth，确保浅色卡片下清晰可见）
    func shouldInvertInLightMode(image: NSImage) -> Bool {
        let oid = ObjectIdentifier(image)
        if let cached = lightInvertCache[oid] {
            return cached
        }
        let result = Self.computeMonochromeTransparencyKind(image) == .light
        lightInvertCache[oid] = result
        return result
    }

    private enum TransparentMonochromeKind {
        case none
        case dark
        case light
    }

    private nonisolated static func computeMonochromeTransparencyKind(_ img: NSImage) -> TransparentMonochromeKind {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return .none
        }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 0, h > 0 else { return .none }

        let stepX = max(1, w / 24)
        let stepY = max(1, h / 24)
        var transparentCount = 0
        var opaqueCount = 0
        var darkNeutralCount = 0
        var lightNeutralCount = 0

        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.alphaComponent < 0.12 {
                    transparentCount += 1
                } else {
                    opaqueCount += 1
                    let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
                    let chroma = max(
                        abs(c.redComponent - c.greenComponent),
                        abs(c.greenComponent - c.blueComponent),
                        abs(c.redComponent - c.blueComponent)
                    )
                    if lum < 0.30 && chroma < 0.12 {
                        darkNeutralCount += 1
                    } else if lum > 0.85 && chroma < 0.12 {
                        lightNeutralCount += 1
                    }
                }
            }
        }

        let total = transparentCount + opaqueCount
        guard total > 0, opaqueCount > 0 else { return .none }
        let transparentRatio = Double(transparentCount) / Double(total)
        guard transparentRatio >= 0.10 else { return .none }
        if Double(darkNeutralCount) / Double(opaqueCount) >= 0.85 {
            return .dark
        }
        if Double(lightNeutralCount) / Double(opaqueCount) >= 0.85 {
            return .light
        }
        return .none
    }

    /// 判断该品牌当前是否已有任意可用图标（CustomLogos / 内置 BrandLogos / LogoCache）
    func hasAnyLogo(for brand: String) -> Bool {
        logoImage(for: brand) != nil
    }

    /// 用户手动选择本地图片设为该品牌的永久 Logo（自动去边规范化为 256px PNG）
    func setCustomLogo(from fileURL: URL, for brand: String) -> Bool {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let img = NSImage(contentsOf: fileURL) else {
            return false
        }
        if let normalized = BrandLogoImageProcessor.normalizeLogo(img, trimMode: .transparentOnly, maxLongEdge: 256) {
            return setCustomLogoData(normalized.pngData, for: trimmed)
        }
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        return setCustomLogoData(png, for: trimmed)
    }

    /// 直接将已规范化的 PNG 数据写入 CustomLogos/ 作为该品牌的永久图标（最高优先级，自动触发云盘同步）
    func setCustomLogoData(_ pngData: Data, for brand: String) -> Bool {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let img = NSImage(data: pngData) else {
            return false
        }
        let key = Self.asciiBrandKey(trimmed)
        let rawKey = Self.normalizedBrandKey(trimmed)
        let canonKey = Self.canonicalBrandName(for: trimmed).map { Self.asciiBrandKey($0) }
        let dst = customDirectory.appendingPathComponent("\(key).png")
        do {
            try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            if let existing = try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for file in existing {
                    let stem = Self.asciiBrandKey(file.deletingPathExtension().lastPathComponent)
                    if stem == key && file.standardizedFileURL != dst.standardizedFileURL {
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            }
            try JournalRepository.atomicWriteData(pngData, to: dst)
            localImageCache.removeValue(forKey: dst.standardizedFileURL.path)
            rebuildCustomIndex()
            images[key] = img
            if rawKey != key { images[rawKey] = img }
            if let ck = canonKey, ck != key { images[ck] = img }
            failedCooldowns.removeValue(forKey: "brand:\(key)")
            failedCooldowns.removeValue(forKey: "brand:\(rawKey)")
            if let ck = canonKey { failedCooldowns.removeValue(forKey: "brand:\(ck)") }
            saveFailedCooldowns()
            cacheRevision += 1
            NotificationCenter.default.post(name: Self.customLogoDidChangeNotification, object: key)
            return true
        } catch {
            return false
        }
    }

    /// 重新扫描 CustomLogos/ 目录（供云盘同步拉取新图标后即时刷新 UI）
    func reloadCustomLogos() {
        localImageCache.removeAll()
        rebuildCustomIndex()
        for (key, url) in customIndex {
            if let img = loadLocalFileImage(at: url) {
                images[key] = img
                failedCooldowns.removeValue(forKey: "brand:\(key)")
            }
        }
        cacheRevision += 1
    }

    /// 彻底清理自动抓取缓存（LogoCache/、failed_cooldown.json 与旧版用户 BrandLogos/），完整保留 CustomLogos/ 与 App 内置精选图包
    func clearAutoCacheAndRefetch() {
        try? FileManager.default.removeItem(at: cooldownFileURL)
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.removeItem(at: legacyDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        fetchGeneration += 1
        activeFetchCount = 0
        inFlight.removeAll()
        queuedKeys.removeAll()
        pendingQueue.removeAll()
        failedCooldowns.removeAll()
        localImageCache.removeAll()
        darkInvertCache.removeAll()
        lightInvertCache.removeAll()
        images.removeAll()

        rebuildCustomIndex()
        cacheRevision += 1
    }

    func requestLogoIfNeeded(for brand: String, category: GearCategory? = nil) {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.shouldSkipBrand(trimmed) else { return }

        let (keys, resolved) = candidateKeys(for: trimmed)

        // Tier 0 (CustomLogos/) 与 Tier 1 (App 内置 BrandLogos/) 直接离线命中，无需联网
        if resolveCustomLogoURL(for: keys) != nil { return }
        if resolveBundledLogoURL(for: keys) != nil { return }

        // 不在核实官网白名单的品牌严禁瞎猜域名，直接走干净首字圆形徽章
        guard let whitelisted = resolved else { return }

        let key = Self.normalizedBrandKey(trimmed)
        let canonicalKey = Self.normalizedBrandKey(whitelisted.canonical)
        let canonicalASCIIKey = Self.asciiBrandKey(whitelisted.canonical)

        if keys.contains(where: { images[$0] != nil }) { return }
        if inFlight.contains(canonicalASCIIKey) || queuedKeys.contains(canonicalASCIIKey) {
            return
        }

        // Tier 2: 检查本地联网缓存 LogoCache/
        if let cachedURL = resolveDiskCacheLogoURL(for: keys),
           let img = loadLocalFileImage(at: cachedURL),
           Self.isValidIcon(img, minDimension: 16) {
            for k in keys { images[k] = img }
            return
        }

        if isInCooldown(brandKey: canonicalASCIIKey, domain: whitelisted.domain) { return }

        let diskURL = cacheDirectory.appendingPathComponent("\(canonicalASCIIKey).png")
        queuedKeys.insert(canonicalASCIIKey)
        pendingQueue.append(PendingFetchRequest(
            key: key,
            canonicalKey: canonicalKey,
            canonicalASCIIKey: canonicalASCIIKey,
            brand: whitelisted.canonical,
            knownDomain: whitelisted.domain,
            diskURL: diskURL
        ))
        pumpFetchQueue()
    }

    private func pumpFetchQueue() {
        while activeFetchCount < maxConcurrentFetches, !pendingQueue.isEmpty {
            let req = pendingQueue.removeFirst()
            queuedKeys.remove(req.canonicalASCIIKey)
            guard images[req.canonicalASCIIKey] == nil,
                  !inFlight.contains(req.canonicalASCIIKey),
                  !isInCooldown(brandKey: req.canonicalASCIIKey, domain: req.knownDomain) else {
                continue
            }

            inFlight.insert(req.canonicalASCIIKey)
            activeFetchCount += 1
            let generation = fetchGeneration

            Task.detached(priority: .utility) { [req, generation] in
                let data = await Self.fetchWhitelistedDomainIcon(domain: req.knownDomain, session: Self.sharedSession)
                await MainActor.run {
                    guard self.fetchGeneration == generation else { return }
                    self.inFlight.remove(req.canonicalASCIIKey)
                    self.activeFetchCount = max(0, self.activeFetchCount - 1)

                    if let data = data, let img = NSImage(data: data), Self.isValidIcon(img, minDimension: 16) {
                        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
                        try? data.write(to: req.diskURL, options: .atomic)
                        self.localImageCache[req.diskURL.standardizedFileURL.path] = img
                        self.images[req.canonicalASCIIKey] = img
                        self.images[req.canonicalKey] = img
                        self.images[req.key] = img
                        self.cacheRevision += 1
                    } else {
                        self.markFailedCooldown(brandKey: req.canonicalASCIIKey, domain: req.knownDomain)
                    }
                    self.pumpFetchQueue()
                }
            }
        }
    }

    nonisolated static func normalizedBrandKey(_ brand: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return brand.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }

    nonisolated static func asciiBrandKey(_ brand: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return brand.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }

    nonisolated static func isBlacklistedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if exactBlacklistedHosts.contains(h) {
            return true
        }
        // Shopify 官方静态图 CDN（cdn.shopify.com）承载众多独立湿剃品牌官网图标，明确放行
        if h == "cdn.shopify.com" || h.hasSuffix(".shopifycdn.com") {
            return false
        }
        for bad in blacklistedDomains {
            if bad.hasSuffix(".") {
                if h.contains(bad) { return true }
            } else if h == bad || h.hasSuffix(".\(bad)") {
                return true
            }
        }
        return false
    }

    private nonisolated static func isValidIcon(_ img: NSImage, minDimension: Int = 16) -> Bool {
        let maxW = img.representations.map(\.pixelsWide).max() ?? Int(img.size.width)
        let maxH = img.representations.map(\.pixelsHigh).max() ?? Int(img.size.height)
        return maxW >= minDimension && maxH >= minDimension
    }

    /// 高命中白名单官网抓图链路：
    /// 1) 直读 /apple-touch-icon.png
    /// 2) 解析首页 HTML（apple-touch-icon → 高清 icon → og:image，不盲抓正文/媒体徽章 <img>）
    /// 3) 直读 /favicon.ico
    /// 4) 稳定回退 Google Favicon 代理（sz=128，仅过滤 16×16 默认灰地球占位图，不误杀黑白单色标）
    private nonisolated static func fetchWhitelistedDomainIcon(domain: String, session: URLSession) async -> Data? {
        let raw = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURLStr = (raw.hasPrefix("http://") || raw.hasPrefix("https://")) ? raw : "https://\(raw)"
        guard let parsed = URL(string: normalizedURLStr),
              let host = parsed.host?.lowercased(),
              !host.isEmpty,
              !isBlacklistedHost(host) else {
            return nil
        }
        let scheme = parsed.scheme?.lowercased() ?? "https"
        let pathSuffix = parsed.path.isEmpty ? "" : parsed.path
        let wwwHost = host.hasPrefix("www.") ? host : "www.\(host)"

        // 1) 优先直读根目录 /apple-touch-icon.png（最快、最清晰且不会抓到媒体背书图）
        for h in Array(Set([host, wwwHost])) {
            if let data = await downloadValidImage(urlStr: "\(scheme)://\(h)/apple-touch-icon.png", session: session, checkHostBlacklist: true, minDimension: 24) {
                return data
            }
        }

        // 2) 解析官网首页 HTML 的页头 Logo / JSON-LD / apple-touch-icon / icon / og:image
        let homeCandidates = host == wwwHost
            ? ["\(scheme)://\(host)\(pathSuffix)"]
            : ["\(scheme)://\(host)\(pathSuffix)", "\(scheme)://\(wwwHost)\(pathSuffix)"]
        for homeStr in homeCandidates {
            guard let homeURL = URL(string: homeStr),
                  let (htmlData, resp) = try? await session.data(from: homeURL),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let finalHost = resp.url?.host,
                  !isBlacklistedHost(finalHost) else {
                continue
            }
            let sample = String(data: htmlData.prefix(320_000), encoding: .utf8)
                ?? String(data: htmlData.prefix(320_000), encoding: .isoLatin1)
                ?? ""
            let candidates = AILogoFinderService.extractSmartHTMLCandidates(html: sample, baseURL: resp.url ?? homeURL)
            for candidate in candidates {
                if let data = await downloadValidImage(urlStr: candidate.url, session: session, checkHostBlacklist: true, minDimension: 20) {
                    return data
                }
            }
        }

        // 3) 尝试根目录 /favicon.ico
        for h in Array(Set([host, wwwHost])) {
            if let data = await downloadValidImage(urlStr: "\(scheme)://\(h)/favicon.ico", session: session, checkHostBlacklist: true, minDimension: 16) {
                return data
            }
        }

        // 4) 稳定回退 Google Favicon（sz=128）；Google 无图标时仅返回 16×16 默认灰地球，>=24px 即真实品牌图标
        let s2 = "https://www.google.com/s2/favicons?domain=\(host)&sz=128"
        if let data = await downloadValidImage(urlStr: s2, session: session, checkHostBlacklist: false, minDimension: 24) {
            return data
        }

        return nil
    }

    private nonisolated static func extractHTMLIconURLs(html: String, baseURL: URL) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []

        func appendURL(_ raw: String) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            guard !cleaned.isEmpty,
                  !cleaned.hasPrefix("data:"),
                  !cleaned.hasPrefix("javascript:"),
                  let resolved = URL(string: cleaned, relativeTo: baseURL)?.absoluteString,
                  !seen.contains(resolved) else {
                return
            }
            // NSImage(data:) 不支持直接解码 .svg，跳过避免浪费请求
            if let pathExt = URL(string: resolved)?.pathExtension.lowercased(), pathExt == "svg" {
                return
            }
            if let host = URL(string: resolved)?.host, isBlacklistedHost(host) {
                return
            }
            seen.insert(resolved)
            found.append(resolved)
        }

        // 1) apple-touch-icon 优先，其次各类 rel="icon"
        let linkPatterns = [
            #"(?i)<link[^>]+rel=["'][^"']*apple-touch-icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*apple-touch-icon[^"']*["']"#,
            #"(?i)<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*icon[^"']*["']"#
        ]
        for pat in linkPatterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for m in matches.prefix(5) {
                    if let r = Range(m.range(at: 1), in: html) {
                        appendURL(String(html[r]))
                    }
                }
            }
        }

        // 2) og:image 作为高质量兜底
        if let og = extractMetaContent(html: html, property: "og:image") {
            appendURL(og)
        }

        return Array(found.prefix(10))
    }

    private nonisolated static func extractMetaContent(html: String, property: String) -> String? {
        let patterns = [
            #"(?i)<meta[^>]+property=["']"# + property + #"["'][^>]+content=["']([^"']+)["']"#,
            #"(?i)<meta[^>]+content=["']([^"']+)["'][^>]+property=["']"# + property + #"["']"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                return String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
            }
        }
        return nil
    }

    private nonisolated static func downloadValidImage(
        urlStr: String,
        session: URLSession,
        checkHostBlacklist: Bool,
        minDimension: Int
    ) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        if checkHostBlacklist, let host = url.host, isBlacklistedHost(host) {
            return nil
        }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count > 100,
              data.count <= 6 * 1024 * 1024 else {
            return nil
        }
        if checkHostBlacklist, let finalHost = resp.url?.host, isBlacklistedHost(finalHost) {
            return nil
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           ct.contains("text/html") || ct.contains("application/xhtml") || ct.contains("image/svg") {
            return nil
        }
        guard let img = NSImage(data: data),
              isValidIcon(img, minDimension: minDimension),
              !BrandLogoImageProcessor.isBlankOrUniform(img),
              !BrandLogoImageProcessor.isSuspiciousAspectRatio(img) else {
            return nil
        }
        if let normalized = BrandLogoImageProcessor.normalizeLogo(img, trimMode: .auto, maxLongEdge: 256) {
            return normalized.pngData
        }
        return data
    }

    static func monogram(for brand: String) -> String {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "品牌未注明" || trimmed == "无品牌" { return "?" }
        if trimmed == "仿刀" { return "仿" }

        if let first = trimmed.first {
            if first.unicodeScalars.contains(where: { $0.value > 0x2E80 }) {
                return String(first)
            }
        }

        let words = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count >= 2 {
            return words[0].prefix(1).uppercased() + words[1].prefix(1).uppercased()
        }
        if let only = words.first {
            return only.count <= 2 ? only.uppercased() : String(only.prefix(1)).uppercased()
        }
        return String(trimmed.prefix(1)).uppercased()
    }
}

/// 品牌 Logo 视图（v1.4.2 原形保真版）：
/// - 有真实品牌图片时彻底移除圆形裁切与多余边框，按 `.resizable().scaledToFit()` 保留圆标/方标/横标/透明字标原始轮廓
/// - 仅无图品牌保留极简首字母/中文首字圆形徽章兜底
struct BrandAvatarView: View {
    @ObservedObject private var cache = BrandLogoCache.shared
    @Environment(\.colorScheme) private var scheme

    let brand: String
    /// 目标高度（圆标/方标保持 1:1，横标按 maxWidth 自适应舒展）
    var size: CGFloat = 24
    /// 横标允许的最大宽度（未指定时默认 size * 1.45）
    var maxWidth: CGFloat? = nil
    var category: GearCategory? = nil
    var alignment: Alignment = .center

    private var effectiveMaxWidth: CGFloat {
        max(size, maxWidth ?? (size * 1.45))
    }

    var body: some View {
        let _ = cache.cacheRevision
        Group {
            if let img = cache.logoImage(for: brand) {
                let shouldInvert = (scheme == .dark && cache.shouldInvertInDarkMode(image: img))
                    || (scheme == .light && cache.shouldInvertInLightMode(image: img))
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .modifier(ConditionalColorInvert(isEnabled: shouldInvert))
                    .frame(maxWidth: effectiveMaxWidth, maxHeight: size, alignment: alignment)
                    .frame(minHeight: size, alignment: alignment)
            } else {
                let bg = ShaveTheme.brandColor(for: brand)
                let letters = BrandLogoCache.monogram(for: brand)
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [bg.opacity(0.86), bg],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text(letters)
                        .font(.system(
                            size: letters.count >= 2 ? size * 0.39 : size * 0.46,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color.white)
                }
                .frame(width: size, height: size)
            }
        }
        .onAppear {
            cache.requestLogoIfNeeded(for: brand, category: category)
        }
        .onChange(of: cache.cacheRevision) { _, _ in
            cache.requestLogoIfNeeded(for: brand, category: category)
        }
    }
}

private struct ConditionalColorInvert: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.colorInvert()
        } else {
            content
        }
    }
}
