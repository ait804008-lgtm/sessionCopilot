import Foundation

/// STT client implementation using Deepgram's streaming WebSocket API.
/// Conforms to SttClient protocol.
@MainActor
public final class DeepgramSttClient: SttClient {
    public let transcriptStream: AsyncStream<TranscriptSegment>

    private let transcriptContinuation: AsyncStream<TranscriptSegment>.Continuation
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionId = UUID()
    private var config: SttConfig?

    public init() {
        var cont: AsyncStream<TranscriptSegment>.Continuation!
        self.transcriptStream = AsyncStream { cont = $0 }
        self.transcriptContinuation = cont!
    }

    public func configure(_ config: SttConfig) async throws {
        self.config = config
        // ponytail: config stored for future reconnection/retry
    }

    public func start() async throws {
        // Connection established lazily on first sendAudio
        sessionId = UUID()
    }

    public func stop() async throws {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        transcriptContinuation.finish()
    }

    /// Feed raw audio data to the STT service.
    public func sendAudio(_ data: Data) async {
        guard let config else { return }
        
        // Lazy connect on first audio
        if webSocketTask == nil {
            let urlString: String
            switch config.provider {
            case .deepgram:
                urlString = "wss://api.deepgram.com/v1/listen?model=\(config.model)&language=\(config.language)&interim_results=\(config.interimResults)"
            case .nemo:
                urlString = "ws://localhost:8000/v1/audio/transcriptions/stream"
            }
            guard let url = URL(string: urlString) else { return }
            let session = URLSession(configuration: .default)

            // Deepgram requires auth: add Authorization header via URLRequest
            if config.provider == .deepgram, let apiKey = config.apiKey, !apiKey.isEmpty {
                var urlRequest = URLRequest(url: url)
                urlRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
                webSocketTask = session.webSocketTask(with: urlRequest)
            } else {
                webSocketTask = session.webSocketTask(with: url)
            }
            webSocketTask?.resume()
            Task { await receiveMessages() }
        }
        
        do {
            try await webSocketTask?.send(.data(data))
        } catch {
            // ponytail: log error, reconnect on next attempt
        }
    }

    // MARK: - Private

    private func receiveMessages() async {
        guard let ws = webSocketTask else { return }
        var receiving = true

        do {
            while receiving {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let channel = json["channel"] as? [String: Any],
                       let alternatives = channel["alternatives"] as? [[String: Any]],
                       let first = alternatives.first,
                       let transcript = first["transcript"] as? String,
                       !transcript.isEmpty {
                        let isFinal = (json["is_final"] as? Bool) ?? false
                        let confidence = (first["confidence"] as? Double).map(Float.init)
                        let segment = TranscriptSegment(
                            sessionId: sessionId,
                            timestamp: Date(),
                            speaker: .unknown,
                            text: transcript,
                            isFinal: isFinal,
                            confidence: confidence
                        )
                        transcriptContinuation.yield(segment)
                    }
                case .data(let data):
                    // Binary messages not expected from Deepgram
                    _ = data
                @unknown default:
                    break
                }
            }
        } catch {
            transcriptContinuation.yield(
                TranscriptSegment(
                    sessionId: sessionId,
                    timestamp: Date(),
                    speaker: .unknown,
                    text: "[STT disconnected]",
                    isFinal: true
                )
            )
        }
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
