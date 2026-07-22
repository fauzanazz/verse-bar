import Cocoa
import SwiftUI
import Combine

class StatusItemManager: NSObject {
    static let shared = StatusItemManager()
    
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var lyricsWindow: NSWindow?
    private var capsuleWindow: NSWindow?
    
    private var playbackEngine = PlaybackEngine.shared
    private var lyricsService = LyricsService.shared
    private var settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    
    // Dedicated timer for smooth menu bar updates
    private var menuBarUpdateTimer: Timer?
    
    private override init() {
        super.init()
        setupStatusItem()
        setupPopover()
        setupBindings()
        startMenuBarUpdateTimer()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            
            // Native monochrome template icon: automatically turns white on dark bars and black on light bars!
            if let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Verse Bar") {
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

        guard let window = lyricsWindow else { return }
        let minimumSize = settings.zenMode
            ? NSSize(width: 240, height: 120)
            : NSSize(width: 280, height: 300)
        window.minSize = minimumSize
        window.setContentSize(size)
    }
    
    private func setupBindings() {
        // Observe track changes
        playbackEngine.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarText()
            }
            .store(in: &cancellables)
        
        // Observe lyric line changes
        lyricsService.$currentLineIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarText()
            }
            .store(in: &cancellables)
        
        // Observe lyric lines loaded
        lyricsService.$lyricLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarText()
            }
            .store(in: &cancellables)
        
        // Observe display setting changes
        settings.$showArtist
            .combineLatest(settings.$showTitle, settings.$showLyrics)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarText()
            }
            .store(in: &cancellables)

        // Touch Bar tap → toggle popover
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(togglePopoverFromNotification),
            name: Notification.Name("ToggleVerseBarPopover"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showSoundCapsule),
            name: Notification.Name("ShowVerseBarSoundCapsule"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toggleLyricsWindow),
            name: Notification.Name("ToggleVerseBarLyricsWindow"),
            object: nil
        )
    }

    @objc private func togglePopoverFromNotification() {
        togglePopover()
    }

    @objc private func toggleLyricsWindow() {
        if let window = lyricsWindow {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let size = settings.zenMode
            ? NSSize(width: 300, height: 180)
            : NSSize(width: 320, height: 380)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Verse Bar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = settings.zenMode
            ? NSSize(width: 240, height: 120)
            : NSSize(width: 280, height: 300)
        window.contentViewController = NSHostingController(rootView: PopoverView(isWindowed: true))
        if !window.setFrameUsingName("VerseBarLyricsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("VerseBarLyricsWindow")

        lyricsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSoundCapsule() {
        if let window = capsuleWindow {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 360, height: 520)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sound Capsule"
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 320, height: 420)
        window.contentViewController = NSHostingController(rootView: SoundCapsuleView())
        if !window.setFrameUsingName("VerseBarCapsuleWindow") {
            window.center()
        }
        window.setFrameAutosaveName("VerseBarCapsuleWindow")

        capsuleWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // Timer for smooth text transitions in the menu bar
    private func startMenuBarUpdateTimer() {
        menuBarUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateMenuBarText()
        }
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

        let capsuleItem = NSMenuItem(title: "Sound Capsule...", action: #selector(showSoundCapsule), keyEquivalent: "")
        capsuleItem.target = self
        menu.addItem(capsuleItem)

        let updateItem = NSMenuItem(title: updateMenuItemTitle(), action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Verse Bar", action: #selector(quitApp), keyEquivalent: "q")
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
        
        var displayString = ""
        
        // 1. If lyrics are enabled and we have an active lyric line, show that
        if settings.showLyrics,
           !lyricsService.lyricLines.isEmpty,
           let activeIdx = lyricsService.currentLineIndex,
           activeIdx >= 0 && activeIdx < lyricsService.lyricLines.count {
            let activeLine = lyricsService.lyricLines[activeIdx]
            let activeLineText: String
            if settings.showRomanization, let romanized = activeLine.romanized {
                activeLineText = romanized
            } else {
                activeLineText = activeLine.text
            }
            if !activeLineText.isEmpty {
                displayString = activeLineText
            }
        }
        
        // 2. If lyrics are enabled but this track has no synced lyrics, show
        //    only the icon — the "not found" message lives in the popup, not
        //    the menu bar.
        if displayString.isEmpty && settings.showLyrics {
            switch lyricsService.status {
            case .plainFound, .notFound, .unavailableOffline, .error:
                button.title = ""
                return
            default:
                break
            }
        }

        // 3. If no lyrics line showing, build title/artist
        if displayString.isEmpty {
            var elements: [String] = []
            if settings.showTitle {
                elements.append(track.title)
            }
            if settings.showArtist {
                elements.append(track.artist)
            }
            displayString = elements.joined(separator: " - ")
        }
        
        // Capping lyric line length at 40 characters for responsive, clean status bar look
        let maxChars = 40
        if displayString.count > maxChars {
            let index = displayString.index(displayString.startIndex, offsetBy: maxChars - 3)
            button.title = String(displayString[..<index]) + "..."
        } else {
            button.title = displayString
        }
    }
}
