import Foundation
import AppKit
import CoreGraphics

// MARK: - 原生 CoreGraphics 品牌 Logo 图像处理引擎（自动去白/黑/透明边、可选圆形裁切、256px 长边规范化）

enum LogoTrimMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case transparentOnly = "transparent"
    case white = "white"
    case black = "black"
    case none = "none"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return L10n.t("智能去边", "Auto Trim")
        case .transparentOnly: return L10n.t("仅去透明边", "Alpha Only")
        case .white: return L10n.t("去白边", "Trim White")
        case .black: return L10n.t("去黑边", "Trim Black")
        case .none: return L10n.t("不裁剪", "None")
        }
    }
}

/// 归一化裁剪框（左上角原点，坐标范围 0...1）
struct NormalizedCropRect: Codable, Equatable, Hashable, Sendable {
    var x0: Double
    var y0: Double
    var x1: Double
    var y1: Double

    var isValid: Bool {
        let cx0 = max(0, min(1, x0))
        let cy0 = max(0, min(1, y0))
        let cx1 = max(0, min(1, x1))
        let cy1 = max(0, min(1, y1))
        return (cx1 - cx0) >= 0.08 && (cy1 - cy0) >= 0.08
    }

    var clamped: NormalizedCropRect {
        let a = max(0, min(1, x0))
        let b = max(0, min(1, y0))
        let c = max(a, min(1, x1))
        let d = max(b, min(1, y1))
        return NormalizedCropRect(x0: a, y0: b, x1: c, y1: d)
    }
}

enum BrandLogoImageProcessor {
    private struct RGBABuffer {
        let width: Int
        let height: Int
        let pixels: [UInt8] // 4 bytes per pixel: R, G, B, A (unpremultiplied / standard sRGB)
    }

    /// 将任意 NSImage 解码为标准 8-bit sRGB RGBA 像素缓冲区与 CGImage（彻底消除 EXIF DPI 坐标偏移）
    private static func makeCGImageAndBuffer(from image: NSImage) -> (cgImage: CGImage, buffer: RGBABuffer)? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else {
            return nil
        }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let normalizedCG = ctx.makeImage() else { return nil }

