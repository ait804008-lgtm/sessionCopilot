import Foundation

// MARK: - Audio Types

public struct AudioBuffer: Codable, Sendable {
    public enum Source: String, Codable, Sendable {
        case mic
        case system
        case unknown
    }

    public let data: Data
    public let timestamp: Date
    public let sampleRate: Int
    public let channels: Int
    public let source: Source

    public init(data: Data, timestamp: Date, sampleRate: Int, channels: Int, source: Source = .unknown) {
        self.data = data
        self.timestamp = timestamp
        self.sampleRate = sampleRate
        self.channels = channels
        self.source = source
    }
}

// MARK: - Transcript Segment

public struct TranscriptSegment: Codable, Sendable, Identifiable {
    public enum Speaker: String, Codable, Sendable {
        case system
        case mic
        case unknown
    }

    public let id: UUID
    public let sessionId: UUID
    public let timestamp: Date
    public let speaker: Speaker
    public let text: String
    public let isFinal: Bool
    public let confidence: Float?

    public init(id: UUID = UUID(), sessionId: UUID, timestamp: Date, speaker: Speaker, text: String, isFinal: Bool, confidence: Float? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

// MARK: - STT Config

public struct SttConfig: Codable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case deepgram
        case nemo
    }

    public let provider: Provider
    public let model: String
    public let language: String
    public let interimResults: Bool
    public let apiKey: String?

    public init(provider: Provider, model: String, language: String = "en", interimResults: Bool = true, apiKey: String? = nil) {
        self.provider = provider
        self.model = model
        self.language = language
        self.interimResults = interimResults
        self.apiKey = apiKey
    }
}

// MARK: - LLM Types

public struct LlmRequest: Codable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case behavioral
        case technicalVerbal = "technical_verbal"
        case meeting
        case coding
    }

    public let model: String
    public let mode: Mode
    public let prompt: String
    public let context: [String: String]
    public let maxTokens: Int
    public let imageBase64: String?

    public init(model: String, mode: Mode, prompt: String, context: [String: String] = [:], imageBase64: String? = nil, maxTokens: Int = 500) {
        self.model = model
        self.mode = mode
        self.prompt = prompt
        self.context = context
        self.imageBase64 = imageBase64
        self.maxTokens = maxTokens
    }
}

public struct LlmToken: Codable, Sendable {
    public let text: String
    public let isDone: Bool

    public init(text: String, isDone: Bool = false) {
        self.text = text
        self.isDone = isDone
    }
}

public struct LlmResponse: Codable, Sendable {
    public struct Section: Codable, Sendable {
        public let title: String
        public let content: String

        public init(title: String, content: String) {
            self.title = title
            self.content = content
        }
    }

    public let sections: [Section]
    public let metadata: [String: String]

    public init(sections: [Section], metadata: [String: String] = [:]) {
        self.sections = sections
        self.metadata = metadata
    }
}

// MARK: - Session

public struct Session: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case preflight
        case live
        case paused
        case done
    }

    public enum Mode: String, Codable, Sendable {
        case behavioral
        case technicalVerbal = "technical_verbal"
        case meeting
        case coding
    }

    public let id: UUID
    public let profileId: UUID
    public let mode: Mode
    public var title: String?
    public var status: Status
    public let startedAt: Date
    public var endedAt: Date?
    public var segments: [TranscriptSegment]
    public var suggestions: [Suggestion]
    public var metadata: [String: String]

    /// Relative path to the recorded audio file (WAV, 16kHz Int16 mono)
    /// under `~/Library/Application Support/SessionCopilot/audio/`.
    /// Nil if audio recording was disabled or the file was deleted.
    public var audioFilePath: String?

    public init(id: UUID = UUID(), profileId: UUID, mode: Mode, title: String? = nil, status: Status = .preflight, startedAt: Date = Date(), endedAt: Date? = nil, segments: [TranscriptSegment] = [], suggestions: [Suggestion] = [], metadata: [String: String] = [:], audioFilePath: String? = nil) {
        self.id = id
        self.profileId = profileId
        self.mode = mode
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.suggestions = suggestions
        self.metadata = metadata
        self.audioFilePath = audioFilePath
    }
}

// MARK: - Profile

public struct Profile: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var resumeText: String
    public var resumeParsed: [String: [String]]
    public var defaultJD: String?
    public var starStories: [StarStory]
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, resumeText: String = "", resumeParsed: [String: [String]] = [:], defaultJD: String? = nil, starStories: [StarStory] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.resumeText = resumeText
        self.resumeParsed = resumeParsed
        self.defaultJD = defaultJD
        self.starStories = starStories
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Star Story

public struct StarStory: Codable, Sendable, Identifiable {
    public let id: UUID
    public var situation: String
    public var task: String
    public var action: String
    public var result: String
    public var tags: [String]

