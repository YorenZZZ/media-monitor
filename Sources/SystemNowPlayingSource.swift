import AppKit

/// The app macOS considers "Now Playing" (what Control Center shows), read through
/// Resources/libNowPlayingHelper.dylib hosted by /usr/bin/perl — see Helper/NowPlayingHelper.m.
final class SystemNowPlayingSource {
    struct State {
        var bundleID: String
        var appName: String
        var title: String
        var artist: String
        var duration: Double
        var elapsed: Double
        var playing: Bool
        var artworkKey: String?
        var sampledAt: Date
    }

    var onChange: ((State?) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restartDelay: TimeInterval = 1
    private var stopped = false
    private let queue = DispatchQueue(label: "media-monitor.now-playing")

    func start() {
        queue.async { self.launch() }
    }

    func stop() {
        queue.sync { stopped = true; process?.terminate(); process = nil }
    }

    func perform(_ command: MediaCommand) {
        let line: String
        switch command {
        case .toggle: line = "toggle"
        case .next: line = "next"
        case .previous: line = "previous"
        case .seek(let t): line = "seek \(max(0, t))"
        default: return
        }
        queue.async { try? self.input?.write(contentsOf: Data((line + "\n").utf8)) }
    }

    private func launch() {
        guard let dylib = Bundle.main.url(forResource: "libNowPlayingHelper", withExtension: "dylib") else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use DynaLoader; DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();", dylib.path]
        p.environment = ["MEDIA_MONITOR_NOW_PLAYING": "1", "PATH": "/usr/bin:/bin"]
        let stdout = Pipe(), stdin = Pipe()
        p.standardOutput = stdout
        p.standardInput = stdin
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            self?.queue.async { self?.consume(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.process = nil
                guard !self.stopped else { return }
                DispatchQueue.main.async { self.onChange?(nil) }
                // Keep trying, but back off if the helper cannot run at all.
                self.queue.asyncAfter(deadline: .now() + self.restartDelay) { self.launch() }
                self.restartDelay = min(self.restartDelay * 2, 60)
            }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
        } catch {
            NSLog("Media Monitor: cannot start Now Playing helper: %@", error.localizedDescription)
        }
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            restartDelay = 1
            handle(json)
        }
    }

    private func handle(_ json: [String: Any]) {
        let pid = (json["pid"] as? NSNumber)?.int32Value ?? 0
        var artworkImage: NSImage?
        if let b64 = json["artwork"] as? String, let data = Data(base64Encoded: b64) { artworkImage = NSImage(data: data) }
        let artworkID = json["artworkId"] as? String

        DispatchQueue.main.async {
            let playing = (json["playing"] as? NSNumber)?.boolValue ?? false
            let reported = json["title"] as? String ?? ""
            // Some apps (e.g. 抖音) publish playback state without metadata; still show them while they play,
            // and keep a tracked app while paused too, or it could not be resumed from here.
            guard pid > 0, let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier,
                  !reported.isEmpty || playing || Targets.apps[bundleID] != nil else { self.onChange?(nil); return }
            let title = reported.isEmpty ? (app.localizedName ?? bundleID) : reported
            var key: String?
            if let artworkID {
                key = "mr:" + artworkID
                if let artworkImage { ArtworkCache.shared.store(artworkImage, for: key!) }
            }
            self.onChange?(State(
                bundleID: bundleID, appName: app.localizedName ?? bundleID, title: title,
                artist: json["artist"] as? String ?? "",
                duration: (json["duration"] as? NSNumber)?.doubleValue ?? 0,
                elapsed: (json["elapsed"] as? NSNumber)?.doubleValue ?? 0,
                playing: playing,
                artworkKey: key, sampledAt: Date()))
        }
    }
}