        // 还原非预乘 RGB 便于颜色阈值检测
        var unpremul = data
        for i in stride(from: 0, to: unpremul.count, by: 4) {
            let a = Int(unpremul[i + 3])
            if a > 0 && a < 255 {
                unpremul[i] = UInt8(min(255, Int(unpremul[i]) * 255 / a))
                unpremul[i + 1] = UInt8(min(255, Int(unpremul[i + 1]) * 255 / a))
                unpremul[i + 2] = UInt8(min(255, Int(unpremul[i + 2]) * 255 / a))
            }
        }
        return (normalizedCG, RGBABuffer(width: width, height: height, pixels: unpremul))
    }

    /// 检测纯白/纯黑/纯透明或几乎无视觉变化的单色占位图（过滤如空白图与损坏图）
    static func isBlankOrUniform(_ image: NSImage) -> Bool {
        guard let (_, buf) = makeCGImageAndBuffer(from: image) else { return true }
        let stepX = max(1, buf.width / 32)
        let stepY = max(1, buf.height / 32)

        var visibleCount = 0
        var minR = 255, maxR = 0
        var minG = 255, maxG = 0
        var minB = 255, maxB = 0
        var nonWhiteCount = 0

        for y in stride(from: 0, to: buf.height, by: stepY) {
            for x in stride(from: 0, to: buf.width, by: stepX) {
                let idx = (y * buf.width + x) * 4
                let r = Int(buf.pixels[idx])
                let g = Int(buf.pixels[idx + 1])
                let b = Int(buf.pixels[idx + 2])
                let a = Int(buf.pixels[idx + 3])
                if a <= 16 { continue }
                visibleCount += 1
                minR = min(minR, r); maxR = max(maxR, r)
                minG = min(minG, g); maxG = max(maxG, g)
                minB = min(minB, b); maxB = max(maxB, b)
                if r < 245 || g < 245 || b < 245 {
                    nonWhiteCount += 1
                }
            }
        }
        if visibleCount < 4 { return true }
        // 几乎全部为纯白像素且不含透明镂空轮廓
        let totalSamples = ((buf.width + stepX - 1) / stepX) * ((buf.height + stepY - 1) / stepY)
        let transparentSamples = max(0, totalSamples - visibleCount)
        if nonWhiteCount == 0 && transparentSamples < max(4, totalSamples / 10) {
            return true
        }
        // 全图不透明且三通道极差极小（纯色块）
        if transparentSamples < max(4, totalSamples / 20) && (maxR - minR) < 12 && (maxG - minG) < 12 && (maxB - minB) < 12 {
            return true
        }
        return false
    }

    /// 过滤极端长条横幅/广告图（避免抓到整页 Banner 照片）
    static func isSuspiciousAspectRatio(_ image: NSImage) -> Bool {
        let w = image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
        let h = image.representations.map(\.pixelsHigh).max() ?? Int(image.size.height)
        guard w > 0, h > 0 else { return true }
        let ratio = Double(w) / Double(h)
        return ratio > 7.5 || ratio < 0.13
    }

    private static func detectAutoTrimMode(in buf: RGBABuffer) -> LogoTrimMode {
        var borderTotal = 0
        var transparentBorder = 0
        var whiteBorder = 0
        var blackBorder = 0

        func sample(_ x: Int, _ y: Int) {
            let idx = (y * buf.width + x) * 4
            let r = buf.pixels[idx]
            let g = buf.pixels[idx + 1]
            let b = buf.pixels[idx + 2]
            let a = buf.pixels[idx + 3]
            borderTotal += 1
            if a <= 12 {
                transparentBorder += 1
            } else if r >= 232 && g >= 232 && b >= 232 {
                whiteBorder += 1
            } else if r <= 24 && g <= 24 && b <= 24 {
                blackBorder += 1
            }
        }

        let stepX = max(1, buf.width / 48)
        let stepY = max(1, buf.height / 48)
        for x in stride(from: 0, to: buf.width, by: stepX) {
            sample(x, 0)
            sample(x, buf.height - 1)
        }
        for y in stride(from: 0, to: buf.height, by: stepY) {
            sample(0, y)
            sample(buf.width - 1, y)
        }

        guard borderTotal > 0 else { return .transparentOnly }
        let ratio = { (n: Int) in Double(n) / Double(borderTotal) }
        if ratio(transparentBorder) >= 0.45 {
            return .transparentOnly
        }
        if ratio(whiteBorder) >= 0.72 {
            return .white
        }
        if ratio(blackBorder) >= 0.72 {
            return .black
        }
        return .transparentOnly
    }

    private static func computeTrimRect(in buf: RGBABuffer, mode: LogoTrimMode) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: buf.width, height: buf.height)
        let resolved = (mode == .auto) ? detectAutoTrimMode(in: buf) : mode
        guard resolved != .none else { return full }

        var minX = buf.width
        var minY = buf.height
        var maxX = -1
        var maxY = -1

        for y in 0..<buf.height {
            let rowOffset = y * buf.width * 4
            for x in 0..<buf.width {
                let idx = rowOffset + x * 4
                let r = buf.pixels[idx]
                let g = buf.pixels[idx + 1]
                let b = buf.pixels[idx + 2]
                let a = buf.pixels[idx + 3]

                let isBackground: Bool
                switch resolved {
                case .transparentOnly:
                    isBackground = (a <= 10)
                case .white:
                    isBackground = (a <= 10) || (r >= 230 && g >= 230 && b >= 230)
                case .black:
                    isBackground = (a <= 10) || (r <= 26 && g <= 26 && b <= 26)
                case .auto, .none:
                    isBackground = false
                }

                if !isBackground {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return full }

        let contentW = maxX - minX + 1
        let contentH = maxY - minY + 1
        // 裁切结果至少保留合理有效区域（避免极端情况把整图裁没）
        guard contentW >= 6, contentH >= 6 else { return full }

        let padX: Int
        let padY: Int
        switch resolved {
        case .transparentOnly:
            padX = max(1, min(6, contentW / 40))
            padY = max(1, min(6, contentH / 40))
        case .white:
            padX = max(2, min(14, contentW / 24))
            padY = max(2, min(14, contentH / 24))
        case .black:
            // 黑底白字徽标保留适度呼吸黑边，确保深浅模式下都像完整铭牌
            padX = max(4, min(28, contentW / 14))
            padY = max(4, min(24, contentH / 12))
        case .auto, .none:
            padX = 0; padY = 0
        }

        let x0 = max(0, minX - padX)
        let y0 = max(0, minY - padY)
        let x1 = min(buf.width, maxX + 1 + padX)
        let y1 = min(buf.height, maxY + 1 + padY)
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    /// 规范化品牌 Logo：支持可选归一化裁剪框 → 智能去边 → 可选抗锯齿圆形蒙版 → 长边等比缩放至 256px → 剥离元数据的洁净 RGBA PNG
    static func normalizeLogo(
        _ image: NSImage,
        trimMode: LogoTrimMode = .auto,
        cropRect: NormalizedCropRect? = nil,
        circularMask: Bool = false,
        maxLongEdge: Int = 256
    ) -> (image: NSImage, pngData: Data)? {
        guard var (cg, buf) = makeCGImageAndBuffer(from: image) else { return nil }

        // 1) 可选裁剪框（左上角原点，与 CGImage.cropping(to:) 坐标系一致）
        if let rect = cropRect, rect.isValid {
            let c = rect.clamped
            let pxX = Int((c.x0 * Double(cg.width)).rounded(.down))
            let pxY = Int((c.y0 * Double(cg.height)).rounded(.down))
            let pxW = max(8, Int(((c.x1 - c.x0) * Double(cg.width)).rounded()))
            let pxH = max(8, Int(((c.y1 - c.y0) * Double(cg.height)).rounded()))
            let safeRect = CGRect(
                x: max(0, min(cg.width - 1, pxX)),
                y: max(0, min(cg.height - 1, pxY)),
                width: min(pxW, cg.width - max(0, pxX)),
                height: min(pxH, cg.height - max(0, pxY))
            )
            if let cropped = cg.cropping(to: safeRect) {
                let tempImg = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
                if let rebuilt = makeCGImageAndBuffer(from: tempImg) {
                    cg = rebuilt.cgImage
                    buf = rebuilt.buffer
                }
            }
        }

        // 2) 智能去边（圆形裁切模式下通常已精确框定圆标，仅对非圆裁或未指定裁剪框执行去边）
        if trimMode != .none && (!circularMask || cropRect == nil) {
            let trimRect = computeTrimRect(in: buf, mode: trimMode)
            if Int(trimRect.width) < cg.width || Int(trimRect.height) < cg.height,
               let trimmed = cg.cropping(to: trimRect) {
                cg = trimmed
            }
        }

        // 3) 等比缩放至目标长边（圆标时若近方形则规整为正圆正方形）
        let srcW = cg.width
        let srcH = cg.height
        guard srcW > 0, srcH > 0 else { return nil }

        let targetW: Int
        let targetH: Int
        if circularMask {
            let side = max(16, maxLongEdge)
            targetW = side
            targetH = side
        } else {
            let scale = Double(maxLongEdge) / Double(max(srcW, srcH))
            targetW = max(1, Int((Double(srcW) * scale).rounded()))
            targetH = max(1, Int((Double(srcH) * scale).rounded()))
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let outCtx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        outCtx.clear(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        outCtx.interpolationQuality = .high
        outCtx.setAllowsAntialiasing(true)
        outCtx.setShouldAntialias(true)

        if circularMask {
            outCtx.addEllipse(in: CGRect(x: 0.5, y: 0.5, width: CGFloat(targetW) - 1, height: CGFloat(targetH) - 1))
            outCtx.clip()
        }
        outCtx.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        guard let finalCG = outCtx.makeImage() else { return nil }
        let outRep = NSBitmapImageRep(cgImage: finalCG)
        outRep.size = NSSize(width: targetW, height: targetH)
        guard let pngData = outRep.representation(using: .png, properties: [:]) else { return nil }
        guard let outImg = NSImage(data: pngData) else { return nil }
        return (outImg, pngData)
    }

    /// 为 AI 视觉自检拼装带编号的中灰底候选拼图（同时清晰呈现白标与黑标）
    static func buildCandidateContactSheet(candidates: [(index: Int, image: NSImage, label: String)]) -> Data? {
        guard !candidates.isEmpty else { return nil }
        let count = candidates.count
        let cols = min(3, count)
        let rows = (count + cols - 1) / cols
        let cellW: CGFloat = 220
        let cellH: CGFloat = 190
        let W = Int(CGFloat(cols) * cellW)
        let H = Int(CGFloat(rows) * cellH)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: W,
            pixelsHigh: H,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.50, alpha: 1.0).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.white
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.92, alpha: 1.0)
        ]

        for (i, item) in candidates.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = CGFloat(col) * cellW
            let y = CGFloat(H) - CGFloat(row + 1) * cellH

            let cardRect = NSRect(x: x + 6, y: y + 6, width: cellW - 12, height: cellH - 12)
            NSColor(calibratedWhite: 0.56, alpha: 1.0).setFill()
            NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8).fill()

            let maxW = cellW - 36
            let maxH = cellH - 64
            let iw = max(1, CGFloat(item.image.representations.map(\.pixelsWide).max() ?? Int(item.image.size.width)))
            let ih = max(1, CGFloat(item.image.representations.map(\.pixelsHigh).max() ?? Int(item.image.size.height)))
            let sc = min(maxW / iw, maxH / ih)
            let dw = iw * sc
            let dh = ih * sc
            let dx = x + (cellW - dw) / 2
            let dy = y + 26 + (maxH - dh) / 2
            item.image.draw(in: NSRect(x: dx, y: dy, width: dw, height: dh))

            // 左上角醒目序号角标（供视觉模型精准返回 selectedIndex）
            let tagRect = NSRect(x: x + 12, y: y + cellH - 34, width: 32, height: 22)
            NSColor(calibratedRed: 0.14, green: 0.42, blue: 0.78, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 5, yRadius: 5).fill()
            ("#\(item.index)" as NSString).draw(at: NSPoint(x: x + 18, y: y + cellH - 32), withAttributes: badgeAttrs)

            (item.label as NSString).draw(in: NSRect(x: x + 12, y: y + 8, width: cellW - 24, height: 15), withAttributes: subAttrs)
        }
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