    public init(id: UUID = UUID(), situation: String, task: String, action: String, result: String, tags: [String] = []) {
        self.id = id
        self.situation = situation
        self.task = task
        self.action = action
        self.result = result
        self.tags = tags
    }
}

// MARK: - Provider Config

public struct ProviderConfig: Codable, Sendable, Identifiable {
    public enum Provider: String, Codable, Sendable {
        case deepseek
        case anthropic
        case openai
        case nemotron
        case deepgram
        case gemini
        case custom

        /// Whether this provider supports LLM chat completions (as opposed
        /// to being STT-only like Deepgram). Used to filter `defaultConfig()`
        /// so an STT provider never gets picked up for LLM calls.
        public var isLLM: Bool {
            switch self {
            case .deepseek, .anthropic, .openai, .nemotron, .gemini, .custom:
                return true
            case .deepgram:
                return false
            }
        }
    }

    public let id: UUID
    public let provider: Provider
    public let baseURL: String
    public let model: String
    public let apiKeyRef: String
    public var isDefault: Bool

    public init(id: UUID = UUID(), provider: Provider, baseURL: String, model: String, apiKeyRef: String, isDefault: Bool = false) {
        self.id = id
        self.provider = provider
        self.baseURL = baseURL
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.isDefault = isDefault
    }
}

// MARK: - Suggestion

public struct Suggestion: Codable, Sendable, Identifiable {
    public enum SuggestionType: String, Codable, Sendable {
        case answerOutline = "answer_outline"
        case coachTip = "coach_tip"
        case followUp = "follow_up"
        case codeSolution = "code_solution"
    }

    public let id: UUID
    public let sessionId: UUID
    public let segmentId: UUID?
    public let timestamp: Date
    public let type: SuggestionType
    public var content: String
    public var metadata: [String: String]

    public init(id: UUID = UUID(), sessionId: UUID, segmentId: UUID? = nil, timestamp: Date = Date(), type: SuggestionType, content: String, metadata: [String: String] = [:]) {
        self.id = id
        self.sessionId = sessionId
        self.segmentId = segmentId
        self.timestamp = timestamp
        self.type = type
        self.content = content
        self.metadata = metadata
    }
}

// MARK: - Settings

public struct AppSettings: Codable, Sendable {
    public struct Hotkeys: Codable, Sendable {
        public var showHide: String
        public var startStop: String
        public var regionCapture: String
        public var copyLast: String
        public var pushToTalk: String

        public init(showHide: String = "cmd+shift+o", startStop: String = "cmd+shift+s", regionCapture: String = "cmd+shift+a", copyLast: String = "cmd+shift+c", pushToTalk: String = "ctrl+shift+space") {
            self.showHide = showHide
            self.startStop = startStop
            self.regionCapture = regionCapture
            self.copyLast = copyLast
            self.pushToTalk = pushToTalk
        }
    }

    public var hotkeys: Hotkeys
    public var opacity: Double
    public var clickThrough: Bool
    public var retentionDays: Int
    public var defaultModels: [String: String]
    public var exportPath: String?
    public var sttProvider: String
    public var sttLanguage: String
    /// "auto" = always listening; "pushToTalk" = hold hotkey to listen
    public var listenMode: String

    /// When true, candidate questions detected by VAD are confirmed by an
    /// LLM call before answer generation fires. Avoids spurious LLM calls
    /// on natural thinking pauses. Default: true (recommended).
    public var semanticDetectionEnabled: Bool

    /// Silence threshold in seconds. When the interviewer stops speaking
    /// for this long, `QuestionDetector` fires `onQuestionDetected`.
    /// Lower = more aggressive (fires on short pauses); higher = more
    /// conservative (waits for longer silences). Default: 1.5s.
    /// Range: 0.5s – 5.0s. Adjust in Settings → General.
    public var silenceThreshold: Double

    /// When true, audio (mic + system, mixed) is recorded to a WAV file
    /// for each session and made available for replay in SessionDetailView.
    /// Default: true. Storage cost: ~10 MB per 30-min session at 16kHz Int16 mono.
    public var audioRecordingEnabled: Bool

    public init(
        hotkeys: Hotkeys = Hotkeys(),
        opacity: Double = 0.8,
        clickThrough: Bool = false,
        retentionDays: Int = 30,
        defaultModels: [String: String] = [:],
        exportPath: String? = nil,
        sttProvider: String = "apple",
        sttLanguage: String = "en",
        listenMode: String = "auto",
        semanticDetectionEnabled: Bool = true,
        silenceThreshold: Double = 1.5,
        audioRecordingEnabled: Bool = true
    ) {
        self.hotkeys = hotkeys
        self.opacity = opacity
        self.clickThrough = clickThrough
        self.retentionDays = retentionDays
        self.defaultModels = defaultModels
        self.exportPath = exportPath
        self.sttProvider = sttProvider
        self.sttLanguage = sttLanguage
        self.listenMode = listenMode
        self.semanticDetectionEnabled = semanticDetectionEnabled
        self.silenceThreshold = silenceThreshold
        self.audioRecordingEnabled = audioRecordingEnabled
    }

