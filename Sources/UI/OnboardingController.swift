import Cocoa
import SwiftUI

/// Hosts the first-run onboarding window. The window is shown automatically
/// on first launch (when `AppSettings.hasCompletedOnboarding` is false) and
/// can also be reopened from the Preferences gear.
final class OnboardingController: NSObject {
    static let shared = OnboardingController()

    private var window: NSWindow?

    func showIfNeeded() {
        if AppSettings.shared.hasCompletedOnboarding { return }
        show()
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Player Studio Setup"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        let view = OnboardingView(onFinish: { [weak self] in
            self?.window?.close()
        })
        window.contentViewController = NSHostingController(rootView: view)

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    @objc private func windowWillClose(_ note: Notification) {
        if let w = note.object as? NSWindow, w == window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: w)
            window = nil
        }
    }
}
