import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var updateStatus: String = ""
    @State private var isCheckingUpdate: Bool = false

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }
    private var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Elegant top gradient bar
            LinearGradient(gradient: Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)]), startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 60)
                .overlay(
                    HStack {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verse Bar Preferences")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                            Text("Configure playback syncing and display options")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                )
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // Display Options Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("MENU BAR RENDER OPTIONS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Zen Mode (lyrics only)", isOn: $settings.zenMode)
                            Toggle("Show Artist Name", isOn: $settings.showArtist)
                            Toggle("Show Track Title", isOn: $settings.showTitle)
                            Toggle("Show Realtime Lyrics Line", isOn: $settings.showLyrics)
                            Toggle("Show Music Island (Dynamic Island under notch)", isOn: $settings.showNotchIsland)
                            Toggle("Romanize Korean / Japanese / Chinese lyrics", isOn: $settings.showRomanization)
                        }
                        .toggleStyle(.checkbox)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03).cornerRadius(10))
                    }
                    
                    // Active Syncing Sources Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ACTIVE SOURCES TO POLL")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Arc Browser (YouTube Music Tab)", isOn: $settings.trackingArc)
                            Toggle("Safari Browser (YouTube Music Tab)", isOn: $settings.trackingSafari)
                            Toggle("Google Chrome Browser (YouTube Music Tab)", isOn: $settings.trackingChrome)
                            Toggle("YouTube Music Desktop App (Localhost Server)", isOn: $settings.trackingYTMDesktop)
                        }
                        .toggleStyle(.checkbox)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03).cornerRadius(10))
                    }
                    
                    // Integrations Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("INTEGRATIONS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Show current track on Discord", isOn: $settings.discordPresenceEnabled)
                            Text("Requires the Discord desktop app")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .toggleStyle(.checkbox)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03).cornerRadius(10))
                    }

                    // General Options Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("GENERAL OPTIONS")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Start Verse Bar at Login", isOn: $settings.launchAtLogin)
                                .onChange(of: settings.launchAtLogin) { _, newValue in
                                    configureLoginItem(enabled: newValue)
                                }
                            HStack {
                                Button("Re-run Setup Guide") {
                                    NotificationCenter.default.post(name: Notification.Name("ShowOnboardingWindow"), object: nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Spacer()
                                Button("Quit Verse Bar", role: .destructive) {
                                    NSApplication.shared.terminate(nil)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 4)
                        }
                        .toggleStyle(.checkbox)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03).cornerRadius(10))
                    }
                    
                    // App version + update check
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ABOUT VERSE BAR")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Version \(appVersion) (build \(buildNumber))")
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    if !updateStatus.isEmpty {
                                        Text(updateStatus)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Button(action: {
                                    isCheckingUpdate = true
                                    updateStatus = "Checking…"
                                    UpdateChecker.shared.checkManually()
                                }) {
                                    Text(isCheckingUpdate ? "Checking…" : "Check for Updates")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(isCheckingUpdate)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03).cornerRadius(10))
                        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.updateStateChanged)) { _ in
                            switch UpdateChecker.shared.state {
                            case .idle:
                                isCheckingUpdate = false
                            case .checking:
                                isCheckingUpdate = true
                                updateStatus = "Checking…"
                            case .upToDate(let current):
                                isCheckingUpdate = false
                                updateStatus = "Up to date (v\(current))."
                            case .updateAvailable(let latest, _, _):
                                isCheckingUpdate = false
                                updateStatus = "Update available — v\(latest)."
                            case .failed(let message):
                                isCheckingUpdate = false
                                updateStatus = "Check failed: \(message)"
                            }
                        }
                    }

                    // Realtime JS Timing Guide Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("💡 REALTIME LYRIC TIMING GUIDE")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("To sync lyrics with millisecond precision, Verse Bar needs browser permission to query the media timer. Enable this setting in your preferred browser:")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("• **Arc Browser:** Go to *Arc* in top menu bar > *Developer* > check **'Allow JavaScript from Apple Events'**.")
                                Text("• **Google Chrome:** Go to *Developer* menu in top menu bar and check **'Allow JavaScript from Apple Events'**.")
                                Text("• **Safari:** Open Safari Settings > Advanced, check **'Show Develop menu in menu bar'**, then in the *Develop* menu check **'Allow JavaScript from Apple Events'**.")
                            }
                            .font(.system(size: 11, design: .rounded))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            
                            Text("*If disabled, Verse Bar falls back to smart wall-clock estimation which still works out-of-the-box!*")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.06).cornerRadius(10))
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func configureLoginItem(enabled: Bool) {
        // Modern login item setup (requires ServiceManagement framework integration)
        // Here we log the state and update preferences, the launcher does the work.
        Logger.info("Login item state changed: \(enabled)", category: "general")
    }
}
