import AppKit

enum SourceKind: Int, Comparable {
    case soda, bilibili, system, huya, browser
    static func < (a: SourceKind, b: SourceKind) -> Bool { a.rawValue < b.rawValue }
}

enum MediaCommand: Equatable {
    case toggle, next, previous, seek(Double), skip(Double), focus
}

struct MediaItem: Identifiable, Equatable {
    let id: String
    let kind: SourceKind
    let appName: String
    let bundleID: String
    var title: String
    var artist: String = ""
    var position: Double = 0
    var duration: Double = 0
    var isPlaying: Bool = false
    var canSeek: Bool = false
    var canNext: Bool = false
    var canPrevious: Bool = false
    var canSkip: Bool = false
    var canFocus: Bool = false
    /// Remote URL string, or "mr:<id>" for artwork delivered by the system Now Playing helper.
    var artworkKey: String?
    var sampledAt = Date()

    /// Icon to show: a web item borrows its site's desktop app icon when that app is installed.
    var iconBundleID: String {
        if bundleID == "com.google.Chrome", let app = Targets.siteIcons[appName],
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil { return app }
        return bundleID
    }
    var subtitle: String { artist.isEmpty ? appName : artist }
    /// Live streams (虎牙, B 站直播) have no finite duration.
    var isLive: Bool { kind == .browser && duration == 0 }
    var marqueeText: String { artist.isEmpty ? title : "\(title) — \(artist)" }

    /// Position extrapolated from the last sample so progress moves smoothly between polls.
    func livePosition(at date: Date) -> Double {
        let p = isPlaying ? position + date.timeIntervalSince(sampledAt) : position
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }
}

/// The only players Media Monitor tracks.
enum Targets {
    /// Desktop apps read through the system Now Playing feed (汽水音乐 has its own richer source).
    static let apps: [String: String] = [
        "com.bytedance.douyin.desktop": "抖音",
        "com.bilibili.bilibiliPC": "哔哩哔哩",
        "cn.toside.music.desktop": "LX Music",
        "com.colliderli.iina": "IINA",
        "com.soda.music": "汽水音乐",
        "com.yy.kiwihd": "虎牙直播",
    ]
    /// Web players in Chrome with a known name, matched by host suffix; other sites show their host.
    static let sites: [(suffix: String, name: String)] = [
        ("bilibili.com", "哔哩哔哩"),
        ("huya.com", "虎牙直播"),
        ("douyin.com", "抖音"),
    ]
    /// Desktop app whose icon stands in for a site's tab, when installed.
    static let siteIcons = ["哔哩哔哩": "com.bilibili.bilibiliPC", "抖音": "com.bytedance.douyin.desktop"]
    static func siteName(forHost host: String) -> String {
        if let known = sites.first(where: { host == $0.suffix || host.hasSuffix("." + $0.suffix) }) { return known.name }
        if host.hasPrefix("www.") { return String(host.dropFirst(4)) }
        return host.isEmpty ? "网页" : host
    }
    /// Fallback when the extension is not connected: Chrome's own Now Playing entry, recognised by its tab title.
    static func siteName(forChromeTitle title: String) -> String? {
        let t = title.lowercased()
        if t.contains("bilibili") || t.contains("哔哩哔哩") { return "哔哩哔哩" }
        if t.contains("虎牙") || t.contains("huya") { return "虎牙直播" }
        if t.contains("抖音") || t.contains("douyin") { return "抖音" }
        return nil
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let t = Int(seconds)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

func appIcon(bundleID: String) -> NSImage {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return NSWorkspace.shared.icon(forFile: url.path)
    }
    return NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) ?? NSImage()
}

/// Loads and caches artwork images plus an accent color derived from each.
final class ArtworkCache: ObservableObject {
    static let shared = ArtworkCache()
    @Published private(set) var images: [String: NSImage] = [:]
    private(set) var accents: [String: NSColor] = [:]
    private var loading = Set<String>()
    private var retryAfter: [String: Date] = [:]
    private var order: [String] = []

    func image(for key: String?) -> NSImage? {
        guard let key else { return nil }
        if let image = images[key] { return image }
        if !loading.contains(key), Date() >= retryAfter[key] ?? .distantPast,
           let url = URL(string: key), ["http", "https"].contains(url.scheme ?? "") {
            loading.insert(key)
            URLSession.shared.dataTask(with: url) { data, _, _ in
                DispatchQueue.main.async {
                    self.loading.remove(key)
                    if let data, let image = NSImage(data: data) { self.store(image, for: key) }
                    else { self.retryAfter[key] = Date().addingTimeInterval(30) }
                }
            }.resume()
        }
        return nil
    }

    func accent(for key: String?) -> NSColor? { key.flatMap { accents[$0] } }

    func store(_ image: NSImage, for key: String) {
        guard images[key] == nil else { return }
        accents[key] = Self.dominantColor(of: image)
        images[key] = image
        order.append(key)
        // Keep memory bounded: artwork churns as tracks change.
        while order.count > 40 { let old = order.removeFirst(); images[old] = nil; accents[old] = nil; loading.remove(old); retryAfter[old] = nil }
    }

    /// Picks the most vivid of a coarse 8×8 sampling rather than a muddy average.
    static func dominantColor(of image: NSImage) -> NSColor? {
        let size = 8
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        var best: NSColor?
        var bestScore: CGFloat = -1
        for i in 0..<(size * size) {
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let score = s * 0.7 + b * 0.3 - (b < 0.2 ? 1 : 0)
            if score > bestScore { bestScore = score; best = NSColor(hue: h, saturation: min(1, max(0.45, s)), brightness: max(0.72, b), alpha: 1) }
        }
        return best
    }
}
