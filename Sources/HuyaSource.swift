import AppKit
import ApplicationServices

/// 虎牙直播 desktop client (kiwihd). It reports nothing to the system Now Playing feed, keeps its audio stream
/// running while paused, and never changes its pause button, so whether it plays is judged by what it actually
/// sounds like; the room title and streamer are read from its window through the Accessibility API.
/// It cannot be controlled from here: its pause button ignores AXPress and synthetic keys, and only takes a click
/// while its auto-hiding control bar is on screen, so play/pause just brings the client forward.
final class HuyaSource {
    static let bundleID = "com.yy.kiwihd"
    let queue = DispatchQueue(label: "media-monitor.huya")

    private let level = AudioLevelMonitor()
    private var lastSound = Date.distantPast
    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var room: (title: String, streamer: String)?
    private var roomReadAt = Date.distantPast

    /// A stream counts as playing while it has been heard within this long; speech and music have short gaps.
    private static let silenceGrace: TimeInterval = 3
    /// Level (0...1, perceptual) above which the output is sound rather than silence.
    private static let soundThreshold: Float = 0.02

    /// Call on `queue`.
    func poll() -> MediaItem? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            if pid != 0 { level.follow(bundleID: nil); pid = 0; app = nil; room = nil }
            return nil
        }
        if running.processIdentifier != pid {
            pid = running.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            app = element
            level.follow(bundleID: Self.bundleID)
        }

        let now = Date()
        if level.takeLevel() > Self.soundThreshold { lastSound = now }
        let playing = now.timeIntervalSince(lastSound) < Self.silenceGrace

        // A live room's window holds thousands of chat messages; reading it every tick would starve the level check.
        if now.timeIntervalSince(roomReadAt) > 5 {
            roomReadAt = now
            room = AXIsProcessTrusted() ? readRoom() : nil
        }
        return MediaItem(
            id: "huya", kind: .huya, appName: "虎牙直播", bundleID: Self.bundleID,
            title: room?.title ?? "虎牙直播", artist: room?.streamer ?? "", isPlaying: playing, canFocus: true)
    }

    // MARK: - Accessibility

    /// The player's controls, in window order: … [btn icon live refresh] <room title> …
    /// [关注 | n] <streamer>. Labels live in AXDescription. They sit five levels below the window; the chat
    /// messages sit deeper and are skipped.
    private func readRoom() -> (title: String, streamer: String)? {
        guard let app, let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var title = "", streamer = ""
        var after: String?
        for window in windows where title.isEmpty {
            walk(window, depth: 0) { element in
                let role = attribute(element, kAXRoleAttribute) as? String
                let label = (attribute(element, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (attribute(element, kAXValueAttribute) as? String) ?? ""
                if role == kAXButtonRole as String {
                    after = label.hasPrefix("btn icon live refresh") ? "title" : label.hasPrefix("关注") ? "streamer" : nil
                } else if role == kAXStaticTextRole as String, let field = after, !label.isEmpty {
                    if field == "title", title.isEmpty { title = label } else if field == "streamer", streamer.isEmpty { streamer = label }
                    after = nil
                }
            }
        }
        return title.isEmpty && streamer.isEmpty ? nil : (title.isEmpty ? "虎牙直播" : title, streamer)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Void) {
        guard depth <= 6 else { return }
        visit(element)
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth: depth + 1, visit) }
    }
}
