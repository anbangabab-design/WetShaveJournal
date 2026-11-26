import SwiftUI
import AppKit

/// 品牌 Logo 检索与本地缓存服务（v1.4.1 白名单治本版）：
/// 0) 用户自定义永久品牌图标（CustomLogos/，最高优先级，永不被清理或覆盖）
/// 1) 品牌别名归一化 + 混搭名 `A × B` 主品牌提取 → 核实官方独立域名白名单
///    严禁对未知品牌瞎猜 `<品牌>.com` 或盲搜第三方站点；不在白名单的小众/国内手工/仿刀默认展示干净首字圆形徽章
/// 2) 白名单官网抓取链路：apple-touch-icon → 高清 icon → og:image → 页面头部 Logo；
///    被 Cloudflare 拦截时自动回退至 Google Favicon 代理（sz=128）并过滤默认灰地球占位图
/// 3) 清理并重抓时彻底清空旧 LogoCache/ 与 failed_cooldown.json（保留 CustomLogos/）
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
    private let cacheDirectory: URL      // 自动抓取缓存：LogoCache/
    private let customDirectory: URL     // 用户手动上传：CustomLogos/
    private let legacyDirectory: URL     // 旧版目录：BrandLogos/
    private let cooldownFileURL: URL     // 失败冷却缓存：LogoCache/failed_cooldown.json

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

    /// 严格禁止作为品牌 Logo 来源的平台域名黑名单
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
        "shopify.com",
        "wixsite.com",
        "blogspot.",
        "wordpress.com"
    ]

    /// 品牌中英文/简称/子线别名归一化表（小写精确与去符号匹配均支持）
    nonisolated static let brandAliases: [String: String] = [
        "华研": "Terry's Soap",
        "华研手工皂": "Terry's Soap",
        "hwayeon": "Terry's Soap",
        "hwayeon soap": "Terry's Soap",
        "hwayeon soap co": "Terry's Soap",
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
        "雅琪": "Yaqi",
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
        "att": "Above The Tie",
        "above the tie": "Above The Tie",
        "ad": "Atelier Durdan",
        "atelier durdan": "Atelier Durdan",
        "alpha": "Alpha",
        "alpha shaving": "Alpha",
        "b&m": "Barrister and Mann",
        "barrister & mann": "Barrister and Mann",
        "barrister and mann": "Barrister and Mann",
        "blackland": "Blackland",
        "blackland razors": "Blackland",
        "黑鸟": "Blackland",
        "colonial": "Colonial",
        "colonial razors": "Colonial",
        "ethos": "Ethos Grooming",
        "ethos grooming": "Ethos Grooming",
        "fine": "Fine Accoutrements",
        "fine accoutrements": "Fine Accoutrements",
        "fs": "Frank Shaving",
        "frank shaving": "Frank Shaving",
        "feather": "Feather",
        "羽毛": "Feather",
        "gillette": "Gillette",
        "吉列": "Gillette",
        "henson": "Henson",
        "henson shaving": "Henson",
        "hls": "HLS",
        "homelike": "HLS",
        "homelike shaving": "HLS",
        "kai": "Kai",
        "贝印": "Kai",
        "lpl": "Le Père Lucien",
        "le pere lucien": "Le Père Lucien",
        "macduff": "MacDuffs Soap Company",
        "macduffs": "MacDuffs Soap Company",
        "maggard": "Maggard",
        "maggard razors": "Maggard",
        "mdc": "Martin de Candre",
        "martin de candre": "Martin de Candre",
        "muhle": "Mühle",
        "mühle": "Mühle",
        "穆乐": "Mühle",
        "merkur": "Merkur",
        "默克尔": "Merkur",
        "mwf": "Mitchell's Wool Fat",
        "noble otter": "Noble Otter",
        "水獭": "Noble Otter",
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
        "sv": "Saponificio Varesino",
        "sv1945": "Saponificio Varesino",
        "saponificio varesino": "Saponificio Varesino",
        "schick": "Schick",
        "舒适": "Schick",
        "simpson": "Simpson",
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
        "wilkinson": "Wilkinson Sword",
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
        "Alpha": "alphashaving.com",
        "Amonatura": "amonatura.com",
        "AP Shave Co": "apshaveco.com",
        "Ariana & Evans": "aegrooming.com",
        "Arko": "arkomen.com",
        "Arno": "arnobrush.com",
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
        "Clubman Pinaud": "clubmanonline.com",
        "Colonial": "colonialrazors.com",
        "D.R. Harris": "drharris.co.uk",
        "Declaration Grooming": "declarationgrooming.com",
        "Derby": "derbyrazorblades.com",
        "Dorco": "dorcousa.com",
        "DSCosmetic": "dscosmetic.com",
        "Edwin Jagger": "edwinjagger.com",
        "Elysian Soap Shop": "elysiansoapshop.com",
        "Ethos Grooming": "ethosgroomingessentials.com",
        "Fatip": "fatip.it",
        "Feather": "feather.co.jp",
        "Fine Accoutrements": "fineaccoutrements.com",
        "Frank Shaving": "frankshaving.com",
        "Geo. F. Trumper": "trumpers.com",
        "Gillette": "gillette.com",
        "Grooming Dept": "groomingdept.com",
        "HAGS": "haveagreatshave.com",
        "Haslinger": "haslingerseifen.at",
        "Henson": "hensonshaving.com",
        "HLS": "homelikeshaving.ru",
        "House of Mammoth": "houseofmammoth.com",
        "Kai": "kai-group.com",
        "Karve": "karveshaving.com",
        "L'Occitane": "loccitane.com",
        "Lambda": "lambdarazors.com",
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
        "Yaqi": "yaqishaving.com",
        "Yates": "yatesprecision.com",
        "Zenith": "pennellificiopandolfo.com",
        "Zingari Man": "zingariman.com"
    ]

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
            .lowercased()
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

    private init() {
        self.appSupportRoot = JournalRepository.defaultAppSupportDirectory()
        self.cacheDirectory = appSupportRoot.appendingPathComponent("LogoCache", isDirectory: true)
        self.customDirectory = appSupportRoot.appendingPathComponent("CustomLogos", isDirectory: true)
        self.legacyDirectory = appSupportRoot.appendingPathComponent("BrandLogos", isDirectory: true)
        self.cooldownFileURL = cacheDirectory.appendingPathComponent("failed_cooldown.json")
        if FileManager.default.fileExists(atPath: appSupportRoot.path) || !appSupportRoot.path.contains("/Library/CloudStorage/") {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        }
        loadFailedCooldowns()
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

    func logoImage(for brand: String) -> NSImage? {
        let key = normalizedBrandKey(brand)
        if let exact = images[key] {
            return exact
        }
        if let resolved = Self.resolveWhitelistedBrand(brand) {
            let canonKey = normalizedBrandKey(resolved.canonical)
            if let hit = images[canonKey] {
                return hit
            }
        }
        return nil
    }

    /// 用户手动选择本地图片设为该品牌的永久 Logo
    func setCustomLogo(from fileURL: URL, for brand: String) -> Bool {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let img = NSImage(contentsOf: fileURL),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        let key = normalizedBrandKey(trimmed)
        let dst = customDirectory.appendingPathComponent("\(key).png")
        do {
            try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
            if let existing = try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for file in existing where file.deletingPathExtension().lastPathComponent.lowercased() == key && file.standardizedFileURL != dst.standardizedFileURL {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            try JournalRepository.atomicWriteData(png, to: dst)
            images[key] = img
            failedCooldowns.removeValue(forKey: "brand:\(key)")
            saveFailedCooldowns()
            cacheRevision += 1
            NotificationCenter.default.post(name: Self.customLogoDidChangeNotification, object: key)
            return true
        } catch {
            return false
        }
    }

    /// 重新扫描 CustomLogos/ 目录（供云盘双端同步拉取新图标后即时刷新 UI）
    func reloadCustomLogos() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return
        }
        var didUpdate = false
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard Self.supportedImageExtensions.contains(ext) else { continue }
            let key = f.deletingPathExtension().lastPathComponent.lowercased()
            guard !key.isEmpty else { continue }
            if let data = try? Data(contentsOf: f), let img = NSImage(data: data) {
                images[key] = img
                failedCooldowns.removeValue(forKey: "brand:\(key)")
                didUpdate = true
            }
        }
        if didUpdate {
            cacheRevision += 1
        }
    }

    private func findCustomLogoFile(forKey key: String) -> URL? {
        let pngURL = customDirectory.appendingPathComponent("\(key).png")
        if FileManager.default.fileExists(atPath: pngURL.path) {
            return pngURL
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return nil
        }
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard Self.supportedImageExtensions.contains(ext) else { continue }
            if file.deletingPathExtension().lastPathComponent.lowercased() == key {
                return file
            }
        }
        return nil
    }

    /// 彻底清理自动抓取缓存（LogoCache/、failed_cooldown.json 与旧版 BrandLogos/），完整保留 CustomLogos/
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

        var retained: [String: NSImage] = [:]
        if let files = try? FileManager.default.contentsOfDirectory(at: customDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for f in files where Self.supportedImageExtensions.contains(f.pathExtension.lowercased()) {
                let key = f.deletingPathExtension().lastPathComponent.lowercased()
                if let data = try? Data(contentsOf: f), let img = NSImage(data: data) {
                    retained[key] = img
                }
            }
        }
        images = retained
        cacheRevision += 1
    }

    func requestLogoIfNeeded(for brand: String, category: GearCategory? = nil) {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.shouldSkipBrand(trimmed) else { return }

        let key = normalizedBrandKey(trimmed)
        let resolved = Self.resolveWhitelistedBrand(trimmed)
        let canonicalKey = resolved.map { normalizedBrandKey($0.canonical) } ?? key

        if images[key] != nil || images[canonicalKey] != nil { return }
        if inFlight.contains(key) || queuedKeys.contains(key) || inFlight.contains(canonicalKey) || queuedKeys.contains(canonicalKey) {
            return
        }

        // Tier 0: 优先加载用户自定义永久图标（依次检查原始 key 与规范别名 key）
        for customKey in [key, canonicalKey] {
            if let customURL = findCustomLogoFile(forKey: customKey),
               let data = try? Data(contentsOf: customURL),
               let img = NSImage(data: data) {
                images[key] = img
                if canonicalKey != key { images[canonicalKey] = img }
                return
            }
        }

        // 不在核实官网白名单的品牌严禁瞎猜域名，直接走干净首字圆形徽章
        guard let whitelisted = resolved else { return }

        // 检查本地自动缓存 LogoCache/（兼容原 key 与规范别名 key）
        for cacheKey in [key, canonicalKey] {
            let cachedURL = cacheDirectory.appendingPathComponent("\(cacheKey).png")
            if FileManager.default.fileExists(atPath: cachedURL.path),
               let data = try? Data(contentsOf: cachedURL),
               let img = NSImage(data: data),
               Self.isValidIcon(img, minDimension: 24) {
                images[key] = img
                if canonicalKey != key { images[canonicalKey] = img }
                return
            }
        }

        if isInCooldown(brandKey: canonicalKey, domain: whitelisted.domain) { return }

        let diskURL = cacheDirectory.appendingPathComponent("\(canonicalKey).png")
        queuedKeys.insert(canonicalKey)
        pendingQueue.append(PendingFetchRequest(
            key: key,
            canonicalKey: canonicalKey,
            brand: whitelisted.canonical,
            knownDomain: whitelisted.domain,
            diskURL: diskURL
        ))
        pumpFetchQueue()
    }

    private func pumpFetchQueue() {
        while activeFetchCount < maxConcurrentFetches, !pendingQueue.isEmpty {
            let req = pendingQueue.removeFirst()
            queuedKeys.remove(req.canonicalKey)
            guard images[req.canonicalKey] == nil,
                  !inFlight.contains(req.canonicalKey),
                  !isInCooldown(brandKey: req.canonicalKey, domain: req.knownDomain) else {
                continue
            }

            inFlight.insert(req.canonicalKey)
            activeFetchCount += 1
            let generation = fetchGeneration

            Task.detached(priority: .utility) { [req, generation] in
                let data = await Self.fetchWhitelistedDomainIcon(domain: req.knownDomain, session: Self.sharedSession)
                await MainActor.run {
                    guard self.fetchGeneration == generation else { return }
                    self.inFlight.remove(req.canonicalKey)
                    self.activeFetchCount = max(0, self.activeFetchCount - 1)

                    if let data = data, let img = NSImage(data: data), Self.isValidIcon(img, minDimension: 24) {
                        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
                        try? data.write(to: req.diskURL, options: .atomic)
                        self.images[req.canonicalKey] = img
                        self.images[req.key] = img
                    } else {
                        self.markFailedCooldown(brandKey: req.canonicalKey, domain: req.knownDomain)
                    }
                    self.pumpFetchQueue()
                }
            }
        }
    }

    private func normalizedBrandKey(_ brand: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return brand.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()
    }

    private nonisolated static func isBlacklistedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        for bad in blacklistedDomains {
            if bad.hasSuffix(".") {
                if h.contains(bad) { return true }
            } else if h == bad || h.hasSuffix(".\(bad)") {
                return true
            }
        }
        return false
    }

    private nonisolated static func isValidIcon(_ img: NSImage, minDimension: Int = 24) -> Bool {
        let maxW = img.representations.map(\.pixelsWide).max() ?? Int(img.size.width)
        let maxH = img.representations.map(\.pixelsHigh).max() ?? Int(img.size.height)
        return maxW >= minDimension && maxH >= minDimension
    }

    /// 检测 Google S2 返回的默认灰地球占位图（尺寸 < 32 或低色差纯灰默认球）
    private nonisolated static func isLikelyDefaultGrayGlobe(_ img: NSImage, rawByteCount: Int) -> Bool {
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return true
        }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        // Google S2 无图标时固定返回 16×16 默认灰地球（即使请求 sz=128）
        if w < 32 || h < 32 {
            return true
        }
        // 进一步抽样过滤极低体积的纯灰默认占位图标
        if rawByteCount < 900 {
            var coloredPixels = 0
            var visiblePixels = 0
            let step = max(1, min(w, h) / 16)
            for y in stride(from: 0, to: h, by: step) {
                for x in stride(from: 0, to: w, by: step) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if c.alphaComponent < 0.15 { continue }
                    visiblePixels += 1
                    let chroma = max(abs(c.redComponent - c.greenComponent),
                                     abs(c.greenComponent - c.blueComponent),
                                     abs(c.redComponent - c.blueComponent))
                    if chroma > 0.08 {
                        coloredPixels += 1
                    }
                }
            }
            if visiblePixels == 0 || (coloredPixels == 0 && rawByteCount < 550) {
                return true
            }
        }
        return false
    }

    private nonisolated static func isCloudflareChallenge(http: HTTPURLResponse, html: String) -> Bool {
        if let cfMitigated = http.value(forHTTPHeaderField: "cf-mitigated"), !cfMitigated.isEmpty {
            return true
        }
        if http.statusCode == 403 || http.statusCode == 503 {
            let lower = html.lowercased()
            if lower.contains("cloudflare") || lower.contains("just a moment") || lower.contains("_cf_chl_opt") || lower.contains("cf-browser-verification") {
                return true
            }
        }
        return false
    }

    /// 白名单官网抓图链路：apple-touch-icon → 高清 icon → og:image → 页面头部 Logo → Cloudflare/失败回退 Google Favicon (sz=128)
    private nonisolated static func fetchWhitelistedDomainIcon(domain: String, session: URLSession) async -> Data? {
        guard !isBlacklistedHost(domain) else { return nil }

        var blockedByCloudflare = false

        // 1) 解析官网首页 HTML（优先 apple-touch-icon / 高清 icon / og:image / 头部 Logo）
        for homeStr in ["https://\(domain)", "https://www.\(domain)"] {
            guard let homeURL = URL(string: homeStr),
                  let (htmlData, resp) = try? await session.data(from: homeURL),
                  let http = resp as? HTTPURLResponse else {
                continue
            }
            let sample = String(data: htmlData.prefix(262_144), encoding: .utf8)
                ?? String(data: htmlData.prefix(262_144), encoding: .isoLatin1)
                ?? ""
            if isCloudflareChallenge(http: http, html: sample) {
                blockedByCloudflare = true
                break
            }
            guard (200...299).contains(http.statusCode),
                  let finalHost = resp.url?.host,
                  !isBlacklistedHost(finalHost) else {
                continue
            }
            let candidates = extractHTMLIconURLs(html: sample, baseURL: resp.url ?? homeURL)
            for candidate in candidates {
                if let data = await downloadValidImage(urlStr: candidate, session: session, checkHostBlacklist: true, minDimension: 24, filterGrayGlobe: false) {
                    return data
                }
            }
            break
        }

        // 2) 未被 Cloudflare 拦截时，直接探测 /apple-touch-icon.png 与 /favicon.ico
        if !blockedByCloudflare {
            let directCandidates = [
                "https://\(domain)/apple-touch-icon.png",
                "https://www.\(domain)/apple-touch-icon.png",
                "https://\(domain)/favicon.ico",
                "https://www.\(domain)/favicon.ico"
            ]
            for urlStr in directCandidates {
                if let data = await downloadValidImage(urlStr: urlStr, session: session, checkHostBlacklist: true, minDimension: 24, filterGrayGlobe: false) {
                    return data
                }
            }
        }

        // 3) Cloudflare 拦截或直连未命中：回退 Google Favicon 代理（sz=128）并严格过滤默认灰地球图标
        let s2 = "https://www.google.com/s2/favicons?domain=\(domain)&sz=128"
        if let data = await downloadValidImage(urlStr: s2, session: session, checkHostBlacklist: false, minDimension: 32, filterGrayGlobe: true) {
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
            if let host = URL(string: resolved)?.host, isBlacklistedHost(host) {
                return
            }
            seen.insert(resolved)
            found.append(resolved)
        }

        // 1) apple-touch-icon 优先
        let linkPatterns = [
            #"(?i)<link[^>]+rel=["'][^"']*apple-touch-icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*apple-touch-icon[^"']*["']"#,
            #"(?i)<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*icon[^"']*["']"#
        ]
        for pat in linkPatterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for m in matches.prefix(4) {
                    if let r = Range(m.range(at: 1), in: html) {
                        appendURL(String(html[r]))
                    }
                }
            }
        }

        // 2) og:image
        if let og = extractMetaContent(html: html, property: "og:image") {
            appendURL(og)
        }

        // 3) 页面头部 Logo <img>（扫描 <header>...</header> 或带 logo/brand 属性的 <img>）
        let headerRegions: [String] = {
            var regions: [String] = []
            if let regex = try? NSRegularExpression(pattern: #"(?is)<header\b[^>]*>.*?</header>"#) {
                for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(2) {
                    if let r = Range(m.range, in: html) {
                        regions.append(String(html[r]))
                    }
                }
            }
            regions.append(String(html.prefix(65_536)))
            return regions
        }()

        if let imgTagRegex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#),
           let srcRegex = try? NSRegularExpression(pattern: #"(?i)\bsrc=["']([^"']+)["']"#) {
            for region in headerRegions {
                for m in imgTagRegex.matches(in: region, range: NSRange(region.startIndex..., in: region)).prefix(20) {
                    guard let r = Range(m.range, in: region) else { continue }
                    let tag = String(region[r])
                    let lowerTag = tag.lowercased()
                    guard lowerTag.contains("logo") || lowerTag.contains("brand") else { continue }
                    if let sm = srcRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                       let sr = Range(sm.range(at: 1), in: tag) {
                        appendURL(String(tag[sr]))
                    }
                }
            }
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
        minDimension: Int,
        filterGrayGlobe: Bool
    ) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        if checkHostBlacklist, let host = url.host, isBlacklistedHost(host) {
            return nil
        }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count > 250,
              data.count <= 4 * 1024 * 1024 else {
            return nil
        }
        if checkHostBlacklist, let finalHost = resp.url?.host, isBlacklistedHost(finalHost) {
            return nil
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           ct.contains("text/html") || ct.contains("application/xhtml") {
            return nil
        }
        guard let img = NSImage(data: data), isValidIcon(img, minDimension: minDimension) else {
            return nil
        }
        if filterGrayGlobe && isLikelyDefaultGrayGlobe(img, rawByteCount: data.count) {
            return nil
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

/// 品牌圆形徽章（优先显示自定义/官方缓存 Logo，否则回退 iOS 通讯录风格圆形首字母徽章）
struct BrandAvatarView: View {
    @ObservedObject private var cache = BrandLogoCache.shared
    @Environment(\.colorScheme) private var scheme

    let brand: String
    var size: CGFloat = 24
    var category: GearCategory? = nil

    var body: some View {
        let _ = cache.cacheRevision
        Group {
            if let img = cache.logoImage(for: brand) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
                    .frame(width: size, height: size)
                    .background(
                        Circle()
                            .fill(scheme == .dark ? Color.white.opacity(0.92) : Color.white)
                    )
                    .overlay(
                        Circle()
                            .stroke(ShaveTheme.cardBorder(scheme), lineWidth: 0.75)
                    )
                    .clipShape(Circle())
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
