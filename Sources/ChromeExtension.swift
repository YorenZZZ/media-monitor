import AppKit

/// The bundled Chrome extension (Contents/Resources/ChromeExtension) and the native messaging host it talks to.
/// Chrome no longer lets another program load an unpacked extension (--load-extension is ignored since Chrome 137),
/// so installing means: copy the extension to a stable folder, open chrome://extensions, and show the folder in
/// Finder for the user to drag in with Developer mode on. Everything else is done here.
enum ChromeExtension {
    static let chromeBundleID = "com.google.Chrome"
    /// Fixed by the "key" in the extension's manifest.json.
    static let extensionID = "ggkooakbkljmenacmfoaofcdjccdlnbm"
    static let hostName = "io.github.yorenzzz.media_monitor"

    private static var chromeSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome")
    }
    /// Where the extension is loaded from. Outside the app bundle, so replacing the app never breaks Chrome's path.
    static var installedFolder: URL { BridgeFiles.directory.appendingPathComponent("ChromeExtension") }
    private static var bundledFolder: URL? { Bundle.main.url(forResource: "ChromeExtension", withExtension: nil) }

    static var chromeURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: chromeBundleID) }

    /// Whether any Chrome profile has the extension (enabled or not).
    static var isInstalled: Bool {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: chromeSupport, includingPropertiesForKeys: nil)) ?? []
        return profiles.contains { profile in
            ["Secure Preferences", "Preferences"].contains { name in
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any] else { return false }
                return settings[extensionID] != nil
            }
        }
    }

    /// Called at launch: points Chrome's native host entry at this copy of the app, and refreshes the loaded
    /// extension's files when the app was updated (Chrome picks them up on its next start).
    static func prepare() {
        registerNativeHost()
        if FileManager.default.fileExists(atPath: installedFolder.path) { copyExtension() }
    }

    enum InstallResult { case chromeMissing, opened }

    static func install() -> InstallResult {
        guard let chrome = chromeURL else { return .chromeMissing }
        registerNativeHost()
        copyExtension()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let page = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open([page], withApplicationAt: chrome, configuration: configuration)
        }
        NSWorkspace.shared.activateFileViewerSelecting([installedFolder])
        return .opened
    }

    private static func copyExtension() {
        guard let source = bundledFolder else { return }
        let fm = FileManager.default
        let staging = installedFolder.deletingLastPathComponent().appendingPathComponent("ChromeExtension.new")
        do {
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: installedFolder.path) {
                _ = try fm.replaceItemAt(installedFolder, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: installedFolder)
            }
        } catch {
            NSLog("Media Monitor: cannot copy the Chrome extension: %@", error.localizedDescription)
        }
    }

    private static func registerNativeHost() {
        guard let executable = Bundle.main.executablePath, FileManager.default.fileExists(atPath: chromeSupport.path) else { return }
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Media Monitor local browser bridge",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let folder = chromeSupport.appendingPathComponent("NativeMessagingHosts")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
            let file = folder.appendingPathComponent(hostName + ".json")
            if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        } catch {
            NSLog("Media Monitor: cannot register the native messaging host: %@", error.localizedDescription)
        }
    }
}
