import AppKit
import SwiftUI

/// The main player window (sidebar + transport bar). Menu-bar-first app: the
/// window opens from the status menu or the Dock icon, never at launch.
final class MainWindowController: NSObject {
    static let shared = MainWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show(section: MainSection? = nil, nowPlaying: Bool? = nil) {
        if let section { MainWindowRouter.shared.section = section }
        if let nowPlaying { MainWindowRouter.shared.showNowPlaying = nowPlaying }
        LibraryService.shared.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Player Studio"
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 560)
        window.contentViewController = NSHostingController(rootView: MainWindowView())
        if !window.setFrameUsingName("PlayerStudioMainWindow") { window.center() }
        window.setFrameAutosaveName("PlayerStudioMainWindow")

        self.window = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mainWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: closed)
        window = nil
        Logger.info("Main window closed.", category: "general")
    }
}
