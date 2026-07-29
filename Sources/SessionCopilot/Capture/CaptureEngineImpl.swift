import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox
import ScreenCaptureKit
import CoreMedia

/// Status of the capture engine.
public enum CaptureState: Sendable {
    case idle
    case running
    case failed(Error)
}

/// Default implementation of CaptureEngine.
///
/// - Microphone: AVAudioEngine input tap.
/// - System audio: SCStream with `capturesAudio = true` (Apple's only
///   supported API for capturing system audio output on macOS 14+).
///   AUHAL (`kAudioUnitSubType_HALOutput`) and
///   `AudioDeviceCreateIOProcID` cannot capture speaker output —
///   built-in speakers are an output-only device with no input stream
///   for the HAL to pull from. Those paths were removed.
///
/// **Bundle requirement**: SCStream requires the binary to run as a
/// `.app` bundle with a stable code-signing identity, a valid Info.plist
/// containing `NSScreenCaptureUsageDescription`, and a Screen Recording
/// TCC grant. `swift run` will silently fail — SCStream returns `noErr`
/// from `startCapture()` but never delivers buffers when the TCC grant
/// is missing or the executable identity is unstable.
///
/// **Hybrid fallback**: If SCStream does not deliver audio within
/// `systemAudioFallbackSeconds` (default 2.0s) of starting, the engine
/// falls back to feeding `systemDetector` from the mic tap. This allows
/// the app to function (with degraded speaker attribution) on machines
/// where SCStream permission is unavailable.
public final class CaptureEngineImpl: @unchecked Sendable, CaptureEngine {
    // MARK: - Streams

    public let audioStream: AsyncStream<AudioBuffer>
    public let levelMeter: AsyncStream<Float>

    let audioContinuation: AsyncStream<AudioBuffer>.Continuation
    let meterContinuation: AsyncStream<Float>.Continuation

    // MARK: - Mic audio engine

    private let audioEngine = AVAudioEngine()
    let yieldQueue = DispatchQueue(label: "com.sessioncopilot.audio-yield")

    private let stateLock = NSLock()
    private var _state: CaptureState = .idle
    fileprivate var state: CaptureState {
        get { stateLock.withLock { _state } }
        set { stateLock.withLock { _state = newValue } }
    }

    // MARK: - System audio (SCStream)

    /// When true, captures system audio output via SCStream.
    public var captureSystemAudio: Bool = false

    /// Time to wait for SCStream to deliver audio before falling back to
    /// mic-based systemDetector feed. Exposed for testing.
    public var systemAudioFallbackSeconds: TimeInterval = 2.0

    /// Strongly-held SCStream. Must not be nil while running or ARC will
    /// deallocate it and silently stop sample delivery.
    private var scStream: SCStream?

    /// Delegate boxes held strongly — `SCStream.delegate` is weak, and
    /// `addStreamOutput` does not retain its target either.
    private var scStreamDelegateBox: SCStreamDelegateBox?
    private var scAudioOutputBox: SCAudioOutputBox?

    /// Serial queue for SCStream sample delivery. Using `.global()` is
    /// forbidden — it's concurrent and can deliver samples out of order
    /// or drop them under load. Main queue is acceptable but blocks UI
    /// for downstream conversion. Dedicated serial queue is preferred.
    private let scAudioQueue = DispatchQueue(label: "com.sessioncopilot.sc-audio")

    /// Downstream converter state. All access must occur on `scAudioQueue`.
    /// `AVAudioConverter` is not thread-safe and not Sendable; we enforce
    /// single-threaded access via the serial queue.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    /// Output format for STT (Apple Speech Recognizer).
    internal let sttFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    /// Number of SCStream audio sample buffers received. For diagnostics
    /// and fallback triggering.
    private let scBufferCountLock = NSLock()
    private var _scBufferCount: Int = 0
    internal var scBufferCount: Int {
        scBufferCountLock.withLock { _scBufferCount }
    }
    private func incrementSCBufferCount() {
        scBufferCountLock.withLock { _scBufferCount += 1 }
    }

