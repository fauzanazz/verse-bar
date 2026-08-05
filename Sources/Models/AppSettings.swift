import Foundation
import Combine

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    
    @Published var trackingSafari: Bool {
        didSet { UserDefaults.standard.set(trackingSafari, forKey: "trackingSafari") }
    }
    
    @Published var trackingChrome: Bool {
        didSet { UserDefaults.standard.set(trackingChrome, forKey: "trackingChrome") }
    }
    
    @Published var trackingYTMDesktop: Bool {
        didSet { UserDefaults.standard.set(trackingYTMDesktop, forKey: "trackingYTMDesktop") }
    }
    
    @Published var trackingArc: Bool {
        didSet { UserDefaults.standard.set(trackingArc, forKey: "trackingArc") }
    }
    
    @Published private var manualSyncOffsetsByTrack: [String: TimeInterval] {
        didSet { UserDefaults.standard.set(manualSyncOffsetsByTrack, forKey: "manualSyncOffsetsByTrack") }
    }

    @Published var pinPopover: Bool {
        didSet { UserDefaults.standard.set(pinPopover, forKey: "pinPopover") }
    }

    @Published var zenMode: Bool {
        didSet { UserDefaults.standard.set(zenMode, forKey: "zenMode") }
    }

    @Published var showNotchIsland: Bool {
        didSet { UserDefaults.standard.set(showNotchIsland, forKey: "showNotchIsland") }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    @Published var showRomanization: Bool {
        didSet { UserDefaults.standard.set(showRomanization, forKey: "showRomanization") }
    }

    @Published var discordPresenceEnabled: Bool {
        didSet { UserDefaults.standard.set(discordPresenceEnabled, forKey: "discordPresenceEnabled") }
    }

    @Published var downloadFolderPath: String {
        didSet { UserDefaults.standard.set(downloadFolderPath, forKey: "downloadFolderPath") }
    }

    @Published var playerVolume: Double {
        didSet { UserDefaults.standard.set(playerVolume, forKey: "playerVolume") }
    }

    /// Offline library folder (default: ~/Music/Player Studio).
    var downloadFolder: URL {
        URL(fileURLWithPath: (downloadFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            "launchAtLogin": false,
            "trackingSafari": true,
            "trackingChrome": true,
            "trackingArc": true,
            "trackingYTMDesktop": true,
            "pinPopover": false,
            "zenMode": true,
            "showNotchIsland": false,
            "hasCompletedOnboarding": false,
            "showRomanization": true,
            "discordPresenceEnabled": false,
            "downloadFolderPath": "~/Music/Player Studio",
            "playerVolume": 1.0
        ])

        self.launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
        self.trackingSafari = UserDefaults.standard.bool(forKey: "trackingSafari")
        self.trackingChrome = UserDefaults.standard.bool(forKey: "trackingChrome")
        self.trackingArc = UserDefaults.standard.bool(forKey: "trackingArc")
        self.trackingYTMDesktop = UserDefaults.standard.bool(forKey: "trackingYTMDesktop")
        self.manualSyncOffsetsByTrack = UserDefaults.standard.dictionary(forKey: "manualSyncOffsetsByTrack")?
            .compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        UserDefaults.standard.removeObject(forKey: "manualSyncOffset")
        self.pinPopover = UserDefaults.standard.bool(forKey: "pinPopover")
        self.zenMode = UserDefaults.standard.bool(forKey: "zenMode")
        self.showNotchIsland = UserDefaults.standard.bool(forKey: "showNotchIsland")
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.showRomanization = UserDefaults.standard.bool(forKey: "showRomanization")
        self.discordPresenceEnabled = UserDefaults.standard.bool(forKey: "discordPresenceEnabled")
        self.downloadFolderPath = UserDefaults.standard.string(forKey: "downloadFolderPath") ?? "~/Music/Player Studio"
        self.playerVolume = UserDefaults.standard.double(forKey: "playerVolume")
    }

    func manualSyncOffset(for track: Track) -> TimeInterval {
        manualSyncOffsetsByTrack[track.syncOffsetKey] ?? 0.0
    }

    func setManualSyncOffset(_ offset: TimeInterval, for track: Track) {
        if offset == 0.0 {
            manualSyncOffsetsByTrack.removeValue(forKey: track.syncOffsetKey)
        } else {
            manualSyncOffsetsByTrack[track.syncOffsetKey] = offset
        }
    }
}
