import SwiftUI
import AppKit

/// First-run onboarding flow. Four steps:
///   1. Welcome / install location check
///   2. Automation permission (browsers + YTM Desktop)
///   3. Notification permission
///   4. Ready to play
struct OnboardingView: View {
    @ObservedObject var settings = AppSettings.shared

    @State private var step: Int = 0
    @State private var inApplications: Bool = PermissionHelper.isInApplicationsFolder()

    @State private var safariAuto: PermissionStatus = .notDetermined
    @State private var chromeAuto: PermissionStatus = .notDetermined
    @State private var arcAuto: PermissionStatus = .notDetermined

    @State private var notifStatus: PermissionStatus = .notDetermined

    var onFinish: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch step {
                case 0: welcomeStep
                case 1: automationStep
                case 2: notificationStep
                default: doneStep
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 560, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear(perform: refreshAll)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.75)]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Player Studio")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Let's get synced lyrics working in ~30 seconds.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.9))
                }
                Spacer()
                stepDots
            }
            .padding(.horizontal, 24)
        }
        .frame(height: 84)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i <= step ? Color.white : Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Step 0 — welcome / install location

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Step 1 — Install location")
            stepHint("Player Studio should run from your Applications folder so macOS keeps permissions stable across updates.")

            HStack(spacing: 12) {
                Image(systemName: inApplications ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(inApplications ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(inApplications ? "Installed in Applications" : "Not in Applications folder")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(inApplications
                         ? "You're good. Ready to set up permissions."
                         : "Quit Player Studio, drag the app into /Applications, then reopen it.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Color.primary.opacity(0.04).cornerRadius(10))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.accentColor)
                    Text("If macOS said \"Player Studio was blocked\"")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                Text("The app is ad-hoc signed but not notarized. Open Terminal and run this command once to clear the warning for good:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("xattr -dr com.apple.quarantine \"/Applications/Player Studio.app\"")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.06).cornerRadius(6))
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString("xattr -dr com.apple.quarantine \"/Applications/Player Studio.app\"", forType: .string)
                    }
                    .controlSize(.small)
                }
                Text("Or open the app once, then go to System Settings → Privacy & Security → Open Anyway.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06).cornerRadius(10))

            Spacer()
        }
    }

    // MARK: - Step 1 — automation

    private var automationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Step 2 — Automation")
            stepHint("Player Studio reads the YouTube Music tab via AppleScript. macOS will ask once per browser. Tap each button — accept the prompt.")

            permRow(title: "Safari",       status: safariAuto)  { askAutomation("com.apple.Safari") }
            permRow(title: "Google Chrome", status: chromeAuto) { askAutomation("com.google.Chrome") }
            permRow(title: "Arc",          status: arcAuto)     { askAutomation("company.thebrowser.Browser") }

            HStack {
                Spacer()
                Button("Open Automation Settings") {
                    PermissionHelper.openAutomationSettings()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(.top, 4)

            Spacer()
        }
    }

    // MARK: - Step 2 — notifications

    private var notificationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Step 3 — Notifications (optional)")
            stepHint("Get a banner when the track changes. Skip if you'd rather keep things quiet.")

            HStack(spacing: 12) {
                Image(systemName: statusIcon(notifStatus))
                    .font(.system(size: 26))
                    .foregroundColor(statusColor(notifStatus))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Track-change banners")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(statusLabel(notifStatus))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if notifStatus == .denied {
                    Button("Open Settings") {
                        PermissionHelper.openNotificationSettings()
                    }
                } else if notifStatus != .granted {
                    Button("Enable") {
                        PermissionHelper.requestNotifications { _ in
                            refreshNotifications()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.04).cornerRadius(10))

            Spacer()
        }
    }

    // MARK: - Step 3 — done

    private var doneStep: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Color.green.opacity(0.15)).frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.green)
            }
            Text("You're all set")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Play a track on music.youtube.com — the lyric will appear in your menu bar within a second or two.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button(action: openYTM) {
                Label("Open YouTube Music", systemImage: "play.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step < 3 {
                Button("Skip") { advance() }
                    .buttonStyle(.borderless)
                Button(step == 0 ? "Get Started" : "Continue") { advance() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Helpers

    private func stepTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 16, weight: .bold, design: .rounded))
    }

    private func stepHint(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func permRow(title: String, status: PermissionStatus, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon(status))
                .font(.system(size: 20))
                .foregroundColor(statusColor(status))
                .frame(width: 24)
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            Text(statusLabel(status))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Button(status == .granted ? "Re-test" : "Request") {
                action()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04).cornerRadius(8))
    }

    private func statusIcon(_ s: PermissionStatus) -> String {
        switch s {
        case .granted:        return "checkmark.circle.fill"
        case .denied:         return "xmark.octagon.fill"
        case .notDetermined:  return "questionmark.circle"
        case .unknown:        return "minus.circle"
        }
    }

    private func statusColor(_ s: PermissionStatus) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .orange
        case .unknown: return .secondary
        }
    }

    private func statusLabel(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "Granted"
        case .denied: return "Denied — open Settings"
        case .notDetermined: return "Not requested yet"
        case .unknown: return "Unknown"
        }
    }

    private func advance() {
        if step < 3 { step += 1 }
        if step == 1 { refreshAutomation() }
        if step == 2 { refreshNotifications() }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        onFinish()
    }

    private func refreshAll() {
        inApplications = PermissionHelper.isInApplicationsFolder()
        refreshAutomation()
        refreshNotifications()
    }

    private func refreshAutomation() {
        PermissionHelper.probeAutomation(for: "com.apple.Safari")        { safariAuto = $0 }
        PermissionHelper.probeAutomation(for: "com.google.Chrome")       { chromeAuto = $0 }
        PermissionHelper.probeAutomation(for: "company.thebrowser.Browser") { arcAuto = $0 }
    }

    private func refreshNotifications() {
        PermissionHelper.probeNotifications { notifStatus = $0 }
    }

    private func askAutomation(_ bundleId: String) {
        PermissionHelper.probeAutomation(for: bundleId) { _ in
            refreshAutomation()
        }
    }

    private func openYTM() {
        if let url = URL(string: "https://music.youtube.com") {
            NSWorkspace.shared.open(url)
        }
    }
}