    /// Whether the system-audio fallback (mic feeding systemDetector)
    /// has been triggered. Latched true once activated.
    private let fallbackLock = NSLock()
    private var _didFallbackToMic = false
    public var didFallbackToMic: Bool {
        fallbackLock.withLock { _didFallbackToMic }
    }

    /// Background task that monitors SCStream for the first audio buffer
    /// and triggers mic fallback if none arrives in time.
    private var fallbackMonitorTask: Task<Void, Never>?

    // MARK: - VAD

    /// Detects question boundaries from system (interviewer) audio.
    let systemDetector: QuestionDetector
    /// Tracks candidate (mic) speech for speaker attribution only — does NOT fire.
    private let micDetector: QuestionDetector
    private var lastMicTime = Date()
    private var lastSystemTime = Date()
    public var onQuestionDetected: (() -> Void)?

    public var isSystemSpeaking: Bool { systemDetector.isSpeaking }
    public var isMicSpeaking: Bool { micDetector.isSpeaking }

    public func enableVAD() {
        let now = Date()
        lastMicTime = now
        lastSystemTime = now
        systemDetector.enable()
        micDetector.enable()
    }

    public func disableVAD() {
        systemDetector.disable()
        micDetector.disable()
    }

    public func resetSilence() {
        let now = Date()
        lastMicTime = now
        lastSystemTime = now
        systemDetector.reset()
        micDetector.reset()
    }

    // MARK: - Init

    public init(captureSystemAudio: Bool = false, silenceThreshold: TimeInterval = 1.5) {
        self.captureSystemAudio = captureSystemAudio
        self.systemDetector = QuestionDetector(silenceThreshold: silenceThreshold)
        self.micDetector = QuestionDetector(silenceThreshold: silenceThreshold)

        var audioCont: AsyncStream<AudioBuffer>.Continuation!
        self.audioStream = AsyncStream { audioCont = $0 }
        self.audioContinuation = audioCont!

        var meterCont: AsyncStream<Float>.Continuation!
        self.levelMeter = AsyncStream { meterCont = $0 }
        self.meterContinuation = meterCont!
    }

    // MARK: - Public API

    public func start() async throws {
        if case .running = state { return }
        systemDetector.reset()
        micDetector.reset()
        lastMicTime = Date()
        lastSystemTime = Date()

        // ---- Mic tap (AVAudioEngine) ----
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else {
            state = .failed(CaptureError.invalidFormat)
            throw CaptureError.invalidFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = self.convert(buffer: buffer, from: inputFormat, to: recordingFormat) else {
                return
            }
            let frameLength = Int(converted.frameLength)
            guard let channelData = converted.int16ChannelData?.pointee else { return }
            let data = Data(bytes: channelData, count: frameLength * MemoryLayout<Int16>.size)

            let timestamp = Date()
            let sampleRate = Int(recordingFormat.sampleRate)
            let channels = Int(recordingFormat.channelCount)
            let capturedRMS = Self.computeRMS(from: data)

            let capturedData = data
            let capturedTimestamp = timestamp
            let capturedSampleRate = sampleRate
            let capturedChannels = channels
            self.yieldQueue.async { [weak self] in
                guard let self else { return }
                let audioBuffer = AudioBuffer(
                    data: capturedData,
                    timestamp: capturedTimestamp,
                    sampleRate: capturedSampleRate,
                    channels: capturedChannels,
                    source: .mic
                )
                self.audioContinuation.yield(audioBuffer)
                self.meterContinuation.yield(capturedRMS)
            }

            let now = Date()
            let micDelta = now.timeIntervalSince(self.lastMicTime)
            self.lastMicTime = now
            self.micDetector.feed(level: capturedRMS, deltaTime: micDelta)

            // Hybrid fallback: if SCStream has not produced audio, feed
            // the systemDetector from the mic so question detection still
            // works (with degraded speaker attribution).
            if self.captureSystemAudio && self.didFallbackToMic {
                let micDetected = self.systemDetector.feed(level: capturedRMS, deltaTime: micDelta)
                if micDetected {
                    Task { @MainActor in
                        self.onQuestionDetected?()
                    }
                }
            }
        }

        do {
            try audioEngine.start()
            state = .running
        } catch {
            state = .failed(error)
            throw error
        }

        // ---- System audio (SCStream) ----
        if captureSystemAudio {
            await startSystemAudioCapture()
            // Watchdog: if SCStream delivers nothing within the timeout,
            // latch the fallback flag so the mic tap starts feeding
            // systemDetector on subsequent callbacks.
            startFallbackMonitor()
        }
    }

