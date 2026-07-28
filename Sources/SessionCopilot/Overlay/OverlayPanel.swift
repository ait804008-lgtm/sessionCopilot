import AppKit
import SwiftUI
import Combine

/// Floating NSPanel overlay that stays on top of other windows.
public final class OverlayPanel: NSPanel {
    private let viewModel: OverlayViewModel
    private var cancellables = Set<AnyCancellable>()
    var onPanelClose: (() -> Void)?

    init(viewModel: OverlayViewModel) {
        self.viewModel = viewModel

        super.init(
            contentRect: NSRect(x: 200, y: 200, width: 400, height: 500),
            styleMask: [.nonactivatingPanel, .resizable, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        configureWindow()
    }

    private func configureWindow() {
        title = "SessionCopilot"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        let overlayView = OverlayView(viewModel: viewModel) { [weak self] in
            self?.close()
        }
        contentView = NSHostingView(rootView: overlayView)
        isOpaque = false
        backgroundColor = .clear

        // Sync panel properties whenever the view model changes
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.alphaValue = self.viewModel.opacity
                self.ignoresMouseEvents = self.viewModel.clickThrough
            }
            .store(in: &cancellables)
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public override func close() {
        onPanelClose?()
        super.close()
    }
}
