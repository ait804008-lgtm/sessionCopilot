import AppKit
import os

/// Owns the menu bar status item and its menu.
///
/// Renders a colored dot indicating capture status:
/// - Gray (`idle`): no session active
/// - Blue (`micOnly`): mic-only capture (system audio disabled or still initializing)
/// - Green (`systemActive`): mic + system audio both delivering
/// - Amber (`systemFallback`): SCStream silent, mic feeding systemDetector
/// - Red (`failed`): capture error
///
/// The dot updates in response to `CaptureEngineImpl.onStatusChange`
/// callbacks. The menu provides access to overlay, settings, history,
/// and quit.
///
/// Extracted from `AppDelegate` as part of the controller split —
/// `AppDelegate` retains a `MenuBarController` and calls
/// `updateStatus(_:)` whenever capture state changes.
@MainActor
public final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    /// Weak references so the controller doesn't retain the app delegate
    /// graph (avoids a cycle: AppDelegate → MenuBarController → closures → AppDelegate).
    public weak var delegate: MenuBarControllerDelegate?

    /// Current displayed status. Setting this updates the menu bar icon
    /// and tooltip. The setter is `public` so tests can drive it directly.
    public private(set) var currentStatus: CaptureStatus = .idle {
        didSet { renderStatus() }
    }

    public override init() {
        super.init()
        setupStatusItem()
        setupMenu()
        renderStatus()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "SessionCopilot status"
            )
            button.image?.isTemplate = false  // we want the colored dot, not template tinting
            button.toolTip = "SessionCopilot — Idle"
        }
        statusItem.menu = nil  // menu shows on click; we set it lazily in renderStatus
    }

    private func setupMenu() {
        menu = NSMenu()

        let overlayItem = NSMenuItem(title: "Show Overlay", action: #selector(showOverlay), keyEquivalent: "o")
        overlayItem.target = self
        menu.addItem(overlayItem)

        let stopItem = NSMenuItem(title: "Stop Session", action: #selector(stopSession), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(title: "Session History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let captureItem = NSMenuItem(title: "Capture Coding Problem", action: #selector(captureCodingProblem), keyEquivalent: "a")
        captureItem.target = self
        menu.addItem(captureItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Rendering

    /// Update the menu bar icon + tooltip to reflect `currentStatus`.
    /// Called automatically by the `currentStatus` didSet.
    private func renderStatus() {
        guard let button = statusItem?.button else { return }

        // Build a small colored circle as the icon. We use a template
        // image with `NSImage(size:flipped:drawingHandler:)` to get a
        // crisp 10×10 dot regardless of screen resolution.
        let color = statusColor(for: currentStatus)
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false  // preserve the color, don't apply menu-bar tinting

        button.image = image
        button.toolTip = "SessionCopilot — \(currentStatus.label)"
        statusItem.menu = menu
    }

    private func statusColor(for status: CaptureStatus) -> NSColor {
        switch status {
        case .idle:           return .secondaryLabelColor
        case .micOnly:        return .systemBlue
        case .systemActive:   return .systemGreen
        case .systemFallback: return .systemOrange
        case .failed:         return .systemRed
        }
    }

    // MARK: - Public API

    /// Update the displayed status. Called by `AppDelegate` in response
    /// to `CaptureEngineImpl.onStatusChange`.
    public func updateStatus(_ status: CaptureStatus) {
        Log.ui.debug("MenuBarController status → \(status.label, privacy: .public)")
        currentStatus = status
    }

    // MARK: - Menu actions (forwarded to delegate)

    @objc private func showOverlay() {
        delegate?.menuBarDidRequestShowOverlay()
    }

    @objc private func stopSession() {
        delegate?.menuBarDidRequestStopSession()
    }

    @objc private func openSettings() {
        delegate?.menuBarDidRequestOpenSettings()
    }

    @objc private func openHistory() {
        delegate?.menuBarDidRequestOpenHistory()
    }

    @objc private func captureCodingProblem() {
        delegate?.menuBarDidRequestCaptureCodingProblem()
    }
}

/// Delegate for `MenuBarController` menu actions.
/// Each method corresponds to one menu item. The delegate (typically
/// `AppDelegate`) is responsible for routing the request to the right
/// controller.
@MainActor
public protocol MenuBarControllerDelegate: AnyObject {
    func menuBarDidRequestShowOverlay()
    func menuBarDidRequestStopSession()
    func menuBarDidRequestOpenSettings()
    func menuBarDidRequestOpenHistory()
    func menuBarDidRequestCaptureCodingProblem()
}
