import Foundation
import os

/// Centralized `os.Logger` instances for SessionCopilot.
///
/// Replaces ad-hoc `fputs(stderr, ...)` calls with structured logging
/// that's filterable in Console.app. Each module gets its own category
/// so log streams can be narrowed during debugging:
///
/// ```bash
/// # All SessionCopilot logs:
/// log stream --predicate 'subsystem == "com.sessioncopilot.app"' --level debug
///
/// # Just SCStream audio pipeline:
/// log stream --predicate \
///   'subsystem == "com.sessioncopilot.app" AND category == "sc-audio"' \
///   --level debug
///
/// # Just TCC / permission issues:
/// log stream --predicate \
///   'subsystem == "com.sessioncopilot.app" AND category == "permissions"'
/// ```
///
/// ## Usage
///
/// ```swift
/// import Foundation
///
/// private let log = Log.capture
///
/// log.info("SCStream started")
/// log.error("Failed: \(error.localizedDescription, privacy: .public)")
/// log.debug("Frame count = \(frameCount)")
/// ```
///
/// ## Privacy
///
/// `os.Logger` defaults to `<private>` for interpolated values. Use
/// `\(value, privacy: .public)` for non-sensitive values that should
/// appear in plain text in Console.app. Audio sample data, transcripts,
/// API keys, and personal information MUST remain private (the default).
public enum Log {
    /// Subsystem identifier. Matches the bundle ID and TCC client ID
    /// so logs and permissions correlate in Console.app.
    public static let subsystem = "com.sessioncopilot.app"

    /// Audio capture pipeline (mic tap, SCStream, AVAudioConverter,
    /// hybrid fallback watchdog).
    public static let capture = Logger(
        subsystem: subsystem,
        category: "capture"
    )

    /// SCStream-specific events. Subset of `capture` — useful for
    /// diagnosing "SCStream silently produces nothing" issues.
    public static let scAudio = Logger(
        subsystem: subsystem,
        category: "sc-audio"
    )

    /// Speech recognition (SFSpeechRecognizer, Deepgram).
    public static let stt = Logger(
        subsystem: subsystem,
        category: "stt"
    )

    /// LLM provider calls (OpenAI, Anthropic, DeepSeek, Gemini).
    public static let llm = Logger(
        subsystem: subsystem,
        category: "llm"
    )

    /// Session lifecycle (start, stop, persistence).
    public static let session = Logger(
        subsystem: subsystem,
        category: "session"
    )

    /// UI / overlay state changes.
    public static let ui = Logger(
        subsystem: subsystem,
        category: "ui"
    )

    /// Hotkey registration and dispatch.
    public static let hotkey = Logger(
        subsystem: subsystem,
        category: "hotkey"
    )

    /// Settings load / save / migration.
    public static let settings = Logger(
        subsystem: subsystem,
        category: "settings"
    )

    /// Permission / TCC state.
    public static let permissions = Logger(
        subsystem: subsystem,
        category: "permissions"
    )

    /// Audio recording (WAV file writing for session replay).
    public static let recording = Logger(
        subsystem: subsystem,
        category: "recording"
    )

    /// Semantic question classification (LLM-based).
    public static let classifier = Logger(
        subsystem: subsystem,
        category: "classifier"
    )

    /// General app lifecycle.
    public static let app = Logger(
        subsystem: subsystem,
        category: "app"
    )
}
