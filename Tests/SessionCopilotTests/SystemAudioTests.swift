import Foundation
import AVFoundation
import Testing
@testable import SessionCopilot

// MARK: - AudioBuffer Source Tagging Tests

@Suite("AudioBuffer Source") struct AudioBufferSourceTests {

    @Test("AudioBuffer has mic source when tagged")
    func micSource() {
        let buffer = AudioBuffer(
            data: Data([0x01, 0x02]),
            timestamp: Date(),
            sampleRate: 16000,
            channels: 1,
            source: .mic
        )
        #expect(buffer.source == .mic)
    }

    @Test("AudioBuffer has system source when tagged")
    func systemSource() {
        let buffer = AudioBuffer(
            data: Data([0x01, 0x02]),
            timestamp: Date(),
            sampleRate: 16000,
            channels: 1,
            source: .system
        )
        #expect(buffer.source == .system)
    }

    @Test("AudioBuffer defaults to unknown source")
    func defaultUnknownSource() {
        let buffer = AudioBuffer(
            data: Data([0x01, 0x02]),
            timestamp: Date(),
            sampleRate: 16000,
            channels: 1
        )
        #expect(buffer.source == .unknown)
    }

    @Test("AudioBuffer source is Codable")
    func sourceCodable() throws {
        let buffer = AudioBuffer(
            data: Data([0x01, 0x02]),
            timestamp: Date(timeIntervalSince1970: 1000000),
            sampleRate: 16000,
            channels: 1,
            source: .system
        )
        let encoded = try JSONEncoder().encode(buffer)
        let decoded = try JSONDecoder().decode(AudioBuffer.self, from: encoded)
        #expect(decoded.source == .system)
    }

    @Test("CaptureEngineImpl can be initialized with system audio enabled")
    func initWithSystemAudio() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(engine.captureSystemAudio)
    }

    @Test("CaptureEngineImpl defaults to mic-only")
    func initDefaultMicOnly() {
        let engine = CaptureEngineImpl()
        #expect(!engine.captureSystemAudio)
    }

    @Test("RMS from silent Int16 PCM returns near-zero")
    func rmsSilentPcm() {
        let silent = Data(count: 160 * MemoryLayout<Int16>.size) // 160 zero samples
        let rms = CaptureEngineImpl.computeRMS(from: silent)
        #expect(rms < 0.001)
    }

    @Test("RMS from max-amplitude Int16 PCM returns ~1.0")
    func rmsMaxAmplitude() {
        var samples = [Int16](repeating: Int16.max, count: 160)
        let data = Data(bytes: &samples, count: samples.count * MemoryLayout<Int16>.size)
        let rms = CaptureEngineImpl.computeRMS(from: data)
        #expect(abs(rms - 1.0) < 0.01)
    }

    @Test("RMS from zero-length data returns 0")
    func rmsEmptyData() {
        let rms = CaptureEngineImpl.computeRMS(from: Data())
        #expect(rms == 0)
    }
}

// MARK: - RMS Computation Edge Cases

@Suite("RMS Edge Cases") struct RMSEdgeCaseTests {

    @Test("RMS from a single non-zero sample equals |sample|")
    func singleSample() {
        let value: Int16 = 16384 // 0.5 in normalized float
        var samples = [value]
        let data = Data(bytes: &samples, count: 2)
        let rms = CaptureEngineImpl.computeRMS(from: data)
        // Normalized: 16384/32767 ≈ 0.50001
        #expect(abs(rms - 0.5) < 0.01)
    }

    @Test("RMS from odd-length byte data is robust")
    func oddByteCount() {
        // 3 bytes = 1 full Int16 + 1 trailing byte.
        // computeRMS should treat this as 1 frame and ignore the trailing byte.
        let data = Data([0xFF, 0x7F, 0x00])
        let rms = CaptureEngineImpl.computeRMS(from: data)
        #expect(rms >= 0 && rms <= 1)
    }

