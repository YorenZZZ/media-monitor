import AppKit
import Combine

/// Merges all sources into one list. Each source polls on its own queue so a slow one
/// (a hung AppleScript target, a busy Electron renderer) never stalls the others or the UI.
final class MediaStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published var selectedID: String?
    @Published private(set) var needsAccessibility = false
    /// The popover shows the settings page instead of the players; kept across popover openings.
    @Published var showSettings = false

    private let browser = BrowserSource()
    private let soda = SodaSource()
    private let huya = HuyaSource()
    private let system = SystemNowPlayingSource()
    private let fileQueue = DispatchQueue(label: "media-monitor.browser")

    private var browserItems: [MediaItem] = []
    private var sodaItem: MediaItem?
    private var huyaItem: MediaItem?
    private var systemState: SystemNowPlayingSource.State?
    /// Last state of every target app the system reported. macOS only reports one Now Playing app, so when a
    /// newer app takes over, the older one is kept here and shown for as long as it keeps producing audio.
    private var systemHistory: [String: SystemNowPlayingSource.State] = [:]
    /// When each item started playing; the most recent one leads, so pausing it falls back to the previous one.
    private var playStarted: [String: Date] = [:]
    /// When the Now Playing app last said "playing" while not actually sounding (see `checkedAgainstAudio`).
    private var silentSince: (date: Date, elapsed: Double)?
    private var timer: Timer?
    private var inFlight = Set<String>()
    /// Play/pause the user just asked for, held until the source reports it (sources lag by up to a second or two),
    /// so a stale sample cannot flip the item back and reshuffle the list meanwhile.
    private var pendingPlaying: [String: (playing: Bool, until: Date)] = [:]

    /// Hero of the popover: the user's pick, else the first (playing-first) item.
    var selected: MediaItem? { items.first { $0.id == selectedID } ?? items.first }
    /// What the status bar shows: only something that is actually playing.
    var nowPlaying: MediaItem? { items.first { $0.isPlaying } }

    /// Static store for --render-preview; starts no sources.
    init(preview: [MediaItem]) { items = preview }

    init() {
        system.onChange = { [weak self] state in
            guard let self else { return }
            self.systemState = state.map(self.checkedAgainstAudio)
            if let state, Targets.apps[state.bundleID] != nil { self.systemHistory[state.bundleID] = state }
            self.merge()
        }
        system.start()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
    }

    func shutdown() { system.stop() }

    /// MediaRemote has been seen to go stale for 抖音: "playing" long after a pause, the clock running past the
    /// video's end. For Electron apps Chromium's "Playing audio" assertion is the ground truth, so a "playing"
    /// report without it for a few seconds is taken as paused, frozen where the silence began.
    private func checkedAgainstAudio(_ state: SystemNowPlayingSource.State) -> SystemNowPlayingSource.State {
        var s = state
        guard s.playing, AudioActivity.isElectron(bundleID: s.bundleID), !AudioActivity.isAudible(bundleID: s.bundleID) else {
            silentSince = nil; return s
        }
        let now = Date()
        let since = silentSince ?? (now, s.duration > 0 ? min(s.elapsed, s.duration) : s.elapsed)
        silentSince = since
        guard now.timeIntervalSince(since.date) > 4 else { return s }
        s.playing = false; s.elapsed = since.elapsed
        return s
    }

    func refresh() {
        poll("browser", on: fileQueue, browser.poll) { self.browserItems = $0 }
        poll("huya", on: huya.queue, huya.poll) { self.huyaItem = $0 }
        poll("soda", on: soda.queue, soda.poll) { result in
            switch result {
            case .none: self.sodaItem = nil; self.needsAccessibility = false
            case .needsPermission: self.sodaItem = nil; self.needsAccessibility = true
            case .item(let item): self.sodaItem = item; self.needsAccessibility = false
            }
        }
    }

    /// Skips a source whose previous poll has not returned yet instead of queueing up behind it.
    private func poll<T>(_ name: String, on queue: DispatchQueue, _ work: @escaping () -> T, apply: @escaping (T) -> Void) {
        guard !inFlight.contains(name) else { return }
        inFlight.insert(name)
        queue.async {
            let value = work()
            DispatchQueue.main.async {
                self.inFlight.remove(name)
                apply(value)
                self.merge()
            }
        }
    }

    private func merge() {
        var all = browserItems
        if let sodaItem { all.append(sodaItem) }
        if let huyaItem { all.append(huyaItem) }

        if let s = systemState {
            if let index = all.firstIndex(where: { $0.bundleID == s.bundleID && $0.kind != .browser }) {
                // Already covered by a richer source: just borrow the system artwork.
                if all[index].artworkKey == nil { all[index].artworkKey = s.artworkKey }
            } else if s.bundleID == "com.google.Chrome", !browserItems.isEmpty {
                // The extension reports Chrome media per tab; lend the artwork to the playing one if it has none.
                if let index = all.firstIndex(where: { $0.kind == .browser && $0.isPlaying && $0.artworkKey == nil }) {
                    all[index].artworkKey = s.artworkKey
                }
            } else if s.bundleID == "com.google.Chrome" {
                // Extension not connected: still show a target site from Chrome's own entry.
                if let site = Targets.siteName(forChromeTitle: s.title) {
                    all.append(MediaItem(
                        id: "system:" + s.bundleID, kind: .system, appName: site, bundleID: s.bundleID,
                        title: s.title, position: s.elapsed, duration: s.duration, isPlaying: s.playing,
                        canSeek: s.duration > 0, canFocus: true, artworkKey: s.artworkKey, sampledAt: s.sampledAt))
                }
            } else if let name = Targets.apps[s.bundleID] {
                all.append(MediaItem(
                    id: "system:" + s.bundleID, kind: .system, appName: name, bundleID: s.bundleID,
                    title: s.title, artist: s.artist, position: s.elapsed, duration: s.duration, isPlaying: s.playing,
                    canSeek: s.duration > 0, canNext: true, canPrevious: true, canFocus: true,
                    artworkKey: s.artworkKey, sampledAt: s.sampledAt))
            }
        }

        all += backgroundSystemItems(excluding: Set(all.map(\.bundleID)))
        all = all.map(Self.simplified)

        let now = Date()
        for (index, item) in all.enumerated() {
            guard let pending = pendingPlaying[item.id] else { continue }
            if item.isPlaying == pending.playing || now >= pending.until { pendingPlaying[item.id] = nil; continue }
            if let shown = items.first(where: { $0.id == item.id }) {
                all[index].position = shown.livePosition(at: now); all[index].sampledAt = now
            }
            all[index].isPlaying = pending.playing
        }
        pendingPlaying = pendingPlaying.filter { id, _ in all.contains { $0.id == id } }
        for item in all {
            if item.isPlaying { if playStarted[item.id] == nil { playStarted[item.id] = now } } else { playStarted[item.id] = nil }
        }
        playStarted = playStarted.filter { id, _ in all.contains { $0.id == id } }

        all.sort { a, b in
            if a.isPlaying != b.isPlaying { return a.isPlaying }
            if a.isPlaying, let ta = playStarted[a.id], let tb = playStarted[b.id], ta != tb { return ta > tb }
            if a.kind != b.kind { return a.kind < b.kind }
            return a.id < b.id
        }
        // A picked item that stops playing hands the hero back to whatever is still playing.
        if let id = selectedID, let now = all.first(where: { $0.id == id }) {
            let wasPlaying = items.first { $0.id == id }?.isPlaying ?? false
            if wasPlaying && !now.isPlaying && all.contains(where: \.isPlaying) { selectedID = nil }
        } else { selectedID = nil }
        if all != items { items = all }
        writeDebugState()
    }

    /// 抖音 reports a generic page title and a clock that jumps between feed videos, so it is shown as just
    /// the app with play/pause.
    private static func simplified(_ item: MediaItem) -> MediaItem {
        guard item.kind == .system, item.bundleID == "com.bytedance.douyin.desktop" else { return item }
        var s = item
        s.title = item.appName; s.artist = ""; s.position = 0; s.duration = 0; s.artworkKey = nil
        s.canSeek = false; s.canNext = false; s.canPrevious = false; s.canSkip = false
        return s
    }

    /// Target apps that are no longer the system's Now Playing app. One that still holds an audio
    /// assertion is still playing; otherwise it is frozen as paused until the app quits.
    private func backgroundSystemItems(excluding covered: Set<String>) -> [MediaItem] {
        let current = systemState?.bundleID
        var result: [MediaItem] = []
        for (bundleID, state) in systemHistory where bundleID != current {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
                systemHistory[bundleID] = nil; continue
            }
            guard !covered.contains(bundleID), let name = Targets.apps[bundleID] else { continue }
            // Audio activity decides both ways: an app resumed from its own window is playing again.
            var s = state
            let audible = AudioActivity.isAudible(bundleID: bundleID)
            if s.playing != audible {
                if s.playing { s.elapsed = s.duration > 0 ? min(s.elapsed + Date().timeIntervalSince(s.sampledAt), s.duration) : s.elapsed }
                s.sampledAt = Date(); s.playing = audible
                systemHistory[bundleID] = s
            }
            // Transport commands would reach the current Now Playing app, so only "open app" is offered.
            result.append(MediaItem(
                id: "system:" + bundleID, kind: .system, appName: name, bundleID: bundleID,
                title: s.title, artist: s.artist, position: s.elapsed, duration: s.duration, isPlaying: s.playing,
                canFocus: true, artworkKey: s.artworkKey, sampledAt: s.sampledAt))
        }
        return result
    }

    /// Writes what the app currently sees to state.json, so the merge can be inspected without the GUI.
    private var lastDebug = ""
    private func writeDebugState() {
        let lines = items.map { "\($0.id)\t\($0.isPlaying ? "playing" : "paused")\t\($0.title)\t\($0.artist)\t\(Int($0.position))/\(Int($0.duration))\t\($0.artworkKey ?? "-")" }
        var text = lines.joined(separator: "\n")
        text += "\nneedsAccessibility=\(needsAccessibility) system=\(systemState.map { "\($0.bundleID) \($0.title) playing=\($0.playing)" } ?? "none")\n"
        guard text != lastDebug else { return }
        lastDebug = text
        try? text.write(to: BridgeFiles.directory.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    }

    func perform(_ command: MediaCommand, on item: MediaItem) {
        switch item.kind {
        case .browser:
            browser.perform(command, on: item)
            if case .focus = command { activate(item.bundleID) }
        case .soda:
            if case .focus = command { activate(item.bundleID) } else { soda.perform(command, currentlyPlaying: item.isPlaying) }
        case .huya:
            activate(item.bundleID); return
        case .system:
            if case .focus = command { activate(item.bundleID) }
            else if let current = systemState?.bundleID, current != item.bundleID {
                // A background app cannot be controlled through the system feed; bring it forward instead.
                activate(item.bundleID); return
            } else { system.perform(command) }
        }
        applyOptimistically(command, to: item)
        // Pick up the real state quickly instead of waiting for the next tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.refresh() }
    }

    /// Reflect the command immediately so buttons and progress respond without lag.
    private func applyOptimistically(_ command: MediaCommand, to item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items[index]
        let now = Date()
        switch command {
        case .toggle:
            // merge() applies it, so ordering and hero hand-off see the change like any other.
            pendingPlaying[item.id] = (!updated.isPlaying, now.addingTimeInterval(3))
            merge(); return
        case .seek(let t):
            updated.position = t; updated.sampledAt = now
        case .skip(let d):
            updated.position = min(max(0, updated.livePosition(at: now) + d), updated.duration); updated.sampledAt = now
        default: return
        }
        items[index] = updated
    }

    private func activate(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
