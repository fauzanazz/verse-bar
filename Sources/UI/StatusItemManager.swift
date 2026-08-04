import Cocoa
import SwiftUI
import Combine

class StatusItemManager: NSObject {
    static let shared = StatusItemManager()
    
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    
    private var playbackEngine = PlaybackEngine.shared
    private var settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    
    private override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        setupBindings()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            
            // Menu bar glyph derived from the app logo — monochrome template
            // image: automatically turns white on dark bars and black on light bars!
            let menuBarIcon: NSImage? = {
                if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    image.size = NSSize(width: 18, height: 18)
                    return image
                }
                return nil
            }()
            if let image = menuBarIcon ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "Player Studio") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageRight
            }
            
            updateMenuBarText()
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        applyPopoverSize()
        applyPopoverBehavior()

        // PopoverHostingController vends an NSTouchBar so the lyric appears in the
        // MacBook Pro Touch Bar whenever the popover is open.
        let popoverContent = PopoverView()
        popover.contentViewController = PopoverHostingController(rootView: popoverContent)

        // Re-apply popover behavior whenever the user toggles the Pin setting,
        // so Touch Bar lyric can persist across app switches when pinned.
        settings.$pinPopover
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPopoverBehavior() }
            .store(in: &cancellables)

        settings.$zenMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyPopoverSize() }
            .store(in: &cancellables)
    }

    private func applyPopoverBehavior() {
        // .applicationDefined keeps the popover open across app switches —
        // required for the Touch Bar lyric to remain visible while you work
        // in another app. .transient is the standard menu-bar-app behavior.
        popover.behavior = settings.pinPopover ? .applicationDefined : .transient
    }

    private func applyPopoverSize() {
        let size = settings.zenMode
            ? NSSize(width: 300, height: 180)
            : NSSize(width: 320, height: 380)
        popover.contentSize = size
    }
    
    private func setupBindings() {
        // Observe track changes
        playbackEngine.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarText()
            }
            .store(in: &cancellables)
        
        // Observe display setting changes
        settings.$showArtist
            .combineLatest(settings.$showTitle)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarText()
            }
            .store(in: &cancellables)

        // Touch Bar tap → toggle popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(togglePopoverFromNotification),
            name: Notification.Name("TogglePlayerStudioPopover"),
            object: nil
        )
    }

    @objc private func togglePopoverFromNotification() {
        togglePopover()
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            // Show a quick context menu on right click
            showContextMenu()
        } else {
            togglePopover()
        }
    }
    
    private func togglePopover() {
        guard let button = statusItem.button else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    private func showContextMenu() {
        let menu = NSMenu()
        let windowItem = NSMenuItem(title: "Open Player Studio…", action: #selector(openMainWindow), keyEquivalent: "o")
        windowItem.target = self
        menu.addItem(windowItem)
        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(
            title: settings.zenMode ? "Switch to Normal Mode" : "Switch to Zen Mode",
            action: #selector(toggleZenMode),
            keyEquivalent: ""
        )
        modeItem.target = self
        menu.addItem(modeItem)


        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let capsuleItem = NSMenuItem(title: "Sound Capsule...", action: #selector(postShowSoundCapsule), keyEquivalent: "")
        capsuleItem.target = self
        menu.addItem(capsuleItem)

        let updateItem = NSMenuItem(title: updateMenuItemTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Player Studio", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // Reset so next left-click opens popover
    }

    @objc private func toggleZenMode() {
        settings.zenMode.toggle()
    }

    private func updateMenuItemTitle() -> String {
        if case .updateAvailable(let latest, _, _) = UpdateChecker.shared.state {
            return "Update Available — v\(latest)…"
        }
        return "Check for Updates…"
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: Notification.Name("ShowSettingsWindow"), object: nil)
    }

    @objc private func postShowSoundCapsule() {
        NotificationCenter.default.post(name: Notification.Name("ShowPlayerStudioSoundCapsule"), object: nil)
    }

    @objc private func openMainWindow() {
        NotificationCenter.default.post(name: Notification.Name("ShowMainWindow"), object: nil)
    }

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkManually()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Menu Bar Styling & Truncation
    private func updateMenuBarText() {
        guard let button = statusItem.button else { return }
        
        // Default idle state (only show icon, no text)
        guard let track = playbackEngine.currentTrack else {
            button.title = ""
            return
        }
        
        var elements: [String] = []
        if settings.showTitle { elements.append(track.title) }
        if settings.showArtist { elements.append(track.artist) }
        let displayString = elements.joined(separator: " - ")
        
        // Cap at 40 characters for a responsive, clean status bar look
        let maxChars = 40
        if displayString.count > maxChars {
            let index = displayString.index(displayString.startIndex, offsetBy: maxChars - 3)
            button.title = String(displayString[..<index]) + "..."
        } else {
            button.title = displayString
        }
    }
}