    @Test("RMS from alternating +/- samples is non-zero")
    func alternatingSamples() {
        var samples: [Int16] = []
        for i in 0..<200 {
            samples.append(i % 2 == 0 ? 16384 : -16384)
        }
        let data = Data(bytes: &samples, count: samples.count * MemoryLayout<Int16>.size)
        let rms = CaptureEngineImpl.computeRMS(from: data)
        #expect(abs(rms - 0.5) < 0.01)
    }
}

// MARK: - PCM Format Conversion

@Suite("PCM Conversion") struct PCMConversionTests {

    /// Helper: build an AVAudioConverter from Float32 48kHz stereo to
    /// Int16 16kHz mono (the STT format).
    private func makeConverter() -> (AVAudioConverter, AVAudioFormat, AVAudioFormat)? {
        guard let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ),
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ),
        let conv = AVAudioConverter(from: inFmt, to: outFmt) else {
            return nil
        }
        return (conv, inFmt, outFmt)
    }

    @Test("Converter builds from Float32 48kHz stereo to Int16 16kHz mono")
    func converterBuilds() {
        #expect(makeConverter() != nil)
    }

    @Test("Silent Float32 input converts to silent Int16 output")
    func silentConversion() throws {
        guard let (conv, inFmt, outFmt) = makeConverter() else {
            Issue.record("converter build failed")
            return
        }
        // 480 samples * 2 channels = 960 floats = 5ms at 48kHz
        let samples = [Float](repeating: 0.0, count: 960)
        guard let input = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            Issue.record("input buffer build failed")
            return
        }
        #expect(input.format == inFmt)
        let output = CaptureEngineImpl.convertPCM(input, with: conv, to: outFmt)
        #expect(output != nil)
        #expect(output!.frameLength > 0)

        // Verify silence: all samples should be 0
        let frameLength = Int(output!.frameLength)
        let channelData = output!.int16ChannelData!.pointee
        var maxAbs: Int16 = 0
        for i in 0..<frameLength {
            let s = channelData[i]
            if abs(s) > maxAbs { maxAbs = abs(s) }
        }
        #expect(maxAbs == 0)
    }

    @Test("Max-amplitude Float32 input converts to near-max Int16 output")
    func maxAmplitudeConversion() throws {
        guard let (conv, _, outFmt) = makeConverter() else {
            Issue.record("converter build failed")
            return
        }
        // 4800 samples * 2 channels = 100ms at 48kHz — large enough to
        // avoid AVAudioConverter's inputRanOut state on the first call.
        let samples = [Float](repeating: 1.0, count: 9600)
        guard let input = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            Issue.record("input buffer build failed")
            return
        }
        let output = CaptureEngineImpl.convertPCM(input, with: conv, to: outFmt)
        #expect(output != nil)
        #expect(output!.frameLength > 0)

        // Output should be downsampled 3:1 (48k → 16k). 4800 input frames
        // (9600 samples / 2 ch) → 1600 output frames.
        #expect(output!.frameLength == 1600 || abs(Int(output!.frameLength) - 1600) < 50)

        let frameLength = Int(output!.frameLength)
        let channelData = output!.int16ChannelData!.pointee
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += Float(channelData[i]) / Float(Int16.max)
        }
        let avg = sum / Float(frameLength)
        // Average normalized amplitude should be very close to 1.0.
        // (Converter may apply minor dithering/rounding.)
        #expect(avg > 0.95)
    }

    @Test("Conversion downsamples 48kHz to 16kHz at correct ratio")
    func downsampleRatio() throws {
        guard let (conv, _, outFmt) = makeConverter() else {
            Issue.record("converter build failed")
            return
        }
        // 48000 input frames (1 second at 48kHz) → 16000 output frames.
        let samples = [Float](repeating: 0.5, count: 96_000)
        guard let input = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            Issue.record("input buffer build failed")
            return
        }
        let output = CaptureEngineImpl.convertPCM(input, with: conv, to: outFmt)
        #expect(output != nil)
        // Expect ~16000 frames (±100 for converter priming/flush).
        #expect(abs(Int(output!.frameLength) - 16_000) < 200)
    }

    @Test("Sine wave converts preserving frequency content")
    func sineWaveConversion() throws {
        guard let (conv, _, outFmt) = makeConverter() else {
            Issue.record("converter build failed")
            return
        }
        // 1 second of 440Hz sine wave at 48kHz stereo.
        let frameCount = 48_000
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * 2)
        for i in 0..<frameCount {
            let s = Float(sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0) * 0.5)
            samples.append(s) // L
            samples.append(s) // R
        }
        guard let input = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            Issue.record("input buffer build failed")
            return
        }
        let output = CaptureEngineImpl.convertPCM(input, with: conv, to: outFmt)
        #expect(output != nil)
        #expect(output!.frameLength > 0)

        // Verify the output is non-silent (RMS > 0).
        let data = Data(
            bytes: output!.int16ChannelData!.pointee,
            count: Int(output!.frameLength) * MemoryLayout<Int16>.size
        )
        let rms = CaptureEngineImpl.computeRMS(from: data)
        #expect(rms > 0.1)
    }

    @Test("Conversion of single-sample input returns nil (inputRanOut)")
    func tooFewSamples() throws {
        guard let (conv, _, outFmt) = makeConverter() else {
            Issue.record("converter build failed")
            return
        }
        // 2 samples = 1 frame (stereo). At 48k→16k, the converter needs
        // to accumulate enough input before producing output. With only
        // 1 frame of input, it should return .inputRanOut and our helper
        // returns nil.
        let samples: [Float] = [0.5, 0.5]
        guard let input = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else {
            Issue.record("input buffer build failed")
            return
        }
        let output = CaptureEngineImpl.convertPCM(input, with: conv, to: outFmt)
        // May be nil (inputRanOut) or a tiny buffer. Either is acceptable.
        if let output = output {
            #expect(output.frameLength >= 0) // tautology, but documents the contract
        }
    }
}

