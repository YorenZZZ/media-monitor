import AppKit
import CoreAudio
import ApplicationServices
import IOKit.pwr_mgt

/// 汽水音乐 (Soda Music) is an Electron app with no AppleScript and no system Now Playing
/// integration, so its bottom player bar is read and driven through the Accessibility API.
final class SodaSource {
    static let bundleID = "com.soda.music"
    let queue = DispatchQueue(label: "media-monitor.soda")

    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var bar: AXUIElement?
    private var controls: [AXUIElement] = []   // previous, play/pause, next
    private var lastTitle = ""
    private var lastPosition: Double = -1
    private var lastMove = Date.distantPast
    private var lastAudible = Date.distantPast
    /// Position at a moment; while playing it runs on from there. Stands in for the bar while the bar is frozen.
    private var clock: (position: Double, at: Date)?
    private var wasPlaying = false
    /// Play/pause just sent from here, trusted over the audio signal until Chromium catches up (it lags a few seconds).
    private var override: (playing: Bool, at: Date)?
    private static let overrideHold: TimeInterval = 5

    enum Result { case none, needsPermission, item(MediaItem) }

    /// Call on `queue`.
    func poll() -> Result {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            reset(); return .none
        }
        guard AXIsProcessTrusted() else { return .needsPermission }
        if running.processIdentifier != pid { attach(running.processIdentifier) }

        let audible = AudioActivity.isAudible(bundleID: Self.bundleID)
        guard let snapshot = readBar() else {
            // Window closed to the tray: the player bar is not in the AX tree. Still show that it plays.
            guard audible else { return .none }
            return .item(MediaItem(id: "soda", kind: .soda, appName: running.localizedName ?? "汽水音乐", bundleID: Self.bundleID,
                                   title: running.localizedName ?? "汽水音乐", artist: "正在播放", isPlaying: true, canFocus: true))
        }

        // The bar only shows whole seconds, and stops repainting while the window is in the background,
        // so it counts as playing while the clock moves or while the app is producing audio.
        let now = Date()
        if snapshot.title != lastTitle { lastTitle = snapshot.title; lastPosition = -1; clock = nil }
        if snapshot.position != lastPosition { lastPosition = snapshot.position; lastMove = now; clock = (snapshot.position, now) }
        if audible { lastAudible = now }
        let clockMoving = now.timeIntervalSince(lastMove) < 2.5 && snapshot.duration > 0
        var playing = clockMoving || audible
        if let o = override { if now.timeIntervalSince(o.at) < Self.overrideHold { playing = o.playing } else { override = nil } }

        // A frozen bar keeps showing where it last repainted, so the position comes from our own clock:
        // it runs from the bar's last value while playing and stops where playback stopped.
        var c = clock ?? (snapshot.position, now)
        if playing != wasPlaying {
            if playing {
                c.at = now
            } else {
                // A bar that was still repainting stopped with the music; otherwise take the pause we sent, or the
                // last moment the app was heard.
                let stoppedAt = override.map(\.at) ?? (lastMove >= lastAudible.addingTimeInterval(-4) ? lastMove : lastAudible)
                let elapsed = max(0, stoppedAt.timeIntervalSince(c.at))
                c = (snapshot.duration > 0 ? min(c.position + elapsed, snapshot.duration) : c.position + elapsed, now)
            }
            wasPlaying = playing
        }
        if !playing { c.at = now }
        clock = c

