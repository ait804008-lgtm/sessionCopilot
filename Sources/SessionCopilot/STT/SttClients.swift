import Foundation
import os

private let log = Logger(subsystem: "com.sessioncopilot.app", category: "stt")

// MARK: - Deepgram Batch STT Client

/// STT client that buffers audio and sends it to Deepgram's pre-recorded
/// REST API when a question boundary is detected (silence threshold).
///
/// Audio flows into `sendAudio(_:)` and is accumulated in an internal PCM
/// buffer. When `triggerFlush()` is called (from `SessionEngine`'s question-
/// detection callback), the buffer is wrapped in a WAV header and POSTed to
/// `https://api.deepgram.com/v1/listen`. The JSON response is parsed and
/// the transcript yielded through `transcriptStream`.
///
/// For long monologues, the buffer auto-flushes every ~15 seconds of audio
/// to keep transcripts flowing without waiting for a silence boundary.
@MainActor
public final class DeepgramSttClient: SttClient {
    public let transcriptStream: AsyncStream<TranscriptSegment>

    private let transcriptContinuation: AsyncStream<TranscriptSegment>.Continuation
    private var sessionId = UUID()
    private var config: SttConfig?
    private var audioBuffer = Data()
    private var isFlushing = false

    /// When true, a `triggerFlush()` (final) arrived while an auto-flush
    /// (non-final) was in flight. The in-flight request's result will be
    /// upgraded to `isFinal: true` when the response arrives, so the
    /// silence-triggered question isn't dropped.
    private var upgradeInFlightToFinal = false

    /// Most recent non-empty transcript text. Used to re-emit as final
    /// when an auto-flush returns empty but a final flush was pending.
    private var lastTranscriptText: String = ""

    /// ~15 seconds of audio at 16kHz/16bit/mono = 480 KB.
    private let autoFlushThreshold = 480_000

    /// Dedicated URLSession with a 30s timeout so a hung request doesn't
    /// permanently block the flush gate (`isFlushing` stuck true).
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    public init() {
        var cont: AsyncStream<TranscriptSegment>.Continuation!
        self.transcriptStream = AsyncStream { cont = $0 }
        self.transcriptContinuation = cont!
    }

    public func configure(_ config: SttConfig) async throws {
        self.config = config
        log.info("Deepgram configured: model=\(config.model, privacy: .public), lang=\(config.language, privacy: .public)")
    }

    public func start() async throws {
        sessionId = UUID()
        audioBuffer = Data()
        isFlushing = false
        upgradeInFlightToFinal = false
        lastTranscriptText = ""
        log.debug("Deepgram session started")
    }

    public func stop() async throws {
        log.debug("Deepgram stop — flushing remaining \(self.audioBuffer.count) bytes")
        if !audioBuffer.isEmpty {
            await flushBuffer(isFinal: true)
        }
        transcriptContinuation.finish()
    }

    /// Append raw PCM Int16 audio data to the internal buffer.
    /// Auto-flushes when the buffer exceeds ~15 seconds of audio.
    public func sendAudio(_ data: Data) async {
        audioBuffer.append(data)

        // Auto-flush on long monologues to keep transcripts flowing.
        if audioBuffer.count >= autoFlushThreshold && !isFlushing {
            log.info("Auto-flush triggered at \(self.audioBuffer.count) bytes (~\(self.audioBuffer.count / 32000)s)")
            await flushBuffer(isFinal: false)
        }
    }

    /// Called externally when a question boundary is detected (silence
    /// threshold reached). Sends the accumulated audio buffer to Deepgram
    /// and yields the final transcript.
    public func triggerFlush() async {
        log.info("triggerFlush called — isFlushing=\(self.isFlushing), bufferSize=\(self.audioBuffer.count)")
        guard !isFlushing else {
            log.info("triggerFlush — auto-flush in flight, upgrade result to final")
            upgradeInFlightToFinal = true
            return
        }
        await flushBuffer(isFinal: true)
    }

    // MARK: - Private