// MARK: - AI 智能品牌找图服务（AI 联网寻源 → 官网页头/JSON-LD/Wayback 归档提取 → 视觉自检 → 256px 规范化）

enum LogoCandidateSource: String, Sendable {
    case aiDirectURL
    case officialHeader
    case officialJSONLD
    case officialIcon
    case waybackHeader
    case googleFavicon

    var displayName: String {
        switch self {
        case .aiDirectURL: return L10n.t("AI 直链", "AI Direct")
        case .officialHeader: return L10n.t("官网页头", "Site Header")
        case .officialJSONLD: return L10n.t("官网元数据", "JSON-LD")
        case .officialIcon: return L10n.t("官网图标", "Site Icon")
        case .waybackHeader: return L10n.t("Wayback 归档", "Wayback Archive")
        case .googleFavicon: return L10n.t("Favicon", "Favicon")
        }
    }

    var basePriority: Int {
        switch self {
        case .officialHeader: return 100
        case .aiDirectURL: return 92
        case .officialJSONLD: return 88
        case .waybackHeader: return 85
        case .officialIcon: return 74
        case .googleFavicon: return 45
        }
    }
}

struct AILogoDiscoveryPlan: Codable, Equatable, Sendable {
    var canonicalName: String?
    var officialSiteURL: String?
    var directLogoURLs: [String]
    var reasoning: String?
}

struct AILogoVisionAuditResponse: Codable, Equatable, Sendable {
    var selectedIndex: Int?
    var isAuthentic: Bool?
    var isCircularEmblem: Bool?
    var cropRect: NormalizedCropRect?
    var reason: String?
}

