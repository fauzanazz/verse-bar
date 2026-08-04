import Cocoa
import UserNotifications

/// Status of a single permission required by Player Studio.
enum PermissionStatus {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// Centralised permission probing + deep-link helpers so the onboarding flow
/// can guide the user straight to the right pane in System Settings.
enum PermissionHelper {

    // MARK: - Install location

    /// True when the running binary lives inside `/Applications` (or the
    /// per-user `~/Applications`). Onboarding nudges the user to move the
    /// app there if it is still in `~/Downloads` or a DMG mount.
    static func isInApplicationsFolder() -> Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    // MARK: - Automation (AppleScript / Apple Events)

    /// Probe Automation permission for a given target app by issuing a tiny
    /// AppleScript that asks for its name. macOS will surface the consent
    /// prompt the first time this is called for each target.
    static func probeAutomation(for bundleId: String, completion: @escaping (PermissionStatus) -> Void) {
        let script = "tell application id \"\(bundleId)\" to return name"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            _ = appleScript?.executeAndReturnError(&error)

            let status: PermissionStatus
            if let err = error {
                let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                switch code {
                case -1743:        status = .denied        // user declined
                case -1744:        status = .notDetermined // not yet asked
                case 0:            status = .granted
                default:           status = .unknown
                }
            } else {
                status = .granted
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: - Notifications

    static func probeNotifications(completion: @escaping (PermissionStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status: PermissionStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .granted
            case .denied:                                status = .denied
            case .notDetermined:                         status = .notDetermined
            @unknown default:                            status = .unknown
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    static func requestNotifications(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - System Settings deep links

    static func openAutomationSettings() {
        openSettings(url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    static func openNotificationSettings() {
        openSettings(url: "x-apple.systempreferences:com.apple.preference.notifications")
    }

    private static func openSettings(url: String) {
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}
