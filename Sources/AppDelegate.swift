import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        let currentPID = ProcessInfo.processInfo.processIdentifier
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.playerstudio.PlayerStudio")
            .contains(where: { $0.processIdentifier < currentPID }) {
            NSApp.terminate(nil)
            return
        }

        // Notification authorization is handled by the onboarding flow on
        // first launch. After that we no-op — the user already made a choice.
        if AppSettings.shared.hasCompletedOnboarding {
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }

        // Spawn the MediaRemote helper so /usr/bin/swift starts streaming
        // Now Playing info before the first poll arrives.
        NowPlayingService.shared.start()

        // Initialize StatusItemManager to load the status bar item and start tracking
        _ = StatusItemManager.shared

        // Initialize the Music Island overlay (it is hidden until the user
        // enables the toggle in Preferences and something is playing).
        _ = NotchIslandController.shared
        _ = ListeningStatsService.shared
        _ = AudioPlayerService.shared
        _ = LibraryService.shared
        DiscordPresenceService.shared.start()

        // Observe window presentation requests
        NotificationCenter.default.addObserver(self, selector: #selector(showPreferences), name: Notification.Name("ShowSettingsWindow"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showSoundCapsule), name: Notification.Name("ShowPlayerStudioSoundCapsule"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showNowPlayingPane), name: Notification.Name("TogglePlayerStudioLyricsWindow"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showOnboardingWindow), name: Notification.Name("ShowOnboardingWindow"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showMainWindow), name: Notification.Name("ShowMainWindow"), object: nil)

        // Show the first-run setup window if the user hasn't finished it.
        DispatchQueue.main.async {
            OnboardingController.shared.showIfNeeded()
        }

        // Quietly check for a newer release on launch. Surface results only
        // if an update is actually available (the menu will reflect state).
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            UpdateChecker.shared.check(manual: false)
        }

        Logger.info("Player Studio application launched.", category: "general")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ListeningStatsService.shared.flush()
        DiscordPresenceService.shared.stop()
        AudioPlayerService.shared.saveState()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    @objc func showMainWindow() {
        MainWindowController.shared.show()
    }

    @objc func showOnboardingWindow() {
        OnboardingController.shared.show()
    }
    
    @objc func showPreferences() {
        MainWindowController.shared.show(section: .settings)
    }

    /// The app ships without a menu bar (popover-first), but the main window
    /// still needs standard shortcuts: Settings… is ⌘,, Quit is ⌘Q.
    private func installMainMenu() {
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Player Studio",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Player Studio",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Player Studio",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc func showSoundCapsule() {
        MainWindowController.shared.show(section: .capsule)
    }

    @objc func showNowPlayingPane() {
        MainWindowController.shared.show(nowPlaying: true)
    }
}