struct BrandLogoCandidate: Identifiable, @unchecked Sendable {
    let id: UUID
    let source: LogoCandidateSource
    let sourceURL: String
    let rawImage: NSImage
    var normalizedImage: NSImage
    var pngData: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var aiRecommended: Bool
    var aiSuggestedCircular: Bool
    var aiCropRect: NormalizedCropRect?
    var aiAuditNote: String?

    init(
        id: UUID = UUID(),
        source: LogoCandidateSource,
        sourceURL: String,
        rawImage: NSImage,
        normalizedImage: NSImage,
        pngData: Data,
        aiRecommended: Bool = false,
        aiSuggestedCircular: Bool = false,
        aiCropRect: NormalizedCropRect? = nil,
        aiAuditNote: String? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceURL = sourceURL
        self.rawImage = rawImage
        self.normalizedImage = normalizedImage
        self.pngData = pngData
        self.pixelWidth = normalizedImage.representations.map(\.pixelsWide).max() ?? Int(normalizedImage.size.width)
        self.pixelHeight = normalizedImage.representations.map(\.pixelsHigh).max() ?? Int(normalizedImage.size.height)
        self.aiRecommended = aiRecommended
        self.aiSuggestedCircular = aiSuggestedCircular
        self.aiCropRect = aiCropRect
        self.aiAuditNote = aiAuditNote
    }
}

struct AILogoSearchResult: @unchecked Sendable {
    let brand: String
    let canonicalBrand: String?
    let officialSiteURL: String?
    let candidates: [BrandLogoCandidate]
    let recommendedCandidateID: UUID?
    let visionVerified: Bool
    let summary: String
    let errorMessage: String?
}

protocol AILogoHTTPFetcher: Sendable {
    func fetch(url: URL) async -> (Data, HTTPURLResponse)?
}

struct URLSessionLogoHTTPFetcher: AILogoHTTPFetcher {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 18
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        ]
        self.session = URLSession(configuration: config)
    }

    func fetch(url: URL) async -> (Data, HTTPURLResponse)? {
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse else {
            return nil
        }
        return (data, http)
    }
}

struct AILogoFinderService: Sendable {
    static let shared = AILogoFinderService()

    private let aiClient: AIClient
    private let httpFetcher: AILogoHTTPFetcher

    init(
        aiTransport: AIClientTransport = URLSessionAIClientTransport(),
        httpFetcher: AILogoHTTPFetcher = URLSessionLogoHTTPFetcher()
    ) {
        self.aiClient = AIClient(transport: aiTransport)
        self.httpFetcher = httpFetcher
    }

    /// 严格 SSRF 与非法协议防护（禁止访问 localhost / 内网私网 IP / 非 http(s) 协议）
    static func isSafePublicURL(_ url: URL, allowImageCDN: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasSuffix(".internal") {
            return false
        }
        // 拦截 IPv4 私有网段与链路本地地址
        let ipv4Parts = host.split(separator: ".").compactMap { Int($0) }
        if ipv4Parts.count == 4 {
            let a = ipv4Parts[0], b = ipv4Parts[1]
            if a == 0 || a == 10 || a == 127 { return false }
            if a == 169 && b == 254 { return false }
            if a == 192 && b == 168 { return false }
            if a == 172 && (16...31).contains(b) { return false }
        }
        if !allowImageCDN && BrandLogoCache.isBlacklistedHost(host) {
            return false
        }
        // 即使允许图片 CDN，也禁止直接去抓 Etsy/Amazon/Reddit 等主站页面（仅允许其静态图片主机如 i.etsystatic.com / cdn.shopify.com）
        if allowImageCDN {
            let blockedPageHosts = ["etsy.com", "www.etsy.com", "reddit.com", "www.reddit.com", "facebook.com", "www.facebook.com", "instagram.com", "www.instagram.com", "wikipedia.org", "en.wikipedia.org"]
            if blockedPageHosts.contains(host) {
                return false
            }
        }
        return true
    }

