import AppKit
import SwiftUI

/// `--render-preview [--dark] [--settings]`: shows PopoverView with sample sessions in a real window (so materials and
/// vibrancy render as in the popover), prints its window number for `screencapture -l`, then exits.
@MainActor func runPreview(dark: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let now = Date()
    let art = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
        NSGradient(colors: [NSColor(red: 0.95, green: 0.35, blue: 0.45, alpha: 1), NSColor(red: 0.35, green: 0.2, blue: 0.75, alpha: 1)])?.draw(in: rect, angle: 45)
        return true
    }
    ArtworkCache.shared.store(art, for: "preview-art")
    let store = MediaStore(preview: selectHero([
        MediaItem(id: "soda", kind: .soda, appName: "汽水音乐", bundleID: "com.soda.music", title: "And I", artist: "Starry",
                  position: 128, duration: 157, isPlaying: true, canNext: true, canPrevious: true, canFocus: true,
                  artworkKey: "preview-art", sampledAt: now),
        MediaItem(id: "browser:2:0:1", kind: .browser, appName: "虎牙直播", bundleID: "com.google.Chrome",
                  title: "【英雄联盟】巅峰赛冲分中", artist: "某主播", isPlaying: true, canFocus: true, sampledAt: now),
        MediaItem(id: "browser:1:0:1", kind: .browser, appName: "哔哩哔哩", bundleID: "com.google.Chrome",
                  title: "猫和老鼠 旧版-番剧-全集-高清正版在线观看-bilibili-哔哩哔哩",
                  position: 133, duration: 402, canSeek: true, canSkip: true, canFocus: true, sampledAt: now),
        MediaItem(id: "system:com.colliderli.iina", kind: .system, appName: "IINA", bundleID: "com.colliderli.iina",
                  title: "Interstellar.2014.mkv", position: 3100, duration: 10140, canSeek: true, canNext: true, canPrevious: true,
                  canFocus: true, sampledAt: now),
        MediaItem(id: "system:com.bytedance.douyin.desktop", kind: .system, appName: "抖音", bundleID: "com.bytedance.douyin.desktop",
                  title: "抖音", isPlaying: true, canFocus: true, sampledAt: now),
    ]))
    store.showSettings = CommandLine.arguments.contains("--settings")
    let host = NSHostingView(rootView: PopoverView(store: store))
    host.frame.size = host.fittingSize
    let effect = NSVisualEffectView(frame: host.frame)
    effect.material = .popover
    effect.state = .active
    effect.addSubview(host)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = effect
    window.level = .floating
    window.setFrameOrigin(NSPoint(x: 60, y: 120))
    window.orderFrontRegardless()
    print(window.windowNumber)
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    app.run()
}

/// `--hero=<id>` puts that sample first (e.g. `--hero=browser:2` for the live layout).
@MainActor private func selectHero(_ items: [MediaItem]) -> [MediaItem] {
    guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--hero=") }) else { return items }
    let id = String(arg.dropFirst("--hero=".count))
    return items.sorted { a, _ in a.id.hasPrefix(id) }
}