    private func flushBuffer(isFinal: Bool) async {
        guard let config, !isFlushing else {
            if isFlushing {
                log.warning("flushBuffer skipped — already flushing (isFinal=\(isFinal))")
            }
            return
        }
        isFlushing = true

        // Snapshot and clear the buffer atomically (before any suspension).
        let chunk = audioBuffer
        audioBuffer = Data()

        guard !chunk.isEmpty else {
            log.debug("flushBuffer — empty buffer, skipping")
            isFlushing = false
            return
        }

        log.info("Flushing \(chunk.count) bytes (~\(chunk.count / 32000)s) isFinal=\(isFinal)")

        // Wrap PCM in WAV header (16kHz, 16-bit, mono).
        let wavData = wavHeader(
            sampleRate: 16000,
            bitsPerSample: 16,
            channels: 1,
            dataLength: UInt32(chunk.count)
        ) + chunk

        let urlString = "https://api.deepgram.com/v1/listen?smart_format=true&language=\(config.language)&model=\(config.model)"
        guard let url = URL(string: urlString) else {
            log.error("Invalid Deepgram URL: \(urlString, privacy: .public)")
            isFlushing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(config.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavData

        let startTime = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = Date().timeIntervalSince(startTime)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                log.error("Deepgram HTTP \(status) after \(elapsed, privacy: .public)s")
                transcriptContinuation.yield(
                    TranscriptSegment(sessionId: sessionId, timestamp: Date(),
                        speaker: .unknown, text: "[STT error]", isFinal: true)
                )
                isFlushing = false
                return
            }

            log.info("Deepgram response: HTTP \(httpResponse.statusCode) in \(elapsed, privacy: .public)s")

            // Deepgram pre-recorded response format:
            // {"results": {"channels": [{"alternatives": [{"transcript": "...", "confidence": 0.9}]}]}}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [String: Any],
               let channels = results["channels"] as? [[String: Any]],
               let alternatives = channels.first?["alternatives"] as? [[String: Any]],
               let first = alternatives.first,
               let transcript = first["transcript"] as? String,
               !transcript.trimmingCharacters(in: .whitespaces).isEmpty {
                let confidence = (first["confidence"] as? Double).map(Float.init)
                log.info("Transcript: \"\(transcript.prefix(80), privacy: .public)\" confidence=\(confidence ?? 0, privacy: .public)")
                // If a final flush was requested while this auto-flush was
                // in flight, upgrade the result so the silence-triggered
                // question isn't dropped (see triggerFlush() guard).
                let effectiveFinal = isFinal || upgradeInFlightToFinal
                if upgradeInFlightToFinal {
                    upgradeInFlightToFinal = false
                    log.info("Upgrading auto-flush result to final")
                }
                lastTranscriptText = transcript
                let segment = TranscriptSegment(
                    sessionId: sessionId,
                    timestamp: Date(),
                    speaker: .unknown,
                    text: transcript,
                    isFinal: effectiveFinal,
                    confidence: confidence
                )
                transcriptContinuation.yield(segment)
            } else {
                log.warning("Deepgram returned empty transcript or unexpected format")
                // Edge case: auto-flush returned empty, but a final flush
                // was requested while it was in flight. Re-emit the last
                // known transcript as final so SessionEngine unblocks.
                if upgradeInFlightToFinal {
                    upgradeInFlightToFinal = false
                    let fallback = lastTranscriptText
                    if !fallback.isEmpty {
                        log.info("Auto-flush empty, re-emitting last transcript as final: \"\(fallback.prefix(60), privacy: .public)\"")
                        transcriptContinuation.yield(
                            TranscriptSegment(sessionId: sessionId, timestamp: Date(),
                                speaker: .unknown, text: fallback, isFinal: true)
                        )
                    }
                }
            }
        } catch {
            log.error("Deepgram request failed: \(error.localizedDescription, privacy: .public)")
            transcriptContinuation.yield(
                TranscriptSegment(sessionId: sessionId, timestamp: Date(),
                    speaker: .unknown, text: "[STT error]", isFinal: true)
            )
        }

        isFlushing = false
        log.debug("flushBuffer complete — isFlushing reset to false")
    }

    /// Build a minimal WAV header for raw PCM data.
    /// Shared format with NemoSttClient below.
    private func wavHeader(sampleRate: UInt32, bitsPerSample: UInt16, channels: UInt16, dataLength: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(bitsPerSample / 8) * UInt32(channels)
        let blockAlign = UInt16(bitsPerSample / 8) * channels
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: (36 + dataLength).littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataLength.littleEndian) { Data($0) })
        return header
    }
}

// MARK: - Errors

enum SttError: Error {
    case notConfigured
    case invalidURL
}

// MARK: - Local NeMo STT

/// STT client for local NVIDIA NIM (NeMo) endpoint.
/// Sends audio via HTTP POST to the NIM audio transcription API.
@MainActor
public final class NemoSttClient: SttClient {
    public let transcriptStream: AsyncStream<TranscriptSegment>

    private let transcriptContinuation: AsyncStream<TranscriptSegment>.Continuation
    private var baseURL = "http://localhost:8000"
    private var sessionId = UUID()
    private var audioBuffer = Data()
    private var isProcessing = false
    private var language = "en"

    public init() {
        var cont: AsyncStream<TranscriptSegment>.Continuation!
        self.transcriptStream = AsyncStream { cont = $0 }
        self.transcriptContinuation = cont!
    }

    public func configure(_ config: SttConfig) async throws {
        language = config.language
        // ponytail: configurable endpoint; default localhost:8000 for NVIDIA NIM
    }

    public func start() async throws {
        sessionId = UUID()
        audioBuffer = Data()
    }

    public func stop() async throws {
        // Flush remaining audio before finishing
        if !audioBuffer.isEmpty {
            await flushBuffer()
        }
        transcriptContinuation.finish()
    }

    public func sendAudio(_ data: Data) async {
        audioBuffer.append(data)
        // Send every ~1s of audio (16000 bytes at 16kHz/16bit mono)
        guard audioBuffer.count >= 16000, !isProcessing else { return }
        await flushBuffer()
    }

    // MARK: - Private

    private func flushBuffer() async {
        guard !audioBuffer.isEmpty else { return }
        isProcessing = true
        let chunk = audioBuffer
        audioBuffer = Data()

        // Build multipart form data with WAV header for NIM compatibility
        let boundary = UUID().uuidString
        var body = Data()
        let wavData = wavHeader(sampleRate: 16000, bitsPerSample: 16, channels: 1, dataLength: UInt32(chunk.count)) + chunk

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        guard let url = URL(string: "\(baseURL)/v1/audio/transcriptions?language=\(language)") else {
            isProcessing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = json["text"] as? String, !text.isEmpty {
                let segment = TranscriptSegment(
                    sessionId: sessionId,
                    timestamp: Date(),
                    speaker: .unknown,
                    text: text,
                    isFinal: true
                )
                transcriptContinuation.yield(segment)
            }
        } catch {
            // ponytail: log error, continue silently
        }
        isProcessing = false
    }

    /// Build a minimal WAV header for raw PCM data.
    private func wavHeader(sampleRate: UInt32, bitsPerSample: UInt16, channels: UInt16, dataLength: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(bitsPerSample / 8) * UInt32(channels)
        let blockAlign = UInt16(bitsPerSample / 8) * channels
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: (36 + dataLength).littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataLength.littleEndian) { Data($0) })
        return header
    }
}
