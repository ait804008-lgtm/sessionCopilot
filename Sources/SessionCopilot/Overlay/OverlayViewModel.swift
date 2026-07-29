import Foundation
import Combine

public final class OverlayViewModel: ObservableObject {
    public var opacity: Double = 0.8 {
        didSet {
            opacity = min(1.0, max(0.1, opacity))
            onChanged()
        }
    }
    public var clickThrough: Bool = false
    public var isVisible: Bool = false
    public var isLive: Bool = false
    public var chatMessages: [ChatMessage] = []
    public var isStreaming: Bool = false
    public var errorMessage: String?
    public var sessionMode: SessionMode = .behavioral
    public var isDetectingSpeech: Bool = false

    public init() {}

    public func show() { isVisible = true }
    public func hide() { isVisible = false }
    public func toggle() { isVisible.toggle() }
    public func goLive() { clearChat(); isLive = true }
    public func endSession() { isLive = false }

    public func appendTranscript(_ segment: TranscriptSegment) {
        // Merge interim updates into the last user message if it's still the current utterance.
        // ponytail: after restartRecognition(), the new STT task yields interim results before
        // the old task's cancellation fires isFinal. If an assistant already answered this
        // question, don't overwrite it — start a new user bubble.
        if let lastIdx = chatMessages.lastIndex(where: { $0.role == .user && $0.isInterim }) {
            let hasAnswer = chatMessages[lastIdx...].contains(where: { $0.role == .assistant })
            if !hasAnswer {
                chatMessages[lastIdx].text = segment.text
                chatMessages[lastIdx].isInterim = !segment.isFinal
                onChanged()
                return
            }
        }
        chatMessages.append(ChatMessage(
            role: .user,
            text: segment.text,
            timestamp: segment.timestamp,
            isInterim: !segment.isFinal,
            segmentId: segment.id
        ))
        onChanged()
    }

    public func startAssistantResponse() {
        chatMessages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        onChanged()
    }

    public func updateAssistantResponse(_ text: String) {
        guard let idx = chatMessages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) else { return }
        chatMessages[idx].text = text
        onChanged()
    }

    public func finalizeAssistantResponse() {
        guard let idx = chatMessages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) else { return }
        chatMessages[idx].isStreaming = false
        onChanged()
    }

    func onChanged() {
        objectWillChange.send()
    }

    public func clearChat() {
        chatMessages.removeAll()
    }

    public var lastAssistantResponse: String {
        chatMessages.last(where: { $0.role == .assistant })?.text ?? ""
    }

    // MARK: - Streaming State

    public func setStreaming(_ active: Bool) {
        isStreaming = active
        onChanged()
    }

    // MARK: - Error State

    public var hasError: Bool {
        errorMessage != nil
    }

    public func setError(_ message: String) {
        errorMessage = message
        onChanged()
    }

    public func clearError() {
        errorMessage = nil
        onChanged()
    }

    // MARK: - Speech Detection

    public func setDetectingSpeech(_ active: Bool) {
        guard isDetectingSpeech != active else { return }
        isDetectingSpeech = active
        onChanged()
    }

    // MARK: - Transcription State

    /// True while waiting for a batch STT response (Deepgram pre-recorded API).
    public var isTranscribing: Bool = false

    public func setTranscribing(_ active: Bool) {
        guard isTranscribing != active else { return }
        isTranscribing = active
        onChanged()
    }
}
