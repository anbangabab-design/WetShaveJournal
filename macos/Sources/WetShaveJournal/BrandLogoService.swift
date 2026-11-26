import SwiftUI
import AppKit

/// 品牌 Logo 多级检索与本地缓存服务（严禁抓取 Etsy/Amazon/Reddit/Instagram 站标替代）：
/// 0) 用户自定义永久品牌图标（CustomLogos/）
/// 1) 扩充内置湿剃品牌官网映射表 → apple-touch-icon / og:image / 高清站标
/// 2) 按品类搜索独立品牌官网（严格过滤平台黑名单域名）→ 抓取真实站标
/// 3) 无独立官网时，尝试查找品牌 Instagram 公开主页并仅提取真实头像 og:image（绝不抓 IG 站标）
/// 4) 未命中时平滑回退为 iOS 通讯录风格圆形首字母/中文首字徽章
@MainActor
final class BrandLogoCache: ObservableObject {
    static let shared = BrandLogoCache()
    static let customLogoDidChangeNotification = Notification.Name("WetShaveJournal.CustomLogoDidChange")
    nonisolated static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "ico", "bmp", "heic", "tiff"
    ]

    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var cacheRevision: Int = 0

    // 并发限流（最多同时 3 个网络抓图任务）+ 失败域名/品牌冷却缓存（24 小时）
    private struct PendingFetchRequest {
        let key: String
        let brand: String
        let knownDomain: String?
        let category: GearCategory?
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
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 3
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    /// 严格禁止作为品牌 Logo 来源的平台域名黑名单
    nonisolated static let blacklistedDomains: [String] = [
        "etsy.com",
        "amazon.",
        "ebay.",
        "aliexpress.",
        "taobao.",
        "tmall.",
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
        "bing.com",
        "duckduckgo.com",
        "shopify.com",
        "wixsite.com"
    ]

    /// 扩充内置湿剃品牌官方独立域名映射
    nonisolated static let brandDomains: [String: String] = [
        "Above The Tie": "abovethetie.com",
        "Alpha": "alphashaving.com",
        "Amonatura": "amonatura.com",
        "Ariana & Evans": "aegrooming.com",
        "Arko": "arkomen.com",
        "Arno": "arnobrush.com",
        "Ascender": "ascenderrazors.com",
        "Atelier Durdan": "atelierdurdan.com",
        "Aylsworth": "aylsworthrazors.com",
        "Barrister and Mann": "barristerandmann.com",
        "Blackland": "blacklandrazors.com",
        "Blutt": "bluttrasur.ch",
        "Boti": "botibrush.com",
        "Brad Sears": "bradsearsshaveworks.com",
        "Captain's Choice": "captainschoicestore.com",
        "Cayuen": "cayuenworkshop.com",
        "Cella": "cellamilano.it",
        "CeraVe": "cerave.com",
        "Chisel & Hound": "chiselandhound.com",
        "Clubman Pinaud": "clubmanonline.com",
        "Colonial": "colonialrazors.com",
        "Declaration Grooming": "declarationgrooming.com",
        "Dorco": "dorcousa.com",
        "Edwin Jagger": "edwinjagger.com",
        "Elysian Soap Shop": "elysiansoapshop.com",
        "Ethos Grooming": "ethosgroomingessentials.com",
        "Feather": "feather.co.jp",
        "Fine Accoutrements": "fineaccoutrements.com",
        "Frank Shaving": "frankshaving.com",
        "Gillette": "gillette.com",
        "HAGS": "haveagreatshave.com",
        "Henson": "hensonshaving.com",
        "HLS": "homelikeshaving.ru",
        "House of Mammoth": "houseofmammoth.com",
        "Kai": "kai-group.com",
        "Karve": "karveshaving.com",
        "Lambda": "lambdarazors.com",
        "Le Père Lucien": "leperelucien.com",
        "Leaf": "leafshave.com",
        "Longshaving": "longshaving.com",
        "MacDuffs Soap Company": "macduffssoapcompany.com",
        "Maggard": "maggardrazors.com",
        "Martin de Candre": "martin-de-candre.com",
        "Maxwell June": "maxwelljune.com",
        "Merkur": "merkur-razors.com",
        "Moon Soaps": "moonsoaps.com",
        "Mühle": "muehle-shaving.com",
        "Noble Otter": "nobleotter.com",
        "Nomad Theory": "nomadtheory.co.uk",
        "Old Spice": "oldspice.com",
        "Omega": "omegabrush.com",
        "Oumo": "oumoshavingbrush.com",
        "Paladin": "paladinshaving.com",
        "PantaRei": "pantareibrushes.it",
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
        "Stirling Soap Co.": "stirlingsoap.com",
        "Tatara": "tatararazors.com",
        "Thayers": "thayers.com",
        "The Razor Company": "therazorcompany.com",
        "Timeless": "timelessrazor.com",
        "Turn-N-Shave": "turnnshave.com",
        "Wald": "waldshaving.com",
        "WestMan Shaving": "westmanshaving.com",
        "Wolfman": "wolfmanrazors.com",
        "Yaqi": "yaqishaving.com",
        "Zingari Man": "zingariman.com"
    ]

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
        return images[key]
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
            // 清理同品牌旧扩展名文件（如从 Windows 同步过来的 .jpg/.webp），避免同 key 多文件冲突
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

    /// 清理自动抓取缓存与失败冷却表（保留用户自定义图标）
    func clearAutoCacheAndRefetch() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.removeItem(at: legacyDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        fetchGeneration += 1
        activeFetchCount = 0
        inFlight.removeAll()
        queuedKeys.removeAll()
        pendingQueue.removeAll()
        failedCooldowns.removeAll()

        // 仅保留内存中的用户自定义图标
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
        guard !trimmed.isEmpty, trimmed != "仿刀", trimmed != "品牌未注明", trimmed != "无品牌" else { return }
        let key = normalizedBrandKey(trimmed)
        if images[key] != nil || inFlight.contains(key) || queuedKeys.contains(key) { return }

        // Tier 0: 检查用户自定义永久品牌图标（支持 PNG/JPG/WebP 等跨平台格式）
        if let customURL = findCustomLogoFile(forKey: key),
           let data = try? Data(contentsOf: customURL),
           let img = NSImage(data: data) {
            images[key] = img
            return
        }

        // 检查本地自动缓存 LogoCache/
        let diskURL = cacheDirectory.appendingPathComponent("\(key).png")
        if FileManager.default.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL),
           let img = NSImage(data: data),
           Self.isValidIcon(img) {
            images[key] = img
            return
        }

        let knownDomain = Self.brandDomains[trimmed]
            ?? Self.brandDomains.first(where: { $0.key.lowercased() == trimmed.lowercased() })?.value

        // 失败冷却期内直接跳过，避免滚动列表时反复发请求导致闪烁与卡顿
        if isInCooldown(brandKey: key, domain: knownDomain) { return }

        queuedKeys.insert(key)
        pendingQueue.append(PendingFetchRequest(
            key: key,
            brand: trimmed,
            knownDomain: knownDomain,
            category: category,
            diskURL: diskURL
        ))
        pumpFetchQueue()
    }

    private func pumpFetchQueue() {
        while activeFetchCount < maxConcurrentFetches, !pendingQueue.isEmpty {
            let req = pendingQueue.removeFirst()
            queuedKeys.remove(req.key)
            guard images[req.key] == nil,
                  !inFlight.contains(req.key),
                  !isInCooldown(brandKey: req.key, domain: req.knownDomain) else {
                continue
            }

            inFlight.insert(req.key)
            activeFetchCount += 1
            let generation = fetchGeneration

            Task.detached(priority: .utility) { [req, generation] in
                let result = await Self.resolveLogoPipeline(
                    brand: req.brand,
                    knownDomain: req.knownDomain,
                    category: req.category
                )
                await MainActor.run {
                    guard self.fetchGeneration == generation else { return }
                    self.inFlight.remove(req.key)
                    self.activeFetchCount = max(0, self.activeFetchCount - 1)

                    if let data = result.data, let img = NSImage(data: data), Self.isValidIcon(img) {
                        try? data.write(to: req.diskURL, options: .atomic)
                        self.images[req.key] = img
                    } else {
                        self.markFailedCooldown(brandKey: req.key, domain: result.failedDomain ?? req.knownDomain)
                    }
                    self.pumpFetchQueue()
                }
            }
        }
    }

    private func normalizedBrandKey(_ brand: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return brand.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
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

    private nonisolated static func isValidIcon(_ img: NSImage) -> Bool {
        guard let rep = img.representations.first else { return false }
        return rep.pixelsWide >= 24 && rep.pixelsHigh >= 24
    }

    /// 4 级品牌 Logo 检索管道（严格隔离黑名单平台，复用共享 URLSession）
    private nonisolated static func resolveLogoPipeline(brand: String, knownDomain: String?, category: GearCategory?) async -> (data: Data?, failedDomain: String?) {
        let session = sharedSession
        var lastTriedDomain = knownDomain

        // 第 1 级：内置官网域名直接抓取
        if let domain = knownDomain, !isBlacklistedHost(domain) {
            if let data = await fetchBrandSiteIcon(domain: domain, session: session) {
                return (data, nil)
            }
        }

        // 中文/极短非独立域名小众作坊不强搜以防误撞无关网站
        let hasLatin = brand.unicodeScalars.contains { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
        guard hasLatin && brand.count >= 3 else { return (nil, lastTriedDomain) }

        // 第 2 级：按品类搜索独立品牌官网（严禁命中黑名单平台域名）
        let keyword = (category == .razor || category == .blade) ? "razor" : "shaving"
        if let discovered = await searchOfficialDomain(query: "\(brand) \(keyword)", brand: brand, session: session) {
            lastTriedDomain = discovered
            if let data = await fetchBrandSiteIcon(domain: discovered, session: session) {
                return (data, nil)
            }
        }

        // 第 3 级：尝试查找品牌公开 Instagram 主页并仅提取真实头像 og:image
        if let igAvatar = await fetchInstagramProfileAvatar(brand: brand, session: session) {
            return (igAvatar, nil)
        }

        // 第 4 级：返回 nil，交由 BrandAvatarView 渲染 iOS 通讯录风格圆形首字母徽章
        return (nil, lastTriedDomain)
    }

    private nonisolated static func fetchBrandSiteIcon(domain: String, session: URLSession) async -> Data? {
        guard !isBlacklistedHost(domain) else { return nil }

        // 1) 尝试直接读取 apple-touch-icon
        let directCandidates = [
            "https://\(domain)/apple-touch-icon.png",
            "https://www.\(domain)/apple-touch-icon.png"
        ]
        for urlStr in directCandidates {
            if let data = await downloadValidImage(urlStr: urlStr, session: session, checkHostBlacklist: true) {
                return data
            }
        }

        // 2) 解析首页 HTML 的 apple-touch-icon / 高清 icon / og:image
        if let homeURL = URL(string: "https://\(domain)"),
           let (htmlData, resp) = try? await session.data(from: homeURL),
           let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
           let finalHost = resp.url?.host, !isBlacklistedHost(finalHost),
           let html = String(data: htmlData, encoding: .utf8) ?? String(data: htmlData, encoding: .isoLatin1) {
            let iconURLs = extractHTMLIconURLs(html: html, baseURL: resp.url ?? homeURL)
            for candidate in iconURLs {
                if let data = await downloadValidImage(urlStr: candidate, session: session, checkHostBlacklist: true) {
                    return data
                }
            }
        }

        // 3) 兜底用 Google S2 拉取该已验证独立官网的 64px 图标（严禁用于黑名单域名）
        let s2 = "https://www.google.com/s2/favicons?domain=\(domain)&sz=64"
        if let data = await downloadValidImage(urlStr: s2, session: session, checkHostBlacklist: false) {
            return data
        }

        return nil
    }

    private nonisolated static func searchOfficialDomain(query: String, brand: String, session: URLSession) async -> String? {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "html.duckduckgo.com"
        comps.path = "/html/"
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url,
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        let brandToken = brand.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        guard brandToken.count >= 3 else { return nil }

        let pattern = #"https?://(?:www\.)?([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for m in matches.prefix(25) {
            guard let r = Range(m.range(at: 1), in: html) else { continue }
            let host = String(html[r]).lowercased()
            if isBlacklistedHost(host) { continue }
            // 仅命中包含品牌特征词的独立域名，避免抓到第三方评测站或零售商城
            let hostCompact = host.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")
            if hostCompact.contains(brandToken) {
                return host
            }
        }
        return nil
    }

    private nonisolated static func fetchInstagramProfileAvatar(brand: String, session: URLSession) async -> Data? {
        let slug = brand.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        guard slug.count >= 3 else { return nil }

        let candidates = [slug, "\(slug)shaving", "\(slug)razors"]
        for handle in candidates {
            guard let url = URL(string: "https://www.instagram.com/\(handle)/") else { continue }
            guard let (data, resp) = try? await session.data(from: url),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                continue
            }
            if let ogImage = extractMetaContent(html: html, property: "og:image") {
                let lower = ogImage.lowercased()
                // 严禁抓取 Instagram 默认站标/静态图标，仅接受真实 CDN 头像
                if (lower.contains("cdninstagram.com") || lower.contains("fbcdn.net")) && !lower.contains("rsrc.php") && !lower.contains("static") {
                    if let imgData = await downloadValidImage(urlStr: ogImage, session: session, checkHostBlacklist: false) {
                        return imgData
                    }
                }
            }
        }
        return nil
    }

    private nonisolated static func extractHTMLIconURLs(html: String, baseURL: URL) -> [String] {
        var found: [String] = []
        let patterns = [
            #"(?i)<link[^>]+rel=["'][^"']*apple-touch-icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*apple-touch-icon[^"']*["']"#,
            #"(?i)<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)["']"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                for m in matches.prefix(3) {
                    if let r = Range(m.range(at: 1), in: html) {
                        let raw = String(html[r])
                        if let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteString {
                            found.append(resolved)
                        }
                    }
                }
            }
        }
        if let og = extractMetaContent(html: html, property: "og:image"),
           let resolved = URL(string: og, relativeTo: baseURL)?.absoluteString {
            found.append(resolved)
        }
        return found
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

    private nonisolated static func downloadValidImage(urlStr: String, session: URLSession, checkHostBlacklist: Bool) async -> Data? {
        guard let url = URL(string: urlStr) else { return nil }
        if checkHostBlacklist, let host = url.host, isBlacklistedHost(host) {
            return nil
        }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              data.count > 250 else {
            return nil
        }
        if checkHostBlacklist, let finalHost = resp.url?.host, isBlacklistedHost(finalHost) {
            return nil
        }
        guard let img = NSImage(data: data), isValidIcon(img) else {
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