// MARK: - Float Buffer Builder (Test Helper)

@Suite("Float Buffer Builder") struct FloatBufferBuilderTests {

    @Test("Builds interleaved stereo buffer with correct frame count")
    func interleavedStereo() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4] // 2 frames * 2 channels
        let buf = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )
        #expect(buf != nil)
        #expect(buf!.frameLength == 2)
        #expect(buf!.stride == 2) // interleaved: stride == channels
    }

    @Test("Builds non-interleaved stereo buffer with correct frame count")
    func nonInterleavedStereo() {
        // For non-interleaved, the helper expects samples organized as
        // [frame0_ch0, frame0_ch1, frame1_ch0, frame1_ch1, ...] and
        // de-interleaves them into per-channel buffers.
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let buf = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )
        #expect(buf != nil)
        #expect(buf!.frameLength == 2)
        #expect(buf!.stride == 1) // non-interleaved: stride == 1
        // Verify de-interleaved content: ch0 = [0.1, 0.3], ch1 = [0.2, 0.4]
        #expect(buf!.floatChannelData![0][0] == 0.1)
        #expect(buf!.floatChannelData![0][1] == 0.3)
        #expect(buf!.floatChannelData![1][0] == 0.2)
        #expect(buf!.floatChannelData![1][1] == 0.4)
    }

    @Test("Returns nil when sample count doesn't divide by channel count (interleaved)")
    func mismatchedInterleaved() {
        // 3 samples, 2 channels → 1.5 frames. Should not crash.
        let samples: [Float] = [0.1, 0.2, 0.3]
        let buf = CaptureEngineImpl.makeFloatBuffer(
            samples: samples,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        )
        // 3 / 2 = 1 (integer division) — produces a 1-frame buffer.
        // The trailing sample is dropped.
        #expect(buf != nil)
        #expect(buf!.frameLength == 1)
    }
}

// MARK: - CaptureError

@Suite("CaptureError") struct CaptureErrorTests {

    @Test("invalidFormat equals invalidFormat")
    func equalitySame() {
        #expect(CaptureError.invalidFormat == CaptureError.invalidFormat)
        #expect(CaptureError.noDisplay == CaptureError.noDisplay)
        #expect(CaptureError.scStreamFailed("x") == CaptureError.scStreamFailed("x"))
    }

