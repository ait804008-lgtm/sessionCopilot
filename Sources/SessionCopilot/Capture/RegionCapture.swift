import Foundation
import AppKit
import ScreenCaptureKit

/// Captures a screen region as a CGImage and encodes it to base64 JPEG.
@MainActor
final class RegionCapture {
    private var activeOverlay: RegionSelectionOverlay?

    /// Show a crosshair selection overlay, capture the selected region, and return base64 JPEG.
    /// Returns nil if the user cancels.
    func captureRegion() async -> String? {
        // Use CGWindowListCreateImage for region capture (simplest, most reliable)
        // Wait for user to select a region via a fullscreen overlay
        guard let rect = await showSelectionOverlay() else { return nil }

        // Capture the screen region
        guard let cgImage = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.nominalResolution]
        ) else { return nil }

        // Convert to JPEG base64
        return encodeToBase64JPEG(cgImage)
    }

    // MARK: - Encoding

    func encodeToBase64JPEG(_ image: CGImage) -> String? {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }

    // MARK: - Selection Overlay

    /// Shows a fullscreen transparent overlay for region selection.
    /// Returns the selected rect in screen coordinates, or nil if cancelled.
    private func showSelectionOverlay() async -> CGRect? {
        await withCheckedContinuation { continuation in
            let overlay = RegionSelectionOverlay { [weak self] rect in
                self?.activeOverlay = nil
                continuation.resume(returning: rect)
            }
            // Keep a strong reference to the overlay until selection completes
            self.activeOverlay = overlay
            overlay.show()
        }
    }
}

// MARK: - Region Selection Overlay

/// A transparent fullscreen NSWindow that lets the user drag-select a screen region.
@MainActor
private final class RegionSelectionOverlay {
    private var window: NSPanel?
    private var startPoint: NSPoint = .zero
    private var currentRect: NSRect = .zero
    private let onComplete: (CGRect?) -> Void

    init(onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
    }

    func show() {
        guard let screen = NSScreen.main else {
            onComplete(nil)
            return
        }

        let frame = screen.frame
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.3)
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        // Custom view for drag selection
        let selectionView = RegionSelectionView()
        selectionView.onDragStart = { [weak self] point in
            self?.startPoint = point
        }
        selectionView.onDragUpdate = { [weak self] rect in
            self?.currentRect = rect
            self?.window?.contentView?.setNeedsDisplay(self?.window?.contentView?.bounds ?? .zero)
        }
        selectionView.onDragEnd = { [weak self] rect in
            self?.window?.orderOut(nil)
            self?.window = nil
            if rect.width > 10 && rect.height > 10 {
                self?.onComplete(rect)
            } else {
                self?.onComplete(nil)
            }
        }
        selectionView.onCancel = { [weak self] in
            self?.window?.orderOut(nil)
            self?.window = nil
            self?.onComplete(nil)
        }

        panel.contentView = selectionView
        panel.orderFrontRegardless()
        self.window = panel
    }
}

// MARK: - Selection View

@MainActor
private final class RegionSelectionView: NSView {
    var onDragStart: ((NSPoint) -> Void)?
    var onDragUpdate: ((NSRect) -> Void)?
    var onDragEnd: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint = .zero
    private var currentPoint: NSPoint = .zero
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDragging = true
        onDragStart?(startPoint)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        let rect = NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
        onDragUpdate?(rect)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        let rect = NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )

        // Convert to screen coordinates (flip Y)
        guard let screenFrame = NSScreen.main?.frame else { return }
        let screenRect = NSRect(
            x: rect.origin.x,
            y: screenFrame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        onDragEnd?(screenRect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            onCancel?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw selection rectangle
        if isDragging {
            let rect = NSRect(
                x: min(startPoint.x, currentPoint.x),
                y: min(startPoint.y, currentPoint.y),
                width: abs(currentPoint.x - startPoint.x),
                height: abs(currentPoint.y - startPoint.y)
            )

            // Dim everything outside the selection
            NSColor.black.withAlphaComponent(0.4).setFill()
            dirtyRect.fill()

            // Clear the selection area
            NSColor.clear.setFill()
            rect.fill()

            // Draw border
            NSColor.systemBlue.setStroke()
            let borderRect = NSBezierPath(rect: rect)
            borderRect.lineWidth = 2
            borderRect.stroke()
        }
    }
}