    /// 解析 AI 返回的找图计划 JSON
    static func parseDiscoveryPlan(from rawText: String) -> AILogoDiscoveryPlan? {
        let cleaned = AIClient.extractJSONObjectString(from: rawText)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        if let decoded = try? JSONDecoder().decode(AILogoDiscoveryPlan.self, from: data) {
            return decoded
        }
        // 兼容宽松字典格式
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let canonical = (obj["canonicalName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let site = (obj["officialSiteURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = (obj["directLogoURLs"] as? [String]) ?? []
        let reasoning = (obj["reasoning"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AILogoDiscoveryPlan(
            canonicalName: canonical?.isEmpty == true ? nil : canonical,
            officialSiteURL: site?.isEmpty == true ? nil : site,
            directLogoURLs: urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            reasoning: reasoning?.isEmpty == true ? nil : reasoning
        )
    }

    /// 解析 AI 视觉自检返回的 JSON
    static func parseVisionAudit(from rawText: String) -> AILogoVisionAuditResponse? {
        let cleaned = AIClient.extractJSONObjectString(from: rawText)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AILogoVisionAuditResponse.self, from: data)
    }

    /// 智能提取网页中的品牌主标（优先级：<header> 内 logo <img> → JSON-LD "logo" → apple-touch-icon / icon → og:image）
    /// 自动跳过国家旗帜图标、.svg 与平台黑名单域名
    static func extractSmartHTMLCandidates(html: String, baseURL: URL, isWayback: Bool = false) -> [(url: String, source: LogoCandidateSource)] {
        var found: [(String, LogoCandidateSource)] = []
        var seen: Set<String> = []

        func appendURL(_ raw: String, source: LogoCandidateSource) {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "\\u0026", with: "&")
            guard !cleaned.isEmpty,
                  !cleaned.hasPrefix("data:"),
                  !cleaned.hasPrefix("javascript:"),
                  !cleaned.contains("{width}"),
                  !cleaned.lowercased().contains("/flags/") else {
                return
            }
            guard let resolvedURL = URL(string: cleaned, relativeTo: baseURL)?.absoluteURL else { return }
            let resolved = resolvedURL.absoluteString
            guard !seen.contains(resolved) else { return }
            if resolvedURL.pathExtension.lowercased() == "svg" { return }
            if !isWayback && !isSafePublicURL(resolvedURL, allowImageCDN: true) { return }
            seen.insert(resolved)
            found.append((resolved, source))
        }

        // 1) 扫描 <header>...</header> 中的品牌 Logo <img>（只匹配带 logo / brand / site-logo / header__logo 线索的标签）
        if let headerRegex = try? NSRegularExpression(pattern: #"(?is)<header\b[^>]*>.*?</header>"#),
           let imgRegex = try? NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#),
           let srcRegex = try? NSRegularExpression(pattern: #"(?i)\b(?:src|data-src)=["']([^"']+)["']"#) {
            let headerMatches = headerRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for hm in headerMatches.prefix(4) {
                guard let hr = Range(hm.range, in: html) else { continue }
                let headerHTML = String(html[hr])
                for im in imgRegex.matches(in: headerHTML, range: NSRange(headerHTML.startIndex..., in: headerHTML)).prefix(24) {
                    guard let ir = Range(im.range, in: headerHTML) else { continue }
                    let tag = String(headerHTML[ir])
                    let lower = tag.lowercased()
                    if lower.contains("flags/") || lower.contains("country-flag") || lower.contains("cart") || lower.contains("search") {
                        continue
                    }
                    let looksLikeLogo = lower.contains("logo") || lower.contains("brand") || lower.contains("site-header") || lower.contains("badge")
                    guard looksLikeLogo else { continue }
                    if let sm = srcRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                       let sr = Range(sm.range(at: 1), in: tag) {
                        appendURL(String(tag[sr]), source: isWayback ? .waybackHeader : .officialHeader)
                    }
                }
            }
        }

        // 2) JSON-LD "logo": "https://..."
        if let jsonLDRegex = try? NSRegularExpression(pattern: #"(?i)"logo"\s*:\s*"([^"]+\.(?:png|jpe?g|webp)[^"]*)""#) {
            for m in jsonLDRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(4) {
                if let r = Range(m.range(at: 1), in: html) {
                    appendURL(String(html[r]), source: isWayback ? .waybackHeader : .officialJSONLD)
                }
            }
        }

        // 3) <link rel="apple-touch-icon"> 与 <link rel="icon">
        let linkPatterns = [
            #"(?i)<link[^>]+rel=["'][^"']*apple-touch-icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*apple-touch-icon[^"']*["']"#,
            #"(?i)<link[^>]+rel=["'][^"']*icon[^"']*["'][^>]+href=["']([^"']+)["']"#,
            #"(?i)<link[^>]+href=["']([^"']+)["'][^>]+rel=["'][^"']*icon[^"']*["']"#
        ]
        for pat in linkPatterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                for m in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(4) {
                    if let r = Range(m.range(at: 1), in: html) {
                        appendURL(String(html[r]), source: isWayback ? .waybackHeader : .officialIcon)
                    }
                }
            }
        }

        // 4) <meta property="og:image">
        let ogPatterns = [
            #"(?i)<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"(?i)<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#
        ]
        for pat in ogPatterns {
            if let regex = try? NSRegularExpression(pattern: pat),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                appendURL(String(html[r]), source: isWayback ? .waybackHeader : .officialIcon)
            }
        }

        return Array(found.prefix(12))
    }