    // MARK: - Codable (backward-compatible decoding)

    private enum CodingKeys: String, CodingKey {
        case hotkeys, opacity, clickThrough, retentionDays, defaultModels
        case exportPath, sttProvider, sttLanguage, listenMode
        case semanticDetectionEnabled, silenceThreshold, audioRecordingEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkeys = try c.decodeIfPresent(Hotkeys.self, forKey: .hotkeys) ?? Hotkeys()
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.8
        clickThrough = try c.decodeIfPresent(Bool.self, forKey: .clickThrough) ?? false
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        defaultModels = try c.decodeIfPresent([String: String].self, forKey: .defaultModels) ?? [:]
        exportPath = try c.decodeIfPresent(String.self, forKey: .exportPath)
        sttProvider = try c.decodeIfPresent(String.self, forKey: .sttProvider) ?? "apple"
        sttLanguage = try c.decodeIfPresent(String.self, forKey: .sttLanguage) ?? "en"
        listenMode = try c.decodeIfPresent(String.self, forKey: .listenMode) ?? "auto"
        semanticDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .semanticDetectionEnabled) ?? true
        silenceThreshold = try c.decodeIfPresent(Double.self, forKey: .silenceThreshold) ?? 1.5
        audioRecordingEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioRecordingEnabled) ?? true
    }
}

// MARK: - Chat Message

public struct ChatMessage: Codable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public let timestamp: Date
    public var isStreaming: Bool
    public var isInterim: Bool
    public let segmentId: UUID?

    public init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date(), isStreaming: Bool = false, isInterim: Bool = false, segmentId: UUID? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.isInterim = isInterim
        self.segmentId = segmentId
    }
}

// MARK: - Export Format

public enum ExportFormat: String, Codable, Sendable {
    case markdown
    case json
}

// MARK: - Session Mode (for overlay mode picker)

public enum SessionMode: String, Codable, Sendable, CaseIterable {
    case behavioral
    case coding
    case systemDesign = "system_design"
    case meeting

    public var label: String {
        switch self {
        case .behavioral: return "Behavioral"
        case .coding: return "Coding"
        case .systemDesign: return "System Design"
        case .meeting: return "Meeting"
        }
    }

    public var icon: String {
        switch self {
        case .behavioral: return "person.wave.2"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .systemDesign: return "square.grid.3x3"
        case .meeting: return "person.3"
        }
    }

    /// Key used in AppSettings.defaultModels dictionary
    public var defaultModelKey: String {
        switch self {
        case .behavioral: return "behavioral"
        case .coding: return "coding"
        case .systemDesign: return "system_design"
        case .meeting: return "meeting"
        }
    }
}

// MARK: - Question Classification

/// Result of a semantic question classification.
///
/// Produced by `QuestionClassifier.classify(_:context:)`. Used by
/// `SessionEngine` to gate answer generation: when
/// `semanticDetectionEnabled` is true, the LLM answer is only triggered
/// if `isQuestion == true`. This avoids spurious LLM calls on the
/// candidate's own thinking pauses (which the pure-VAD `QuestionDetector`
/// can't distinguish from interviewer silence).
public struct QuestionClassification: Codable, Sendable, Equatable {
    /// True if the classified text is judged to be a question directed
    /// at the candidate (i.e. requires an answer).
    public let isQuestion: Bool
    /// Confidence in the classification, 0.0 – 1.0.
    public let confidence: Double
    /// Optional short rationale explaining the classification. Logged
    /// for debugging; not shown to the user.
    public let rationale: String?

    public init(isQuestion: Bool, confidence: Double, rationale: String? = nil) {
        self.isQuestion = isQuestion
        self.confidence = confidence
        self.rationale = rationale
    }

    /// Default "yes" classification used when the classifier is disabled
    /// or unavailable. Maintains backward-compatible behavior (every
    /// VAD trigger fires the LLM answer).
    public static let assumedYes = QuestionClassification(
        isQuestion: true,
        confidence: 1.0,
        rationale: "Semantic classification disabled — assuming question."
    )

    /// Default "no" classification used when the classifier call fails.
    /// Conservative: don't fire the LLM on errors, since spurious LLM
    /// calls cost money and pollute the overlay.
    public static let assumedNo = QuestionClassification(
        isQuestion: false,
        confidence: 0.0,
        rationale: "Classification failed — assuming not a question."
    )
}
