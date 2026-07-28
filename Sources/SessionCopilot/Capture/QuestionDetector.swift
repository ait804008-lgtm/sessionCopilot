import Foundation

/// Detects question boundaries using a silence + speech-resumption heuristic.
/// Emits `onSilenceDetected` when silence exceeds threshold (question ended).
public final class QuestionDetector {
    private let silenceThreshold: TimeInterval
    private let speechLevelThreshold: Float = 0.05
    private var _isSpeaking = false
    private var silenceAccumulator: TimeInterval = 0
    private var didFireForCurrentSilence = false
    private var _isDisabled = false
    private let lock = NSLock()

    public var isSpeaking: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isSpeaking
    }

    public var currentSilenceDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return silenceAccumulator
    }

    /// Called when silence exceeds the threshold (question just ended).
    public var onSilenceDetected: (() -> Void)?

    public init(silenceThreshold: TimeInterval = 1.5) {
        self.silenceThreshold = silenceThreshold
    }

    /// Feed a level meter sample.
    /// Returns true when silence exceeds threshold and a question boundary is detected.
    /// When disabled, always returns false and accumulates nothing.
    @discardableResult
    public func feed(level: Float, deltaTime: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !_isDisabled else { return false }

        let isSpeechNow = level > speechLevelThreshold

        if isSpeechNow {
            silenceAccumulator = 0
            didFireForCurrentSilence = false
            _isSpeaking = true
        } else {
            silenceAccumulator += deltaTime
            if silenceAccumulator >= silenceThreshold {
                _isSpeaking = false
                if !didFireForCurrentSilence {
                    didFireForCurrentSilence = true
                    return true // Silence threshold reached — question ended
                }
            }
        }
        return false
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isSpeaking = false
        silenceAccumulator = 0
        didFireForCurrentSilence = false
    }

    /// Disable the detector — feed() becomes a no-op, accumulates nothing.
    public func disable() {
        lock.lock()
        defer { lock.unlock() }
        _isDisabled = true
        _isSpeaking = false
        silenceAccumulator = 0
        didFireForCurrentSilence = false
    }

    /// Re-enable the detector after disable(). Starts fresh.
    public func enable() {
        lock.lock()
        defer { lock.unlock() }
        _isDisabled = false
        _isSpeaking = false
        silenceAccumulator = 0
        didFireForCurrentSilence = false
    }
}