    public func stop() async throws {
        fallbackMonitorTask?.cancel()
        fallbackMonitorTask = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Stop SCStream BEFORE nil-ing references — `stopCapture()` awaits
        // pending callbacks, so no audio handler will race the teardown.
        await stopSystemAudioCapture()

        systemDetector.reset()
        micDetector.reset()
        state = .idle
        yieldQueue.async { [weak self] in
            self?.audioContinuation.finish()
            self?.meterContinuation.finish()
        }
    }

    // MARK: - System Audio Capture (SCStream)

    private func startSystemAudioCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                fputs("[DEBUG-sc] No displays found\n", stderr)
                state = .failed(CaptureError.noDisplay)
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            // Use device-native format. Conversion to 16 kHz Int16 mono
            // happens downstream via AVAudioConverter. Configuring SCStream
            // to output 16 kHz directly is unsupported.
            config.sampleRate = 48_000
            config.channelCount = 2
            // Do NOT set width/height — audio-only capture. Setting small
            // values (e.g. 1×1, 128×128) triggers CGError 1003 when Screen
            // Recording permission is missing; leaving them at 0 is correct.
            // `queueDepth` controls the minimum number of frames before
            // delivery. Setting it to 1 gives us the earliest possible
            // audio callback, which is important for the fallback watchdog
            // (2s timeout). Available since macOS 13.0.
            config.queueDepth = 1

            // Delegate boxes must be created and retained BEFORE the stream
            // is started. SCStream.delegate is weak; addStreamOutput does
            // not retain its target. Without strong retention, ARC will
            // deallocate the boxes mid-stream and silently stop delivery.
            let delegateBox = SCStreamDelegateBox(owner: self)
            let audioBox = SCAudioOutputBox(owner: self)

            let stream = SCStream(filter: filter, configuration: config, delegate: delegateBox)
            try await stream.addStreamOutput(
                audioBox,
                type: .audio,
                sampleHandlerQueue: scAudioQueue
            )

            try await stream.startCapture()

