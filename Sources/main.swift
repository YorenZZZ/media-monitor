import AppKit
import Combine
import SwiftUI

// Chrome launches this same binary as its native messaging host.
if CommandLine.arguments.count > 1,
   CommandLine.arguments[1].hasPrefix("chrome-extension://") || CommandLine.arguments[1] == "--native-host" {
    NativeHost.run()
}

// Debug: show the popover with sample data in a window for screenshots.
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--render-preview" {
    MainActor.assumeIsolated { runPreview(dark: CommandLine.arguments.contains("--dark")) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = MediaStore()
    private var statusBar: StatusBarController!
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ChromeExtension.prepare()
        statusBar = StatusBarController(target: self, action: #selector(togglePopover))
        let host = NSHostingController(rootView: PopoverView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.statusBar.show(self?.store.nowPlaying) }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusBar.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        store.selectedID = nil
        store.refresh()
        statusBar.isPopoverShown = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        statusBar.isPopoverShown = false
        statusBar.show(store.nowPlaying)
    }

    func applicationWillTerminate(_ notification: Notification) { store.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
