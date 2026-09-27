import Foundation

enum BridgeFiles {
    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Media Monitor")
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { NSLog("Media Monitor: cannot create %@: %@", dir.path, error.localizedDescription) }
        return dir
    }()
    static var snapshot: URL { directory.appendingPathComponent("browser-snapshot.json") }
    static var command: URL { directory.appendingPathComponent("browser-command.json") }
    /// The extension heartbeats every second; anything older means Chrome or the host went away.
    static let snapshotTTL: TimeInterval = 5
}

/// Reads what the Chrome extension reports through the native messaging host.
final class BrowserSource {
    func poll() -> [MediaItem] {
        let url = BridgeFiles.snapshot
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < BridgeFiles.snapshotTTL,
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["items"] as? [[String: Any]] else { return [] }

        func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        func flag(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }
        func text(_ v: Any?) -> String { v as? String ?? "" }

        return entries.compactMap { e in
            // The extension sends "artist · host" (or just the host).
            var parts = text(e["subtitle"]).components(separatedBy: " · ")
            let host = parts.removeLast()
            guard let id = e["id"] as? String, !id.isEmpty,
                  let site = Targets.siteName(forHost: host) else { return nil }
            let duration = max(0, num(e["duration"]))
            let seekable = flag(e["seekable"]) && duration > 0
            let artwork = text(e["artwork"])
            return MediaItem(
                id: "browser:" + id, kind: .browser, appName: site,
                bundleID: "com.google.Chrome",
                title: text(e["title"]).isEmpty ? "网页媒体" : text(e["title"]),
                artist: parts.joined(separator: " · "),
                position: max(0, num(e["position"])), duration: duration,
                isPlaying: flag(e["playing"]), canSeek: seekable,
                canNext: flag(e["canNext"]), canPrevious: flag(e["canPrevious"]), canSkip: seekable, canFocus: true,
                artworkKey: artwork.isEmpty ? nil : artwork)
        }
    }

    func perform(_ command: MediaCommand, on item: MediaItem) {
        let id = String(item.id.dropFirst("browser:".count))
        var payload: [String: Any] = ["id": id, "nonce": UUID().uuidString]
        switch command {
        case .toggle: payload["action"] = "toggle"
        case .next: payload["action"] = "next"
        case .previous: payload["action"] = "previous"
        case .focus: payload["action"] = "focus"
        case .seek(let t): payload["action"] = "seek"; payload["value"] = max(0, t)
        case .skip(let delta):
            payload["action"] = "seek"
            payload["value"] = min(max(0, item.livePosition(at: Date()) + delta), item.duration)
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try data.write(to: BridgeFiles.command, options: .atomic)
        } catch {
            NSLog("Media Monitor: failed to write browser command: %@", error.localizedDescription)
        }
    }
}

/// Chrome launches this binary with "chrome-extension://<id>/" and speaks length-prefixed JSON over stdio.
/// Snapshots go to a file the menu bar app polls; commands the app drops in browser-command.json go back to the extension.
enum NativeHost {
    static func run() -> Never {
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        let snapshot = BridgeFiles.snapshot.path, command = BridgeFiles.command.path
        let claimed = command + ".sending"
        try? FileManager.default.removeItem(atPath: command) // never replay a stale command

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "media-monitor.native-host"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(150), leeway: .milliseconds(20))
        timer.setEventHandler {
            autoreleasepool {
                // rename() is atomic, so a command is delivered exactly once.
                guard rename(command, claimed) == 0 else { return }
                defer { try? FileManager.default.removeItem(atPath: claimed) }
                guard let body = FileManager.default.contents(atPath: claimed), !body.isEmpty,
                      (try? JSONSerialization.jsonObject(with: body)) != nil else { return }
                var length = UInt32(body.count).littleEndian
                do {
                    try output.write(contentsOf: Data(bytes: &length, count: 4))
                    try output.write(contentsOf: body)
                } catch { exit(0) }
            }
        }
        timer.resume()

        while true {
            let ok: Bool = autoreleasepool {
                guard let header = try? input.read(upToCount: 4), header.count == 4 else { return false }
                let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
                guard length <= 16 * 1024 * 1024 else { return false }
                var body = Data()
                while body.count < Int(length) {
                    guard let chunk = try? input.read(upToCount: Int(length) - body.count), !chunk.isEmpty else { return false }
                    body.append(chunk)
                }
                if (try? JSONSerialization.jsonObject(with: body)) != nil {
                    FileManager.default.createFile(atPath: snapshot + ".tmp", contents: body)
                    _ = rename(snapshot + ".tmp", snapshot)
                }
                return true
            }
            if !ok { break }
        }
        try? FileManager.default.removeItem(atPath: snapshot) // Chrome closed the port
        exit(0)
    }
}