            self.scStream = stream
            self.scStreamDelegateBox = delegateBox
            self.scAudioOutputBox = audioBox
            fputs("[DEBUG-sc] SCStream started (display: \(display.width)×\(display.height))\n", stderr)
        } catch {
            fputs("[DEBUG-sc] Failed to start SCStream: \(error)\n", stderr)
            state = .failed(CaptureError.wrap(error))
            // Fall back to mic-only immediately — startFallbackMonitor
            // will latch the flag since scBufferCount is still 0.
        }
    }

    private func stopSystemAudioCapture() async {
        guard let stream = scStream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            fputs("[DEBUG-sc] stopCapture error: \(error)\n", stderr)
        }
        scStream = nil
        scStreamDelegateBox = nil
        scAudioOutputBox = nil
        // Reset converter state on the audio queue to guarantee no
        // concurrent access during teardown.
        scAudioQueue.sync {
            self.converter = nil
            self.converterInputFormat = nil
        }
    }

    /// If SCStream has not delivered any audio within
    /// `systemAudioFallbackSeconds`, latch the mic-fallback flag.
    /// Subsequent mic-tap callbacks will start feeding systemDetector.
    private func startFallbackMonitor() {
        fallbackMonitorTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.systemAudioFallbackSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self.scBufferCount == 0 {
                self.fallbackLock.withLock { self._didFallbackToMic = true }
                fputs("[DEBUG-sc] SCStream silent for \(self.systemAudioFallbackSeconds)s — falling back to mic for systemDetector\n", stderr)
            }
        }
    }

    // MARK: - SCStream sample handling (runs on scAudioQueue)

    /// Called by `SCAudioOutputBox.stream(_:didOutputSampleBuffer:of:)`.
    /// All work here runs on `scAudioQueue`, so `converter` and
    /// `converterInputFormat` access is single-threaded.
    fileprivate func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        incrementSCBufferCount()

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            fputs("[DEBUG-sc] No format description\n", stderr)
            return
        }

        // CMAudioFormatDescriptionGetStreamBasicDescription returns a
        // nullable UnsafePointer<AudioStreamBasicDescription> to the
        // description inside the format description.
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            fputs("[DEBUG-sc] No stream basic description\n", stderr)
            return
        }
        let asbd = asbdPtr.pointee

        let inSampleRate = asbd.mSampleRate
        let inChannels = asbd.mChannelsPerFrame
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat, inSampleRate > 0, inChannels > 0 else {
            fputs("[DEBUG-sc] Unexpected format: rate=\(inSampleRate) ch=\(inChannels) isFloat=\(isFloat)\n", stderr)
            return
        }

        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // Lazily build / rebuild converter if format changed.
        // SCStream format is stable for a given configuration, so this
        // runs once at startup.
        if converterInputFormat == nil
            || converterInputFormat?.sampleRate != inSampleRate
            || converterInputFormat?.channelCount != inChannels
            || converterInputFormat?.isInterleaved != isInterleaved {

            guard let inFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: inSampleRate,
                channels: inChannels,
                interleaved: isInterleaved
            ) else {
                fputs("[DEBUG-sc] Failed to build input AVAudioFormat\n", stderr)
                return
            }
            guard let conv = AVAudioConverter(from: inFmt, to: sttFormat) else {
                fputs("[DEBUG-sc] Failed to build AVAudioConverter\n", stderr)
                return
            }
            converterInputFormat = inFmt
            converter = conv
            fputs("[DEBUG-sc] Converter built: \(inSampleRate)Hz \(inChannels)ch → 16kHz mono Int16\n", stderr)
        }
        guard let inFmt = converterInputFormat, let conv = converter else { return }

        let numFrames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numFrames > 0 else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            fputs("[DEBUG-sc] No data buffer\n", stderr)
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        let expectedBytes = Int(numFrames) * Int(inChannels) * MemoryLayout<Float32>.size
        guard length >= expectedBytes else {
            fputs("[DEBUG-sc] Data length mismatch: have=\(length) expected=\(expectedBytes)\n", stderr)
            return
        }

        // Copy PCM out of the CMBlockBuffer into a Data we own.
        var dataBuffer = Data(count: expectedBytes)
        let copyStatus = dataBuffer.withUnsafeMutableBytes { dst -> OSStatus in
            guard let dstBase = dst.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: expectedBytes,
                destination: dstBase
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            fputs("[DEBUG-sc] CMBlockBufferCopyDataBytes failed: \(copyStatus)\n", stderr)
            return
        }

        // Wrap as AVAudioPCMBuffer. numFrames is Int (CMItemCount);
        // AVAudioFrameCount is UInt32. Safe cast — SCStream buffers are
        // tiny (a few thousand frames max).
        let frameCapacity = AVAudioFrameCount(numFrames)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: frameCapacity) else { return }
        pcmBuffer.frameLength = frameCapacity

        dataBuffer.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            let srcPtr = srcBase.assumingMemoryBound(to: Float.self)
            if isInterleaved {
                // For interleaved, floatChannelData[0] points to a contiguous
                // buffer of frameLength * channels floats.
                guard let dst = pcmBuffer.floatChannelData?[0] else { return }
                dst.update(from: srcPtr, count: Int(numFrames) * Int(inChannels))
            } else {
                // Non-interleaved: de-interleave into per-channel buffers.
                for ch in 0..<Int(inChannels) {
                    guard let dst = pcmBuffer.floatChannelData?[ch] else { continue }
                    for i in 0..<Int(numFrames) {
                        dst[i] = srcPtr[i * Int(inChannels) + ch]
                    }
                }
            }
        }

        // Convert to 16 kHz Int16 mono using the shared pipeline.
        guard let outBuffer = Self.convertPCM(pcmBuffer, with: conv, to: sttFormat) else { return }
        let outFrameLength = Int(outBuffer.frameLength)
        guard outFrameLength > 0,
              let channelData = outBuffer.int16ChannelData?.pointee else { return }
        let pcmData = Data(bytes: channelData, count: outFrameLength * MemoryLayout<Int16>.size)
        let level = Self.computeRMS(from: pcmData)
        let timestamp = Date()

        let audioBuffer = AudioBuffer(
            data: pcmData,
            timestamp: timestamp,
            sampleRate: 16_000,
            channels: 1,
            source: .system
        )
        audioContinuation.yield(audioBuffer)
        meterContinuation.yield(level)

        let now = Date()
        let delta = now.timeIntervalSince(lastSystemTime)
        lastSystemTime = now
        let detected = systemDetector.feed(level: level, deltaTime: delta)
        if detected {
            Task { @MainActor in
                self.onQuestionDetected?()
            }
        }
    }

    // MARK: - Helpers (testable)

    /// Compute RMS of normalized float samples from Int16 PCM data.
    public static func computeRMS(from data: Data) -> Float {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return 0 }
        return data.withUnsafeBytes { ptr -> Float in
            guard let base = ptr.baseAddress else { return 0 }
            let samples = base.assumingMemoryBound(to: Int16.self)
            var sum: Float = 0
            for i in 0..<frameCount {
                let f = Float(samples[i]) / Float(Int16.max)
                sum += f * f
            }
            return sqrt(sum / Float(frameCount))
        }
    }

    /// One-shot PCM conversion using AVAudioConverter. Returns nil on
    /// error or when the converter produces no output.
    ///
    /// Uses the NSError-based `convert(to:error:withInputFrom:)` overload
    /// rather than the throwing `convert(to:from:)` variant. The throwing
    /// variant can raise an Objective-C `NSException` from `_AVAE_Check`
    /// when the internal format state is inconsistent — Swift's `do/catch`
    /// cannot intercept ObjC exceptions, so the process crashes. The
    /// NSError-based overload handles errors gracefully via an out
    /// parameter and never raises.
    ///
    /// Internal for testability.
    internal static func convertPCM(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 32)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrameCapacity) else {
            return nil
        }
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return input
        }
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if status == .error || error != nil {
            return nil
        }
        // If frameLength is 0, the converter buffered the input but
        // produced no output yet. Return nil so callers can skip
        // downstream processing for this cycle. Buffered samples will
        // come out on subsequent calls.
        if outBuffer.frameLength == 0 {
            return nil
        }
        return outBuffer
    }

    /// Build a Float32 AVAudioPCMBuffer from raw Float samples.
    ///
    /// The `samples` array is always treated as **interleaved**:
    /// `[frame0_ch0, frame0_ch1, frame1_ch0, frame1_ch1, ...]`.
    /// The `interleaved` parameter controls the *output* buffer's layout.
    /// When `interleaved == false`, samples are de-interleaved into
    /// per-channel buffers during construction.
    ///
    /// Used by tests to fabricate input for the conversion pipeline.
    internal static func makeFloatBuffer(
        samples: [Float],
        sampleRate: Double,
        channels: UInt32,
        interleaved: Bool
    ) -> AVAudioPCMBuffer? {
        guard channels > 0 else { return nil }
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: interleaved
        ) else { return nil }
        let frameCount = AVAudioFrameCount(samples.count / Int(channels))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount

        if interleaved {
            // Output is interleaved; copy samples directly into
            // floatChannelData[0] which has stride == channels.
            // Only copy frameCount * channels values — if samples has
            // a partial trailing frame (samples.count % channels != 0),
            // the trailing samples are dropped.
            guard let dst = buf.floatChannelData?[0] else { return nil }
            let copyCount = Int(frameCount) * Int(channels)
            for i in 0..<copyCount {
                dst[i] = samples[i]
            }
        } else {
            // Output is non-interleaved; de-interleave the input array
            // into per-channel buffers (each with stride == 1).
            for ch in 0..<Int(channels) {
                guard let dst = buf.floatChannelData?[ch] else { continue }
                for f in 0..<Int(frameCount) {
                    dst[f] = samples[f * Int(channels) + ch]
                }
            }
        }
        return buf
    }

    private func convert(buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else {
            return nil
        }
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if error != nil { return nil }
        return output
    }
}