    /// 完整四阶段 AI 智能找图流程：
    /// 1. AI 联网检索官网地址与直链 Logo
    /// 2. 多通道抓取候选图（AI 直链 + 官网页头/JSON-LD + Wayback 归档兜底 + Google Favicon）并自动去边规范化为 256px PNG
    /// 3. 若当前模型支持视觉，将候选图拼成中灰底编号图交由 AI 视觉自检真伪与推荐（不支持视觉时自动静默降级为启发式排序）
    /// 4. 返回全部候选供用户在中灰底预览窗一键确认保存至 CustomLogos/
    func findLogoCandidates(
        for brand: String,
        category: GearCategory? = nil,
        aiConfig: AIConfig,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> AILogoSearchResult {
        let trimmedBrand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBrand.isEmpty, !BrandLogoCache.shouldSkipBrand(trimmedBrand) else {
            return AILogoSearchResult(
                brand: trimmedBrand,
                canonicalBrand: nil,
                officialSiteURL: nil,
                candidates: [],
                recommendedCandidateID: nil,
                visionVerified: false,
                summary: L10n.t("品牌名称为空或属于占位品牌", "Brand name is empty or a placeholder"),
                errorMessage: L10n.t("请先填写有效的品牌名称", "Please enter a valid brand name first")
            )
        }

        var discoveryPlan: AILogoDiscoveryPlan? = nil
        var aiErrorNote: String? = nil

        // Stage 1: AI 联网寻源
        if aiConfig.isReady {
            onProgress?(L10n.t("1/3 AI 联网检索品牌官网与 Logo 直链…", "1/3 Searching official website & logo URLs with AI…"))
            do {
                discoveryPlan = try await discoverSourcesViaAI(brand: trimmedBrand, category: category, aiConfig: aiConfig)
            } catch {
                aiErrorNote = error.localizedDescription
            }
        }

        // 合并已知核实白名单域名（即便 AI 未开启或未命中也能走智能页头 + Wayback 管道）
        let whitelisted = BrandLogoCache.resolveWhitelistedBrand(trimmedBrand)
        let canonicalBrand = discoveryPlan?.canonicalName ?? whitelisted?.canonical ?? trimmedBrand

        var officialSiteCandidates: [String] = []
        if let aiSite = discoveryPlan?.officialSiteURL, !aiSite.isEmpty {
            officialSiteCandidates.append(normalizeSiteURLString(aiSite))
        }
        if let knownDomain = whitelisted?.domain {
            let knownURL = normalizeSiteURLString(knownDomain)
            if !officialSiteCandidates.contains(knownURL) {
                officialSiteCandidates.append(knownURL)
            }
        }
        let primaryOfficialSite = officialSiteCandidates.first

        // Stage 2: 多通道候选采集与原生 256px 规范化
        onProgress?(L10n.t("2/3 提取官网页头、直链与 Wayback 归档候选图…", "2/3 Harvesting header logos, direct URLs & Wayback archive…"))

        var urlQueue: [(url: String, source: LogoCandidateSource)] = []
        var seenURLs: Set<String> = []
        func enqueue(_ urlStr: String, source: LogoCandidateSource) {
            let clean = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seenURLs.contains(clean) else { return }
            seenURLs.insert(clean)
            urlQueue.append((clean, source))
        }

        // Channel A: AI 直链 Logo URL
        for directURL in (discoveryPlan?.directLogoURLs ?? []).prefix(5) {
            enqueue(directURL, source: .aiDirectURL)
        }

        // Channel B: 官网 HTML 页头 / JSON-LD / Icon 提取 + Channel C: Wayback Machine 归档救援
        var harvestedAnyFromSite = false
        for siteStr in officialSiteCandidates.prefix(2) {
            guard let siteURL = URL(string: siteStr), Self.isSafePublicURL(siteURL, allowImageCDN: false) else { continue }
            var siteNeedsWayback = false
            if let (htmlData, http) = await httpFetcher.fetch(url: siteURL),
               (200...299).contains(http.statusCode),
               let finalURL = http.url ?? URL(string: siteStr) {
                let sample = String(data: htmlData.prefix(320_000), encoding: .utf8)
                    ?? String(data: htmlData.prefix(320_000), encoding: .isoLatin1)
                    ?? ""
                let extracted = Self.extractSmartHTMLCandidates(html: sample, baseURL: finalURL, isWayback: false)
                if extracted.isEmpty {
                    siteNeedsWayback = true
                } else {
                    harvestedAnyFromSite = true
                    for item in extracted.prefix(6) {
                        enqueue(item.url, source: item.source)
                    }
                }
            } else {
                // 官网返回 402/403/404/超时（如 Declaration Grooming 等暂停或被拦截站点）→ 自动走 Wayback 归档提取
                siteNeedsWayback = true
            }

            if siteNeedsWayback {
                let wbCandidates = await harvestFromWaybackArchive(originalSiteURL: siteURL)
                for item in wbCandidates.prefix(4) {
                    enqueue(item.url, source: .waybackHeader)
                }
            }

            // Channel D: Google Favicon 稳定兜底
            if let host = siteURL.host?.lowercased(), !BrandLogoCache.isBlacklistedHost(host) {
                enqueue("https://www.google.com/s2/favicons?domain=\(host)&sz=128", source: .googleFavicon)
            }
        }
        _ = harvestedAnyFromSite

        // 下载并过滤候选图（去重、拦截空白纯色占位图与极端长条横幅、自动去边规范化为 256px PNG）
        var candidates: [BrandLogoCandidate] = []
        var seenDigests: Set<String> = []
        for entry in urlQueue {
            guard candidates.count < 6 else { break }
            guard let url = URL(string: entry.url) else { continue }
            let isGoogleS2 = (entry.source == .googleFavicon)
            if !isGoogleS2 && !Self.isSafePublicURL(url, allowImageCDN: true) {
                continue
            }
            guard let rawImg = await downloadCandidateImage(url: url, minDimension: isGoogleS2 ? 24 : 20) else {
                continue
            }
            guard !BrandLogoImageProcessor.isBlankOrUniform(rawImg),
                  !BrandLogoImageProcessor.isSuspiciousAspectRatio(rawImg) else {
                continue
            }
            guard let normalized = BrandLogoImageProcessor.normalizeLogo(rawImg, trimMode: .auto, maxLongEdge: 256) else {
                continue
            }
            let digestKey = "\(normalized.pngData.count)-\(normalized.pngData.prefix(64).base64EncodedString())"
            guard seenDigests.insert(digestKey).inserted else { continue }

            candidates.append(BrandLogoCandidate(
                source: entry.source,
                sourceURL: entry.url,
                rawImage: rawImg,
                normalizedImage: normalized.image,
                pngData: normalized.pngData
            ))
        }

        // 按来源优先级与清晰度初排
        candidates.sort { lhs, rhs in
            let scoreL = lhs.source.basePriority + min(20, max(lhs.pixelWidth, lhs.pixelHeight) / 16)
            let scoreR = rhs.source.basePriority + min(20, max(rhs.pixelWidth, rhs.pixelHeight) / 16)
            return scoreL > scoreR
        }

        // Stage 3: 若 AI 可用且有候选图，自动尝试 AI 视觉自检（剔除无关旅馆/赌博站标，选出最纯正品牌标）
        var visionVerified = false
        var recommendedID: UUID? = candidates.first?.id
        var summaryText = discoveryPlan?.reasoning ?? ""

        if aiConfig.isReady, !candidates.isEmpty {
            onProgress?(L10n.t("3/3 AI 视觉自检真伪与构图规范…", "3/3 Running AI vision self-audit on candidates…"))
            if let audit = await auditCandidatesViaVision(brand: canonicalBrand, category: category, candidates: candidates, aiConfig: aiConfig) {
                visionVerified = true
                if audit.isAuthentic != false,
                   let idx = audit.selectedIndex,
                   idx >= 0 && idx < candidates.count {
                    candidates[idx].aiRecommended = true
                    candidates[idx].aiSuggestedCircular = audit.isCircularEmblem ?? false
                    candidates[idx].aiCropRect = audit.cropRect
                    candidates[idx].aiAuditNote = audit.reason

                    // 若视觉模型明确建议圆形裁切或精准裁剪框，生成裁切优化版并置顶推荐（同时保留原候选备选）
                    if let crop = audit.cropRect, crop.isValid,
                       let cropped = BrandLogoImageProcessor.normalizeLogo(
                        candidates[idx].rawImage,
                        trimMode: .auto,
                        cropRect: crop,
                        circularMask: audit.isCircularEmblem ?? false,
                        maxLongEdge: 256
                       ) {
                        let refined = BrandLogoCandidate(
                            source: candidates[idx].source,
                            sourceURL: candidates[idx].sourceURL,
                            rawImage: candidates[idx].rawImage,
                            normalizedImage: cropped.image,
                            pngData: cropped.pngData,
                            aiRecommended: true,
                            aiSuggestedCircular: audit.isCircularEmblem ?? false,
                            aiCropRect: crop,
                            aiAuditNote: audit.reason
                        )
                        candidates[idx].aiRecommended = false
                        candidates.insert(refined, at: 0)
                        recommendedID = refined.id
                    } else {
                        let chosen = candidates.remove(at: idx)
                        candidates.insert(chosen, at: 0)
                        recommendedID = chosen.id
                    }

                    if let r = audit.reason, !r.isEmpty {
                        summaryText = r
                    }
                } else if audit.isAuthentic == false || audit.selectedIndex == -1 {
                    recommendedID = nil
                    if let r = audit.reason, !r.isEmpty {
                        summaryText = L10n.t("AI 视觉提醒：\(r)", "AI Vision Warning: \(r)")
                    }
                }
            }
        }

        if candidates.isEmpty {
            let fallbackMsg: String
            if let err = aiErrorNote {
                fallbackMsg = L10n.t("未获取到可用品牌图标（AI 提示：\(err)）", "No usable brand logo found (AI: \(err))")
            } else if !aiConfig.isReady {
                fallbackMsg = L10n.t("未在已知官网找到可用图标；可在设置页开启 AI 接口以启用联网找图", "No logo found from known sites. Enable AI API in Settings for web logo discovery.")
            } else {
                fallbackMsg = L10n.t("未找到该品牌的可靠官方图标，建议手动上传或保留字母徽章", "No reliable official logo found. Consider uploading a custom icon or keeping the monogram badge.")
            }
            return AILogoSearchResult(
                brand: trimmedBrand,
                canonicalBrand: canonicalBrand,
                officialSiteURL: primaryOfficialSite,
                candidates: [],
                recommendedCandidateID: nil,
                visionVerified: false,
                summary: summaryText.isEmpty ? fallbackMsg : summaryText,
                errorMessage: fallbackMsg
            )
        }

        if summaryText.isEmpty {
            summaryText = visionVerified
                ? L10n.t("已通过 AI 联网检索并完成视觉核验（共 \(candidates.count) 个候选）", "Verified via AI web search & vision audit (\(candidates.count) candidates)")
                : L10n.t("已提取并自动去边规范化为 256px PNG（共 \(candidates.count) 个候选）", "Harvested & normalized to 256px PNG (\(candidates.count) candidates)")
        }

        return AILogoSearchResult(
            brand: trimmedBrand,
            canonicalBrand: canonicalBrand,
            officialSiteURL: primaryOfficialSite,
            candidates: candidates,
            recommendedCandidateID: recommendedID,
            visionVerified: visionVerified,
            summary: summaryText,
            errorMessage: nil
        )
    }

    private static func categoryEnglishHint(_ category: GearCategory?) -> String {
        switch category {
        case .razor: return "safety razor"
        case .blade: return "razor blade"
        case .brush: return "shaving brush"
        case .soap: return "shaving soap"
        case .preShave: return "pre-shave"
        case .afterShave: return "aftershave"
        case .bowl: return "shaving bowl"
        case nil: return "wet shaving gear"
        }
    }

    private func discoverSourcesViaAI(
        brand: String,
        category: GearCategory?,
        aiConfig: AIConfig
    ) async throws -> AILogoDiscoveryPlan? {
        let catHint = Self.categoryEnglishHint(category)
        let systemPrompt = """
        You are a traditional wet-shaving brand research assistant. Your task is to locate the authentic official website and direct brand logo image URLs for a wet-shaving brand.
        Rules:
        1. NEVER guess `<brand>.com` without verification. Avoid unrelated hotels, inns, gambling domains, or parked domains.
        2. Prefer official brand websites (including brand subpages like https://aura-craft.com/laxo/) and direct PNG/JPG/WebP logo URLs from official Shopify/WordPress/BigCommerce CDNs or major wet-shaving stockists (e.g. The Razor Company, Maggard Razors).
        3. Avoid SVG-only URLs, Etsy storefront pages, Amazon pages, Reddit, and Wikipedia.
        4. Return STRICT JSON only (no markdown fences) with schema:
        {"canonicalName": "Official Brand Name", "officialSiteURL": "https://...", "directLogoURLs": ["https://.../logo.png"], "reasoning": "Brief source note"}
        """
        let userPrompt = "Find the official website and clean brand logo image URLs for the wet-shaving brand \"\(brand)\" (category: \(catHint))."

        let completion = try await aiClient.chatCompletion(
            system: systemPrompt,
            user: userPrompt,
            config: aiConfig,
            useWebSearch: true,
            maxTokens: 600,
            temperature: 0.1
        )
        return Self.parseDiscoveryPlan(from: completion.content)
    }

    private func harvestFromWaybackArchive(originalSiteURL: URL) async -> [(url: String, source: LogoCandidateSource)] {
        let encoded = originalSiteURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? originalSiteURL.absoluteString
        var snapshotURL: URL? = nil

        if let apiURL = URL(string: "https://archive.org/wayback/available?url=\(encoded)"),
           let (data, http) = await httpFetcher.fetch(url: apiURL),
           (200...299).contains(http.statusCode),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let archived = obj["archived_snapshots"] as? [String: Any],
           let closest = archived["closest"] as? [String: Any],
           let rawSnap = closest["url"] as? String {
            let httpsSnap = rawSnap.replacingOccurrences(of: "http://web.archive.org/", with: "https://web.archive.org/")
            snapshotURL = URL(string: httpsSnap)
        }

        if snapshotURL == nil {
            snapshotURL = URL(string: "https://web.archive.org/web/2024/\(originalSiteURL.absoluteString)")
        }

        guard let targetSnap = snapshotURL,
              let (htmlData, http) = await httpFetcher.fetch(url: targetSnap),
              (200...299).contains(http.statusCode) else {
            return []
        }

        let sample = String(data: htmlData.prefix(320_000), encoding: .utf8)
            ?? String(data: htmlData.prefix(320_000), encoding: .isoLatin1)
            ?? ""
        let base = http.url ?? targetSnap
        return Self.extractSmartHTMLCandidates(html: sample, baseURL: base, isWayback: true)
    }

    private func auditCandidatesViaVision(
        brand: String,
        category: GearCategory?,
        candidates: [BrandLogoCandidate],
        aiConfig: AIConfig
    ) async -> AILogoVisionAuditResponse? {
        let numbered = candidates.enumerated().map { (idx, c) in
            (index: idx, image: c.normalizedImage, label: "\(c.source.displayName) \(c.pixelWidth)×\(c.pixelHeight)")
        }
        guard let jpegData = BrandLogoImageProcessor.buildCandidateContactSheet(candidates: numbered) else {
            return nil
        }
        let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
        let catHint = Self.categoryEnglishHint(category)
        let systemPrompt = """
        You are auditing candidate brand logo images for a traditional wet-shaving app.
        The image shows numbered logo candidates (#0, #1, ...) on a mid-gray background.
        Rules:
        1. Choose the single cleanest, most authentic brand logo for the requested wet-shaving brand.
        2. Reject unrelated businesses (hotels/inns, gambling sites, default Squarespace cubes, generic globes, press badges like 'Essential Business'). If NONE are authentic, set selectedIndex to -1 and isAuthentic to false.
        3. Prefer clean transparent brand emblems/wordmarks over busy product photos. If the best candidate is a circular badge/lid inside a square photo, set isCircularEmblem: true and optionally provide cropRect {"x0":0..1,"y0":0..1,"x1":0..1,"y1":0..1}.
        4. Return STRICT JSON only:
        {"selectedIndex": 0, "isAuthentic": true, "isCircularEmblem": false, "cropRect": null, "reason": "Short explanation"}
        """
        let userPrompt = "Audit these \(candidates.count) logo candidates for wet-shaving brand \"\(brand)\" (\(catHint))."

        do {
            let res = try await aiClient.chatCompletion(
                system: systemPrompt,
                user: userPrompt,
                imageDataURL: dataURL,
                config: aiConfig,
                useWebSearch: false,
                maxTokens: 350,
                temperature: 0.1
            )
            return Self.parseVisionAudit(from: res.content)
        } catch {
            // 文本模型（如 DeepSeek）不支持视觉时静默降级，绝不阻断找图结果
            return nil
        }
    }

    private func downloadCandidateImage(url: URL, minDimension: Int) async -> NSImage? {
        guard let (data, http) = await httpFetcher.fetch(url: url),
              (200...299).contains(http.statusCode),
              data.count > 120,
              data.count <= 8 * 1024 * 1024 else {
            return nil
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           ct.contains("text/html") || ct.contains("application/xhtml") || ct.contains("image/svg") {
            return nil
        }
        guard let img = NSImage(data: data) else { return nil }
        let w = img.representations.map(\.pixelsWide).max() ?? Int(img.size.width)
        let h = img.representations.map(\.pixelsHigh).max() ?? Int(img.size.height)
        guard w >= minDimension && h >= minDimension else { return nil }
        return img
    }

    private func normalizeSiteURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }
}
