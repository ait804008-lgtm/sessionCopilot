import Foundation

/// Detects question boundaries using a silence + speech-resumption heuristic.
/// Emits `onSilenceDetected` when silence exceeds threshold (question ended).
///
/// Uses hysteresis on the speech/silence boundary to prevent noise-driven
/// toggling. Speech onset requires a higher level (`speechOnThreshold`)
/// than silence detection (`speechOffThreshold`), creating a dead zone
/// that filters out ambient noise hovering near a single threshold.
public final class QuestionDetector {
    private let silenceThreshold: TimeInterval

    /// Level above which audio is considered speech (onset).
    /// Higher than `speechOffThreshold` to create hysteresis dead zone.
    private let speechOnThreshold: Float = 0.08

    /// Level at or below which audio is considered silence (offset).
    /// Lower than `speechOnThreshold` — once speaking, must drop below
    /// this to begin the silence countdown.
    private let speechOffThreshold: Float = 0.03

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

        // Hysteresis: speech onset requires crossing the higher threshold;
        // silence offset requires dropping below the lower threshold.
        // This dead zone prevents ambient noise from rapidly cycling the
        // detector state machine.
        let isSpeechNow: Bool
        if _isSpeaking {
            // Already speaking — only transition to silence when level
            // drops below the lower (offset) threshold.
            isSpeechNow = level > speechOffThreshold
        } else {
            // Currently silent — only transition to speech when level
            // exceeds the higher (onset) threshold.
            isSpeechNow = level > speechOnThreshold
        }

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