// MARK: - SCStream Delegate Boxes
//
// SCStream's lifecycle delegate (`SCStreamDelegate`) and sample output
// (`SCStreamOutput`) are NSObject protocols. Swift 6 strict concurrency
// requires us to mark these `@unchecked Sendable` and route access to
// the owner through a weak reference. The boxes themselves are strongly
// retained by `CaptureEngineImpl` to prevent ARC from deallocating them
// mid-stream — `SCStream.delegate` is weak and `addStreamOutput` does
// not retain its target.

private final class SCStreamDelegateBox: NSObject, SCStreamDelegate, @unchecked Sendable {
    weak var owner: CaptureEngineImpl?
    init(owner: CaptureEngineImpl) { self.owner = owner }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[DEBUG-sc] SCStream stopped with error: \(error)\n", stderr)
        guard let owner else { return }
        owner.state = .failed(CaptureError.wrap(error))
    }
}

private final class SCAudioOutputBox: NSObject, SCStreamOutput, @unchecked Sendable {
    weak var owner: CaptureEngineImpl?
    init(owner: CaptureEngineImpl) { self.owner = owner }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        owner?.handleAudioSampleBuffer(sampleBuffer)
    }
}

// MARK: - Errors

enum CaptureError: Error, Equatable {
    case invalidFormat
    case noDisplay
    case scStreamFailed(String)

