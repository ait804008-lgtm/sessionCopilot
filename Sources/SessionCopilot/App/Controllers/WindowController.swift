import AppKit
import SwiftUI
import Combine
import os

/// Owns the auxiliary windows: preflight, settings, history,
/// responsible-use, and the overlay panel.
///
/// Extracted from `AppDelegate` as part of the controller split. Each
/// window is created lazily on first request and nil-ed out on close
/// via `observeWindowClose`.
///
/// The overlay panel lifecycle is tied to `viewModel.isVisible` —
/// `syncOverlayVisibility()` creates/shows/hides the panel based on
/// the view model state.
@MainActor
public final class WindowController {
    private let services: Services

    private nonisolated(unsafe) var preflightWindow: NSWindow?
    private nonisolated(unsafe) var settingsWindow: NSWindow?
    private nonisolated(unsafe) var responsibleUseWindow: NSWindow?
    private nonisolated(unsafe) var historyWindow: NSWindow?
    public private(set) var overlayPanel: OverlayPanel?

    /// Called when the overlay panel is closed by the user (via its
    /// close button). The delegate (typically `AppDelegate`) should
    /// stop the capture session in response.
    public var onOverlayClose: (() -> Void)?

    public init(services: Services) {
        self.services = services
    }

    // MARK: - Overlay

    /// Sync the overlay panel state with `viewModel.isVisible`.
    /// Pulls opacity / click-through from persisted settings.
    public func syncOverlayVisibility() {
        let viewModel = services.viewModel
        let settingsStore = services.settingsStore
        if viewModel.isVisible {
            preflightWindow?.close()
            preflightWindow = nil

            viewModel.opacity = settingsStore.settings.opacity
            viewModel.clickThrough = settingsStore.settings.clickThrough

            if overlayPanel == nil {
                let panel = OverlayPanel(viewModel: viewModel)
                panel.onPanelClose = { [weak self] in
                    self?.onOverlayClose?()
                }
                overlayPanel = panel
            }
            overlayPanel?.alphaValue = viewModel.opacity
            overlayPanel?.ignoresMouseEvents = viewModel.clickThrough
            overlayPanel?.makeKeyAndOrderFront(nil)
        } else {
            overlayPanel?.close()
            overlayPanel = nil
        }
    }

    // MARK: - Preflight

    public func showPreflight(goLive: @escaping () -> Void) {
        let vm = services.preflightVM
        var timer: Timer?

        let preflightView = PreflightView(viewModel: vm) {
            timer?.invalidate()
            goLive()
        }
        let hostingView = NSHostingView(rootView: preflightView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SessionCopilot — Preflight"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        observeWindowClose(window) { [weak self] in
            self?.preflightWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        preflightWindow = window

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak vm] _ in
            Task { @MainActor [weak vm] in
                vm?.refresh()
            }
        }
    }

    // MARK: - Responsible Use

    public func showResponsibleUse() {
        let view = ResponsibleUseView { [weak self] in
            self?.responsibleUseWindow?.close()
            self?.responsibleUseWindow = nil
        }
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to SessionCopilot"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        observeWindowClose(window) { [weak self] in
            self?.responsibleUseWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        responsibleUseWindow = window
    }

    // MARK: - Settings

    public func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(
                settingsStore: services.settingsStore,
                providerStore: services.providerStore,
                profileStore: services.profileStore
            )
            let hostingView = NSHostingView(rootView: settingsView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SessionCopilot Settings"
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            observeWindowClose(window) { [weak self] in
                self?.settingsWindow = nil
            }
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Session History

    public func openHistory() {
        if historyWindow == nil {
            let historyView = SessionHistoryView(store: services.sessionStore)
            let hostingView = NSHostingView(rootView: historyView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Session History"
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            observeWindowClose(window) { [weak self] in
                self?.historyWindow = nil
            }
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    /// Register for NSWindowWillCloseNotification to nil out the reference.
    /// Prevents zombie window crashes when calling makeKeyAndOrderFront after close.
    private func observeWindowClose(_ window: NSWindow, handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            handler()
        }
    }
}
