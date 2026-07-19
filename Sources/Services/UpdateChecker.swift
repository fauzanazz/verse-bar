import Foundation
import AppKit

/// Checks the GitHub releases API for a newer Verse Bar build and exposes
/// the result so the UI can surface an "Update available" affordance.
///
/// Compares `CFBundleShortVersionString` against the latest release tag
/// (`v1.2.3` → `1.2.3`) using a simple numeric semver comparison.
final class UpdateChecker {
    static let shared = UpdateChecker()

    static let updateStateChanged = Notification.Name("UpdateCheckerStateChanged")

    enum State: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(latest: String, current: String, url: URL)
        case failed(message: String)
    }

    private(set) var state: State = .idle {
        didSet {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: UpdateChecker.updateStateChanged, object: nil)
            }
        }
    }

    /// GitHub releases API endpoint for the project.
    private let releasesAPI = URL(string: "https://api.github.com/repos/fauzanazz/verse-bar/releases/latest")!
    /// Public releases page (opened when user clicks "Download").
    private let releasesPage = URL(string: "https://github.com/fauzanazz/verse-bar/releases/latest")!

    private var inFlight: URLSessionDataTask?

    /// Current short version string from Info.plist, e.g. "1.2.0".
    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// Check for a newer release.
    ///
    /// - Parameter manual: When true the user invoked the check explicitly
    ///   (so we surface up-to-date / failure states). When false we only
    ///   announce when an update is available.
    func check(manual: Bool = false) {
        if case .checking = state { return }
        state = .checking

        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("VerseBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        let current = currentVersion
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                Logger.error("Update check failed", category: "general", error: error)
                self.state = manual ? .failed(message: error.localizedDescription) : .idle
                return
            }
            // No published releases yet → GitHub returns 404. That's a normal
            // "nothing to update to" state, not an error.
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                Logger.info("No releases published yet (up to date at \(current))", category: "general")
                self.state = .upToDate(current: current)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                Logger.error("Update check: invalid response", category: "general")
                self.state = manual ? .failed(message: "Invalid response from GitHub.") : .idle
                return
            }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? self.releasesPage

            if Self.compareVersions(latest, current) > 0 {
                Logger.info("Update available: \(latest) (current \(current))", category: "general")
                self.state = .updateAvailable(latest: latest, current: current, url: htmlURL)
            } else {
                Logger.info("Up to date (\(current))", category: "general")
                self.state = .upToDate(current: current)
            }
        }
        inFlight = task
        task.resume()
    }

    /// Manual check that surfaces results via an alert + opens the release
    /// page when an update is available.
    func checkManually() {
        let onChange: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            switch self.state {
            case .checking, .idle:
                return
            case .upToDate(let current):
                self.removeManualObserver()
                self.presentUpToDate(current: current)
            case .updateAvailable(let latest, let current, let url):
                self.removeManualObserver()
                self.presentUpdateAvailable(latest: latest, current: current, url: url)
            case .failed(let message):
                self.removeManualObserver()
                self.presentFailure(message: message)
            }
        }
        manualObserver = NotificationCenter.default.addObserver(
            forName: UpdateChecker.updateStateChanged,
            object: nil,
            queue: .main,
            using: onChange
        )
        check(manual: true)
    }

    private var manualObserver: NSObjectProtocol?
    private func removeManualObserver() {
        if let token = manualObserver {
            NotificationCenter.default.removeObserver(token)
            manualObserver = nil
        }
    }

    // MARK: - Presentation

    private func presentUpToDate(current: String) {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Verse Bar \(current) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentUpdateAvailable(latest: String, current: String, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = "Verse Bar \(latest) is available (you have \(current)). Open the release page to download?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentFailure(message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Version comparison

    /// Returns 1 if `a > b`, -1 if `a < b`, 0 if equal. Numeric component
    /// comparison; missing components treated as 0. Pre-release suffixes
    /// (anything after `-`) are stripped before comparison.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let lhs = stripPrerelease(a).split(separator: ".").map { Int($0) ?? 0 }
        let rhs = stripPrerelease(b).split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l > r { return 1 }
            if l < r { return -1 }
        }
        return 0
    }

    private static func stripPrerelease(_ s: String) -> String {
        if let dash = s.firstIndex(of: "-") {
            return String(s[..<dash])
        }
        return s
    }
}