    static func == (lhs: CaptureError, rhs: CaptureError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidFormat, .invalidFormat): return true
        case (.noDisplay, .noDisplay): return true
        case (.scStreamFailed(let a), .scStreamFailed(let b)): return a == b
        default: return false
        }
    }
}

extension CaptureError {
    /// Convenience initializer that wraps any Error into a scStreamFailed
    /// case with its localized description. Used by call sites that need
    /// to store the error in a CaptureState.
    ///
    /// Named `wrap(_:)` to avoid a name collision with the
    /// `scStreamFailed(String)` enum case constructor.
    static func wrap(_ error: Error) -> CaptureError {
        if let already = error as? CaptureError { return already }
        return .scStreamFailed(error.localizedDescription)
    }
}

// MARK: - Mock Capture Engine (for testing/previews)

@MainActor
public final class MockCaptureEngine: @preconcurrency CaptureEngine {
    public let audioStream: AsyncStream<AudioBuffer>
    public let levelMeter: AsyncStream<Float>
    public nonisolated(unsafe) var isSystemSpeaking: Bool = false
    public nonisolated(unsafe) var isMicSpeaking: Bool = false

    private let audioContinuation: AsyncStream<AudioBuffer>.Continuation
    private let meterContinuation: AsyncStream<Float>.Continuation

    public init() {
        var a: AsyncStream<AudioBuffer>.Continuation!
        self.audioStream = AsyncStream { a = $0 }
        self.audioContinuation = a!

        var m: AsyncStream<Float>.Continuation!
        self.levelMeter = AsyncStream { m = $0 }
        self.meterContinuation = m!
    }

    public func start() async throws {
        let dummy = AudioBuffer(data: Data([0, 0]), timestamp: Date(), sampleRate: 16000, channels: 1)
        audioContinuation.yield(dummy)
        meterContinuation.yield(0.1)
    }

    public func stop() async throws {
        audioContinuation.finish()
        meterContinuation.finish()
    }

    public nonisolated func enableVAD() {}
    public nonisolated func disableVAD() {}
    public nonisolated func resetSilence() {}
}