        return .item(MediaItem(
            id: "soda", kind: .soda, appName: running.localizedName ?? "汽水音乐", bundleID: Self.bundleID,
            title: snapshot.title, artist: snapshot.artist,
            position: c.position, duration: snapshot.duration, isPlaying: playing,
            canNext: controls.count == 3, canPrevious: controls.count == 3, canFocus: true,
            artworkKey: snapshot.artwork, sampledAt: c.at))
    }

    func perform(_ command: MediaCommand, currentlyPlaying: Bool) {
        queue.async {
            if case .focus = command { return }
            guard self.controls.count == 3 else { return }
            let target: AXUIElement
            switch command {
            case .previous: target = self.controls[0]
            case .toggle:
                target = self.controls[1]
                self.override = (!currentlyPlaying, Date())
            case .next: target = self.controls[2]
            default: return
            }
            AXUIElementPerformAction(target, kAXPressAction as CFString)
        }
    }

    // MARK: - Accessibility

    private func reset() { pid = 0; app = nil; bar = nil; controls = []; lastTitle = ""; lastPosition = -1; clock = nil; wasPlaying = false }

    private func attach(_ newPid: pid_t) {
        reset()
        pid = newPid
        let element = AXUIElementCreateApplication(newPid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Chromium only builds its web accessibility tree when an assistive client asks for it.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        app = element
    }

    private struct Snapshot { var title: String; var artist: String; var position: Double; var duration: Double; var artwork: String? }

    private func readBar() -> Snapshot? {
        if bar == nil || attribute(bar!, kAXRoleAttribute) == nil { bar = findBar() }
        guard let bar else { return nil }

        var title = "", artists: [String] = [], progress = "", artwork: String?
        var controlGroup: AXUIElement?
        walk(bar, depth: 0) { element, classes in
            if classes.contains("title"), title.isEmpty {
                title = self.string(element, kAXDescriptionAttribute) ?? self.firstText(in: element) ?? ""
            } else if classes.contains("artist-link") {
                if let name = self.string(element, kAXDescriptionAttribute) ?? self.firstText(in: element), !name.isEmpty { artists.append(name) }
            } else if classes.contains("slider-tip") {
                progress = self.firstText(in: element) ?? ""
            } else if classes.contains("real-image"), artwork == nil {
                artwork = (self.attribute(element, "AXURL") as? URL)?.absoluteString
            } else if classes.contains("controls"), classes.contains("center") {
                controlGroup = element
            }
        }
        if let group = controlGroup {
            controls = children(group).filter { classList($0).contains("button") }
        }
        guard !title.isEmpty else { return nil }
        let (position, duration) = Self.parseProgress(progress)
        return Snapshot(title: title, artist: artists.joined(separator: " / "), position: position, duration: duration, artwork: artwork)
    }

    private func findBar() -> AXUIElement? {
        guard let app, let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        var found: AXUIElement?
        for window in windows where found == nil {
            walk(window, depth: 0) { element, classes in
                if found == nil, classes.contains("bottom-player") { found = element }
            }
        }
        return found
    }

    /// "02:08 / 02:37" → (128, 157)
    static func parseProgress(_ text: String) -> (Double, Double) {
        let parts = text.split(separator: "/").map { part -> Double in
            part.trimmingCharacters(in: .whitespaces).split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
        }
        return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func string(_ element: AXUIElement, _ name: String) -> String? {
        (attribute(element, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private func classList(_ element: AXUIElement) -> [String] {
        attribute(element, "AXDOMClassList") as? [String] ?? []
    }
    private func firstText(in element: AXUIElement) -> String? {
        if let v = attribute(element, kAXValueAttribute) as? String, !v.isEmpty { return v }
        for child in children(element) { if let t = firstText(in: child) { return t } }
        return nil
    }
    private func walk(_ element: AXUIElement, depth: Int, _ visit: (AXUIElement, [String]) -> Void) {
        guard depth < 40 else { return }
        visit(element, classList(element))
        for child in children(element) { walk(child, depth: depth + 1, visit) }
    }
}

/// Whether an app is producing sound, judged by Core Audio's per-process "running output" flag.
/// Unlike power assertions (which linger, and which coreaudiod holds for whichever process opened the device),
/// this follows each process's own output stream, so one player's audio never marks another as playing.
/// Electron apps (汽水音乐, 抖音) keep their output stream running after pausing, so for them Chromium's own
/// "Playing audio" assertion, which it drops within a few seconds of the media stopping, has to agree.
enum AudioActivity {
    /// Includes helper processes (bundle IDs prefixed with the app's), where most players keep their audio.
    static func isAudible(bundleID: String) -> Bool {
        guard outputProcesses().contains(where: { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }) else { return false }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard apps.contains(where: isElectron) else { return true }
        return holdsPlayingAudioAssertion(pids: Set(apps.map(\.processIdentifier)))
    }

    static func isElectron(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: isElectron)
    }

    private static var electronCache: [URL: Bool] = [:]
    private static let cacheLock = NSLock()
    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let known = electronCache[url] { return known }
        let found = FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        electronCache[url] = found
        return found
    }

    private static func holdsPlayingAudioAssertion(pids: Set<pid_t>) -> Bool {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let dict = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return false }
        return dict.contains { pid, assertions in
            pids.contains(pid.int32Value) && assertions.contains { $0[kIOPMAssertionNameKey] as? String == "Playing audio" }
        }
    }

    private static func outputProcesses() -> [(pid: pid_t, bundleID: String)] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var running: UInt32 = 0
            guard read(object, kAudioProcessPropertyIsRunningOutput, &running), running != 0 else { return nil }
            var pid: pid_t = 0
            _ = read(object, kAudioProcessPropertyPID, &pid)
            var name: Unmanaged<CFString>?
            _ = read(object, kAudioProcessPropertyBundleID, &name)
            return (pid, name.map { $0.takeRetainedValue() as String } ?? "")
        }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) } == noErr
    }
}
