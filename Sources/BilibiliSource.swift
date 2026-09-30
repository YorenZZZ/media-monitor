import AppKit
import ApplicationServices

/// The Bilibili desktop player does not consistently publish a macOS Now Playing session.
/// Its player window exposes the title, clock and transport buttons through Accessibility.
final class BilibiliSource {
    static let bundleID = "com.bilibili.bilibiliPC"
    let queue = DispatchQueue(label: "media-monitor.bilibili")

    enum Result { case none, needsPermission, item(MediaItem) }

    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var playButton: AXUIElement?
    private var nextButton: AXUIElement?
    private var lastPosition: Double = -1
    private var lastTitle = ""
    private var lastMove = Date.distantPast
    private var override: (playing: Bool, at: Date)?

    /// Call on `queue`.
    func poll() -> Result {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            reset()
            return .none
        }
        guard AXIsProcessTrusted() else { return .needsPermission }
        if running.processIdentifier != pid {
            reset()
            pid = running.processIdentifier
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.5)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            app = element
        }
        guard let snapshot = readPlayer() else {
            playButton = nil
            nextButton = nil
            return .none
        }

        let now = Date()
        if snapshot.title != lastTitle {
            lastTitle = snapshot.title
            lastPosition = -1
            lastMove = .distantPast
        }
        if snapshot.position != lastPosition {
            if lastPosition >= 0, snapshot.position > lastPosition { lastMove = now }
            lastPosition = snapshot.position
        }
        let audible = AudioActivity.isAudible(bundleID: Self.bundleID)
        var playing = audible || now.timeIntervalSince(lastMove) < 2.5
        if let pending = override {
            if now.timeIntervalSince(pending.at) < 3 { playing = pending.playing }
            else { override = nil }
        }
        return .item(MediaItem(
            id: "bilibili", kind: .bilibili, appName: running.localizedName ?? "哔哩哔哩",
            bundleID: Self.bundleID, title: snapshot.title,
            position: snapshot.position, duration: snapshot.duration, isPlaying: playing,
            canNext: nextButton != nil, canFocus: true, sampledAt: now))
    }

    func perform(_ command: MediaCommand, currentlyPlaying: Bool) {
        queue.async {
            let target: AXUIElement?
            switch command {
            case .toggle:
                target = self.playButton
                if target != nil { self.override = (!currentlyPlaying, Date()) }
            case .next: target = self.nextButton
            default: return
            }
            if let target { AXUIElementPerformAction(target, kAXPressAction as CFString) }
        }
    }

    private func reset() {
        pid = 0; app = nil; playButton = nil; nextButton = nil
        lastPosition = -1; lastTitle = ""; lastMove = .distantPast; override = nil
    }

    private struct Snapshot { let title: String; let position: Double; let duration: Double }

    private func readPlayer() -> Snapshot? {
        guard let app, let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            let title = string(window, kAXTitleAttribute) ?? ""
            guard !title.isEmpty else { continue }
            var play: AXUIElement?
            var next: AXUIElement?
            var progress: (Double, Double)?
            walk(window, depth: 0) { element in
                let role = self.string(element, kAXRoleAttribute)
                if role == kAXButtonRole as String {
                    let label = self.string(element, kAXTitleAttribute)
                        ?? self.string(element, kAXDescriptionAttribute) ?? ""
                    if label == "播放/暂停" { play = element }
                    else if label == "下一个" { next = element }
                } else if role == kAXStaticTextRole as String, progress == nil,
                          let value = self.string(element, kAXValueAttribute),
                          let parsed = Self.parseProgress(value) {
                    progress = parsed
                }
            }
            guard let play else { continue }
            playButton = play
            nextButton = next
            return Snapshot(title: title, position: progress?.0 ?? 0, duration: progress?.1 ?? 0)
        }
        return nil
    }

    /// Player clock, e.g. "0:22:47 / 1:11:16".
    static func parseProgress(_ text: String) -> (Double, Double)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        func seconds(_ part: Substring) -> Double? {
            let fields = part.trimmingCharacters(in: .whitespaces).split(separator: ":")
            let values = fields.compactMap { Int($0) }
            guard (2...3).contains(fields.count), values.count == fields.count,
                  values.allSatisfy({ $0 >= 0 }),
                  values.dropFirst().allSatisfy({ (0...59).contains($0) }) else { return nil }
            return Double(values.reduce(0) { $0 * 60 + $1 })
        }
        guard let position = seconds(parts[0]), let duration = seconds(parts[1]),
              duration > 0, position <= duration else { return nil }
        return (position, duration)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func string(_ element: AXUIElement, _ name: String) -> String? {
        (attribute(element, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement) -> Void) {
        guard depth <= 8 else { return }
        visit(element)
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            walk(child, depth: depth + 1, visit)
        }
    }
}