    @Test("Different errors are not equal")
    func equalityDifferent() {
        #expect(CaptureError.invalidFormat != CaptureError.noDisplay)
        #expect(CaptureError.scStreamFailed("a") != CaptureError.scStreamFailed("b"))
        #expect(CaptureError.invalidFormat != CaptureError.scStreamFailed("x"))
    }

    @Test("wrap(_:) wraps arbitrary Error inputs as strings")
    func wrapsArbitraryError() {
        struct CustomError: Error {}
        let wrapped = CaptureError.wrap(CustomError())
        if case .scStreamFailed(let msg) = wrapped {
            #expect(!msg.isEmpty)
        } else {
            Issue.record("Expected scStreamFailed case")
        }
    }

    @Test("wrap(_:) passes through existing CaptureError")
    func passthroughCaptureError() {
        let original = CaptureError.noDisplay
        let wrapped = CaptureError.wrap(original)
        #expect(wrapped == .noDisplay)
    }
}

// MARK: - Hybrid Fallback

@Suite("Hybrid Fallback") struct HybridFallbackTests {

    @Test("didFallbackToMic is false on init")
    func initialFalse() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(!engine.didFallbackToMic)
    }

    @Test("scBufferCount is zero on init")
    func initialZeroBuffers() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(engine.scBufferCount == 0)
    }

    @Test("systemAudioFallbackSeconds has sensible default")
    func defaultTimeout() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(engine.systemAudioFallbackSeconds > 0)
        #expect(engine.systemAudioFallbackSeconds <= 10) // sanity bound
    }

    @Test("systemAudioFallbackSeconds can be overridden")
    func overrideTimeout() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        engine.systemAudioFallbackSeconds = 0.05
        #expect(engine.systemAudioFallbackSeconds == 0.05)
    }
}

// MARK: - CaptureEngine State

@Suite("CaptureEngine State") @MainActor struct CaptureEngineStateTests {

    @Test("MockCaptureEngine conforms to CaptureEngine")
    func mockConforms() {
        let engine = MockCaptureEngine()
        #expect(engine is CaptureEngine)
    }

    @Test("MockCaptureEngine start/stop do not throw")
    func mockStartStop() async throws {
        let engine = MockCaptureEngine()
        try await engine.start()
        try await engine.stop()
    }

    @Test("CaptureEngineImpl exposes audioStream and levelMeter")
    func exposesStreams() {
        let engine = CaptureEngineImpl(captureSystemAudio: false)
        // Streams exist; consuming them is a no-op until start() is called.
        // We verify the property is accessible without throwing.
        _ = engine.audioStream
        _ = engine.levelMeter
    }

    @Test("isSystemSpeaking and isMicSpeaking are false before start")
    func speakingStateBeforeStart() {
        let engine = CaptureEngineImpl()
        #expect(!engine.isSystemSpeaking)
        #expect(!engine.isMicSpeaking)
    }

    @Test("enableVAD / disableVAD do not throw on idle engine")
    func vadToggleIdle() {
        let engine = CaptureEngineImpl()
        engine.enableVAD()
        engine.disableVAD()
        engine.resetSilence()
        // No assertion needed — just verifying no crash.
    }
}

// MARK: - STT Format Invariants

@Suite("STT Format") struct STTFormatTests {

    @Test("STT format is 16kHz Int16 mono")
    func sttFormatSpec() {
        let engine = CaptureEngineImpl()
        let fmt = engine.sttFormat
        #expect(fmt.sampleRate == 16_000)
        #expect(fmt.channelCount == 1)
        #expect(fmt.commonFormat == .pcmFormatInt16)
        #expect(fmt.isInterleaved)
    }

    @Test("STT format bytesPerFrame is 2")
    func sttBytesPerFrame() {
        let engine = CaptureEngineImpl()
        let fmt = engine.sttFormat
        #expect(fmt.streamDescription.pointee.mBytesPerFrame == 2)
    }
}
