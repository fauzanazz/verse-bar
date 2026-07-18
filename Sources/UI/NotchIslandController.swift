import Cocoa
import SwiftUI
import Combine

/// Manages the floating "Music Island" panel that displays the current lyric
/// docked under the menu bar notch. On notched MacBooks the pill visually
/// wraps the physical notch; on non-notched displays it floats just below the
/// menu bar at top-center.
///
/// The panel is borderless, non-activating, joins all spaces, and sits at
/// `.statusBar` level so it remains visible across app switches without
/// stealing focus from the active app.
final class NotchIslandController: NSObject {
    static let shared = NotchIslandController()

    /// View-model is owned by the controller so hover state is single-sourced
    /// and we can absorb edge ping-pong with a debounce before resizing.
    final class ViewModel: ObservableObject {
        @Published var isExpanded: Bool = false
    }

    private var panel: NSPanel?
    private var hostingView: NSHostingView<NotchIslandView>?
    private var cancellables = Set<AnyCancellable>()
    private let viewModel = ViewModel()

    private let settings = AppSettings.shared
    private let playbackEngine = PlaybackEngine.shared
    private let lyricsService = LyricsService.shared

    /// Compact pill dimensions (excluding any notch reservation).
    private let compactBodyHeight: CGFloat = 30
    /// Expanded pill dimensions.
    private let expandedBodyHeight: CGFloat = 96
    /// Minimum pill widths (further widened on notched displays so the pill
    /// extends comfortably past the physical notch).
    private let minCompactWidth: CGFloat = 260
    private let minExpandedWidth: CGFloat = 520
    /// Lateral overhang each side of the physical notch.
    private let notchOverhang: CGFloat = 44

    /// Resolved notch metrics for the active screen.
    private var notchHeight: CGFloat = 0
    private var notchWidth: CGFloat = 0

    /// Debounce work item for hover-out → collapse.
    private var collapseWorkItem: DispatchWorkItem?
    /// Delay before collapsing after pointer leaves — absorbs spurious
    /// hover toggles caused by SwiftUI re-layout during resize.
    private let collapseDelay: TimeInterval = 0.18

    private override init() {
        super.init()
        bindSettings()
        applyVisibility()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func bindSettings() {
        settings.$showNotchIsland
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyVisibility() }
            .store(in: &cancellables)

        // Reposition / resize as track presence changes (so we can hide the
        // pill when nothing is playing).
        playbackEngine.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyVisibility() }
            .store(in: &cancellables)

        lyricsService.$currentLineIndex
            .combineLatest(lyricsService.$lyricLines, settings.$showRomanization)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.repositionPanel(expanded: self.viewModel.isExpanded)
            }
            .store(in: &cancellables)
    }

    @objc private func screenParametersChanged() {
        guard panel != nil else { return }
        resolveNotchMetrics()
        repositionPanel(expanded: viewModel.isExpanded)
    }

    // MARK: - Visibility

    private func applyVisibility() {
        let wantsVisible = settings.showNotchIsland && playbackEngine.currentTrack != nil
        if wantsVisible {
            ensurePanel()
            panel?.orderFrontRegardless()
        } else {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            viewModel.isExpanded = false
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        resolveNotchMetrics()

        let frame = computeFrame(expanded: false)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        let view = NotchIslandView(
            viewModel: viewModel,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            onHoverChange: { [weak self] inside in
                self?.handleHoverChange(inside)
            }
        )
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        self.panel = panel
        self.hostingView = host
    }

    // MARK: - Hover handling

    private func handleHoverChange(_ inside: Bool) {
        if inside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            guard !viewModel.isExpanded else { return }
            viewModel.isExpanded = true
            repositionPanel(expanded: true)
        } else {
            collapseWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.viewModel.isExpanded = false
                self.repositionPanel(expanded: false)
            }
            collapseWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
        }
    }

    // MARK: - Notch detection

    private func resolveNotchMetrics() {
        let screen = NSScreen.main ?? NSScreen.screens.first

        if #available(macOS 12.0, *), let s = screen {
            let topInset = s.safeAreaInsets.top
            if topInset > 0 {
                notchHeight = topInset
                if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
                    let gap = right.minX - left.maxX
                    notchWidth = max(gap, 200)
                } else {
                    notchWidth = 200
                }
                return
            }
        }

        notchHeight = 0
        notchWidth = 0
    }

    private var currentLyric: String? {
        guard let index = lyricsService.currentLineIndex,
              lyricsService.lyricLines.indices.contains(index) else {
            return nil
        }
        let line = lyricsService.lyricLines[index]
        let text = settings.showRomanization ? line.romanized ?? line.text : line.text
        return text.isEmpty ? nil : text
    }

    // MARK: - Frame computation

    private func computeFrame(expanded: Bool) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen.screens[0]
        let screenFrame = screen.frame

        var baseWidth = expanded ? minExpandedWidth : minCompactWidth
        if !expanded, let lyric = currentLyric {
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            let textWidth = ceil((lyric as NSString).size(withAttributes: [.font: font]).width)
            baseWidth = max(baseWidth, textWidth + 68)
        }

        // Keep enough overhang around a physical notch, then cap the island
        // to the current display so exceptionally long lyrics still fit.
        let desiredWidth = notchHeight > 0
            ? max(baseWidth, notchWidth + notchOverhang * 2)
            : baseWidth
        let width = min(desiredWidth, screenFrame.width - 32)

        let bodyHeight = expanded ? expandedBodyHeight : compactBodyHeight
        let totalHeight = notchHeight + bodyHeight

        let x = screenFrame.midX - width / 2
        let y: CGFloat
        if notchHeight > 0 {
            // Top of pill flush with top of screen so the reserved notch
            // region inside the pill aligns with the physical notch.
            y = screenFrame.maxY - totalHeight
        } else {
            let menuBarBottom = screen.visibleFrame.maxY
            y = menuBarBottom - bodyHeight - 6
        }

        return NSRect(x: x, y: y, width: width, height: totalHeight)
    }

    private func repositionPanel(expanded: Bool) {
        guard let panel = panel else { return }
        let frame = computeFrame(expanded: expanded)
        // No frame animation — SwiftUI handles the content cross-fade. Cocoa
        // frame animation racing with SwiftUI's onHover was the source of the
        // grow/shrink flicker loop.
        panel.setFrame(frame, display: true, animate: false)
    }
}
