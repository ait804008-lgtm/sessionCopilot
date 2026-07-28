import Foundation
import Speech

/// Local STT client using Apple's on-device SFSpeechRecognizer.
/// Works offline on Apple Silicon, no API keys needed.
/// Requires Speech Recognition permission (NSSpeechRecognitionUsageDescription).
@MainActor
public final class AppleSttClient: SttClient {
    public let transcriptStream: AsyncStream<TranscriptSegment>

    private let transcriptContinuation: AsyncStream<TranscriptSegment>.Continuation
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var sessionId = UUID()
    private let audioEngine = AVAudioEngine()

    public init() {
        var cont: AsyncStream<TranscriptSegment>.Continuation!
        self.transcriptStream = AsyncStream { cont = $0 }
        self.transcriptContinuation = cont!
    }

    public func configure(_ config: SttConfig) async throws {
        let locale: Locale
        switch config.language {
        case "en": locale = Locale(identifier: "en-US")
        case "fr": locale = Locale(identifier: "fr-FR")
        case "es": locale = Locale(identifier: "es-ES")
        case "de": locale = Locale(identifier: "de-DE")
        case "zh": locale = Locale(identifier: "zh-CN")
        case "ja": locale = Locale(identifier: "ja-JP")
        case "ko": locale = Locale(identifier: "ko-KR")
        case "pt": locale = Locale(identifier: "pt-BR")
        case "it": locale = Locale(identifier: "it-IT")
        case "ru": locale = Locale(identifier: "ru-RU")
        case "ar": locale = Locale(identifier: "ar-SA")
        case "hi": locale = Locale(identifier: "hi-IN")
        case "nl": locale = Locale(identifier: "nl-NL")
        case "sv": locale = Locale(identifier: "sv-SE")
        case "tr": locale = Locale(identifier: "tr-TR")
        case "pl": locale = Locale(identifier: "pl-PL")
        case "th": locale = Locale(identifier: "th-TH")
        case "vi": locale = Locale(identifier: "vi-VN")
        case "id": locale = Locale(identifier: "id-ID")
        case "ms": locale = Locale(identifier: "ms-MY")
        default: locale = Locale(identifier: "en-US")
        }
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func start() async throws {
        guard let recognizer, recognizer.isAvailable else {
            throw SttError.notConfigured
        }

        sessionId = UUID()
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.taskHint = .dictation

        guard let request = recognitionRequest else { return }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Ignore transient errors — only yield actual transcriptions
            guard let result else { return }

            // Emit the best transcription
            let text = result.bestTranscription.formattedString
            guard !text.isEmpty else { return }

            let segment = TranscriptSegment(
                sessionId: self.sessionId,
                timestamp: Date(),
                speaker: .unknown,
                text: text,
                isFinal: result.isFinal,
                confidence: nil
            )
            self.transcriptContinuation.yield(segment)
        }
    }

    public func stop() async throws {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognizer = nil
    }

    /// Restart speech recognition so the next utterance starts fresh.
    /// Creates new request BEFORE tearing down old to avoid audio drop.
    public func restartRecognition() {
        let oldTask = recognitionTask
        let oldRequest = recognitionRequest

        guard let recognizer, recognizer.isAvailable else { return }

        // Create new request first — audio flows into it immediately
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest?.shouldReportPartialResults = true
        recognitionRequest?.taskHint = .dictation

        guard let request = recognitionRequest else { return }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Ignore transient errors — only yield actual transcriptions
            guard let result else { return }

            let text = result.bestTranscription.formattedString
            guard !text.isEmpty else { return }

            let segment = TranscriptSegment(
                sessionId: self.sessionId,
                timestamp: Date(),
                speaker: .unknown,
                text: text,
                isFinal: result.isFinal,
                confidence: nil
            )
            self.transcriptContinuation.yield(segment)
        }

        // Now tear down old task/request
        oldTask?.cancel()
        oldRequest?.endAudio()
    }

    /// Feed raw PCM Int16 audio data to the speech recognizer.
    public func sendAudio(_ data: Data) async {
        guard let request = recognitionRequest else { return }

        // Convert Data (Int16) to AVAudioPCMBuffer
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ) else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            buffer.int16ChannelData?.pointee.update(from: base.assumingMemoryBound(to: Int16.self), count: frameCount)
        }

        request.append(buffer)
    }
}
