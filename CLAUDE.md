# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

SessionCopilot is a macOS menu-bar app (Swift 6, SwiftPM) for real-time interview coaching. It captures **microphone** (candidate) and **system audio** (interviewer from Teams/Zoom/etc.) via `AVAudioEngine` + `SCStream`, transcribes both through on-device `SFSpeechRecognizer` (or Deepgram), detects question boundaries with VAD, and fires LLM completions to a floating overlay.

## Critical runtime constraint

**The app must run from a `.app` bundle, never `swift run`.** Without a bundle, SCStream's `startCapture()` returns `noErr` but never delivers audio buffers — the app runs with a silent zombie stream. The bundle provides a stable code-signing identity for TCC permissions to persist across rebuilds.

## Build & test commands

```bash
# Build + assemble .app + ad-hoc sign (release)
./scripts/build_app_bundle.sh

# Debug build
./scripts/build_app_bundle.sh --debug

# Build + install to /Applications/
./scripts/build_app_bundle.sh --install

# Run from staged bundle (no install)
open .build/app-stage/SessionCopilot.app

# Run all tests (Swift Testing framework — @Suite/@Test, not XCTest)
swift test

# Open in Xcode
open Package.swift
```

Tests depend on `AVFoundation`/`AVAudioConverter` — they only run on macOS.

## Architecture

### Controller-based composition root

`AppDelegate` (at `Sources/SessionCopilot/App/App.swift`) is a thin coordinator. It creates `Services` (shared stores), then wires five controllers:

| Controller | File | Responsibility |
|---|---|---|
| `MenuBarController` | `App/Controllers/MenuBarController.swift` | Status item + menu |
| `HotkeyController` | `App/Controllers/HotkeyController.swift` | Global/local hotkeys |
| `WindowController` | `App/Controllers/WindowController.swift` | Preflight, settings, history, responsible-use windows; overlay panel |
| `SessionLifecycleController` | `App/Controllers/SessionLifecycleController.swift` | Creates `CaptureEngineImpl` + STT client + `SessionEngine`; start/stop/toggle |
| `LlmOrchestrator` | `App/Controllers/LlmOrchestrator.swift` | LLM answer generation, question classification, coding screenshot capture, clipboard copy |

Callbacks wire inter-controller communication:
- `SessionLifecycleController.onQuestionDetected` → `LlmOrchestrator.handleQuestion(_:)`
- `SessionLifecycleController.onCaptureStatusChange` → `MenuBarController.updateStatus(_:)`
- `WindowController.onOverlayClose` → `AppDelegate.stopCapture()`

### Core protocol layer (`Protocols/Protocols.swift`)

Five protocols define the app's seams:

- **`CaptureEngine`** — `AsyncStream<AudioBuffer>` for audio, `AsyncStream<Float>` for level meter, VAD control (`enableVAD`/`disableVAD`/`resetSilence`), `isSystemSpeaking`/`isMicSpeaking` flags. Implemented by `CaptureEngineImpl` and `MockCaptureEngine` (for testing).
- **`SttClient`** — `AsyncStream<TranscriptSegment>` for transcripts, `configure`/`start`/`stop`/`sendAudio`. Implemented by `AppleSttClient` (on-device), `DeepgramSttClient` (cloud WebSocket), and `NemoSttClient` (local NVIDIA NIM).
- **`LlmClient`** — `streamCompletion` returns `AsyncStream<LlmToken>`, `complete` returns `LlmResponse`. Implemented by `LlmClientImpl` (supports DeepSeek, Anthropic, OpenAI-compatible APIs).
- **`QuestionClassifier`** — `classify(_:context:)` returns `QuestionClassification` (isQuestion + confidence + rationale). Implemented by `LlmQuestionClassifier` using a cheap LLM call. Gated by `AppSettings.semanticDetectionEnabled`.
- **`SessionStore`** — CRUD for `Session`/`TranscriptSegment`/`Suggestion` + export + retention cleanup. Implemented by `SessionStoreImpl` (JSON file-based in `~/Library/Application Support/SessionCopilot/sessions.json`).

### Data flow

```
Mic (AVAudioEngine) ──┐
                       ├──▶ CaptureEngineImpl.audioStream (AsyncStream<AudioBuffer>, 16kHz Int16 mono)
System Audio (SCStream)┘       │
                                ├──▶ SttClient.sendAudio() → transcriptStream
                                │         │
                                │         └──▶ OverlayViewModel.appendTranscript()
                                │                    │
                                │                    └──▶ SessionEngine.resolveSpeaker()
                                │                         (system-active → .system, mic-active → .mic)
                                │
                                ├──▶ AudioRecorder (optional — records mic+system mix to WAV)
                                │         │
                                │         └──▶ ~/Library/Application Support/SessionCopilot/audio/<sessionId>.wav
                                │
                                ├──▶ systemDetector (VAD, 1.5s silence → onQuestionDetected)
                                │         │
                                │         └──▶ SessionEngine.onQuestionDetected
                                │                    │
                                │                    └──▶ LlmOrchestrator.handleQuestion()
                                │                              │
                                │                              ├── [semanticDetectionEnabled?]
                                │                              │     └──▶ LlmQuestionClassifier.classify()
                                │                              │              │
                                │                              │              └── isQuestion==true?
                                │                              │                     │
                                │                              └──▶ fireLlmAnswer() ──▶ overlay chat
                                │
                                └──▶ micDetector (VAD → isMicSpeaking — attribution only, never fires LLM)
```

### SCStream audio capture (`CaptureEngineImpl.swift`)

The system audio path uses `SCStream` with `capturesAudio = true`, receiving `CMSampleBuffer` (Float32 48kHz stereo). A lazily-built `AVAudioConverter` converts to 16kHz Int16 mono on a dedicated **serial** `DispatchQueue` (`.global()` is concurrent and can drop/reorder samples). Important details:

- **Delegate boxes** (`SCStreamDelegateBox`, `SCAudioOutputBox`) are strongly retained by `CaptureEngineImpl` — `SCStream.delegate` is weak and `addStreamOutput` doesn't retain, so without strong references ARC deallocates them mid-stream.
- **Hybrid fallback**: If `scBufferCount` is still 0 after `systemAudioFallbackSeconds` (default 2.0s), the mic tap starts feeding `systemDetector` so question detection works — with degraded speaker attribution (both sides tagged as mic). The `didFallbackToMic` flag latches true.
- **Format conversion helpers** (`convertPCM`, `makeFloatBuffer`, `computeRMS`) are `internal static` — testable without instantiating the full engine.
- **`AVAudioConverter.convert(to:from:)` (throwing overload) crashes on ObjC exceptions** from `_AVAE_Check` — the code uses the NSError-based `convert(to:error:withInputFrom:)` overload instead.

### CaptureStatus and menu bar indicator

`CaptureEngineImpl` exposes a `CaptureStatus` enum (`idle`/`micOnly`/`systemActive`/`systemFallback`/`failed`) with a `label`, `dotSymbol`, and `dotColorName`. Status transitions fire `onStatusChange`, which `SessionLifecycleController` wires to `MenuBarController.updateStatus(_:)`. The menu bar shows a colored dot: gray (idle), blue (mic only), green (system active), amber (fallback), red (failed).

### Listen modes

Two modes, toggled via `SettingsStore.settings.listenMode`:

- **`"auto"`** — VAD is always on. `systemDetector` detects 1.5s of silence after speech, fires `onQuestionDetected`, then STT is restarted (`AppleSttClient.restartRecognition()`).
- **`"pushToTalk"`** — VAD is off by default. User holds `ctrl+shift+space` (configurable) to enable listening. Audio only flows to STT while the key is held. Key-up triggers question detection with the accumulated transcript, then disables VAD and clears the indicator.

`SessionEngine.updateListenMode(_:)` propagates mode changes to a running session. The PTT hotkey handler in `AppDelegate` is the only call site for `startListening()`/`triggerPTTAnswer()`/`stopListening()`.

### Semantic question classification

When `AppSettings.semanticDetectionEnabled` is true (default), VAD-detected silence triggers `LlmQuestionClassifier.classify(_:context:)` before firing the LLM answer. The classifier sends a cheap non-streaming LLM call asking "is this text a question?" — if `isQuestion == false`, the answer is skipped. This prevents spurious LLM calls on candidate thinking pauses that the pure-VAD `QuestionDetector` can't distinguish from interviewer silence.

The classifier prompt is `prompts/classification/question.md` with `{{text}}` and `{{transcript}}` template variables. Falls back to `ContextBuilder.classification(_:transcript:)` inline prompt if the template is unavailable. On any error, returns `.assumedYes` (fire anyway) to maintain backward-compatible behavior.

### LLM integration (`LlmOrchestrator.swift`)

`LlmOrchestrator.handleQuestion(_:)` loads a provider config from `ProviderConfigStore`, fetches the API key from `KeychainStore` (falling back to env vars like `DEEPSEEK_API_KEY`), builds a prompt via `ContextBuilder`/`PromptLoader` (template with `{{variable}}` substitution from `prompts/` directory or bundle resources), and streams tokens to the overlay. Completed responses are persisted as `Suggestion` objects via `SessionEngine.persistSuggestion(_:)`.

Coding capture (`captureCodingProblem()`) uses `RegionCapture` to screenshot a screen region, then sends it as a base64 image to the LLM with a coding/system-design prompt.

### Session audio recording

When `AppSettings.audioRecordingEnabled` is true, `SessionEngine` creates an `AudioRecorder` that writes mic+system audio (mixed by the capture engine) to a WAV file at `~/Library/Application Support/SessionCopilot/audio/<sessionId>.wav`. The relative path is persisted on the `Session.audioFilePath` property. `SessionDetailView` uses `AudioPlaybackView` to replay recordings. `AudioStorage` handles directory creation, URL resolution, and cleanup (deletes orphaned files on retention enforcement).

### Session lifecycle

1. Menu bar → "Show Overlay" or `cmd+shift+o`
2. `PreflightView` checks microphone + speech recognition permissions (polls every 1s via Timer)
3. On grant → `SessionLifecycleController.startCapture()` creates `CaptureEngineImpl(captureSystemAudio: true)`, picks STT client (Apple or Deepgram based on settings), wires `SessionEngine`, and starts capture
4. `SessionEngine.startSession()` creates a `Session` via `SessionStore`, routes audio → STT, routes transcripts → overlay, and wires question detection → LLM
5. Stop (menu bar or `cmd+shift+s`) tears down capture first, then STT, marks session `.done`

`SessionLifecycleController` uses a `pendingStopTask` to prevent re-entrancy when the user rapidly toggles — if stop is still in progress when start is called, the new engine creation defers until the stop completes.

### Domain model (`Models/Models.swift`)

Key types: `AudioBuffer` (source-tagged PCM), `TranscriptSegment` (speaker-tagged, isFinal), `Session` (preflight → live → paused → done, with `audioFilePath`), `Profile` (resume + STAR stories), `Suggestion` (answer_outline / coach_tip / follow_up / code_solution), `AppSettings` (hotkeys, opacity, clickThrough, retention, listenMode, semanticDetectionEnabled, silenceThreshold, audioRecordingEnabled), `SessionMode` (behavioral / coding / systemDesign / meeting), `ProviderConfig` (deepseek / anthropic / openai / nemotron / deepgram / gemini / custom), `QuestionClassification` (isQuestion + confidence + rationale), `CaptureStatus` (idle / micOnly / systemActive / systemFallback / failed), `ChatMessage` (user/assistant with isStreaming/isInterim).

### STT clients

Three implementations of `SttClient`:

- **`AppleSttClient`** — On-device `SFSpeechRecognizer`. Works offline, no API key. Has `restartRecognition()` to create a new recognition task mid-session (called after each detected question). Rarely emits `isFinal` during continuous dictation, so `SessionEngine.persistQuestion(_:)` explicitly persists question text.
- **`DeepgramSttClient`** — Cloud STT via WebSocket. Sends PCM data over a WebSocket to Deepgram's streaming API, parses JSON transcript responses. Lazy-connects on first `sendAudio`.
- **`NemoSttClient`** — Local NVIDIA NIM endpoint. Batches audio into ~1s chunks, wraps in WAV headers, POSTs to `http://localhost:8000/v1/audio/transcriptions`.

### Prompt system

`PromptLoader` loads markdown templates from `prompts/` (copied into the bundle by the build script) or the filesystem, caches them in memory, and substitutes `{{variable}}` placeholders. `ContextBuilder` provides `buildVariables(_:chatMessages:questionText:language:)` and similar static methods to produce the variable dictionaries. The build script copies `prompts/` into `Contents/Resources/prompts/` so `Bundle.main` can find them at runtime.

Current templates: `prompts/classification/question.md`. The behavioral/coding templates are referenced by name but may not exist on disk yet — `ContextBuilder` has inline fallbacks for all modes.

### Swift 6 concurrency

The codebase uses Swift 6 strict concurrency. Patterns to follow:

- `@MainActor` on all UI-adjacent classes (`AppDelegate`, controllers, `OverlayViewModel`, `AppleSttClient`, `SessionEngine`, `LlmOrchestrator`)
- `@unchecked Sendable` for classes that bridge to non-Sendable C/Obj-C types (`CaptureEngineImpl`, SCStream delegate boxes)
- `AsyncStream` continuations for pub/sub (audio, transcripts, level meter, LLM tokens)
- `NSLock` for thread-safe property access on non-`@MainActor` classes (`QuestionDetector`, `CaptureEngineImpl` internal state)
- `nonisolated(unsafe)` for window references held across actor boundaries in `WindowController`

## TCC permissions

Three permissions needed at runtime, granted via System Settings → Privacy & Security:

| Permission | API | Purpose |
|------------|-----|---------|
| Microphone | `AVAudioEngine` input tap | Candidate speech |
| Speech Recognition | `SFSpeechRecognizer` | On-device transcription |
| Screen Recording | `SCStream` audio capture | Interviewer speech from system output |

Reset stale grants with `tccutil reset ScreenCapture`, `tccutil reset Microphone`, `tccutil reset SpeechRecognition`. Verify with `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "SELECT service, client, auth_value FROM access WHERE client = 'com.sessioncopilot.app';"` (auth_value 2 = allowed).

## Keychain & API keys

API keys for LLM providers and Deepgram STT are stored in the system Keychain via `KeychainStore` (service: `com.sessioncopilot.app`). The `ProviderConfigStore` manages provider configs (base URL, model, keychain reference). `ProviderConfig.apiKeyRef` is the keychain key — not the secret itself. Key lookup falls back to environment variables named `{PROVIDER}_API_KEY` (e.g., `DEEPSEEK_API_KEY`).

## Settings persistence

`SettingsStore` uses `@Published` with custom `Codable` serialization to `UserDefaults` (key: `com.sessioncopilot.settings`). The custom decoder tolerates missing keys for backward compatibility with older persisted settings. Settings sync is bidirectional: changes in the overlay (opacity slider, click-through toggle) write back to `SettingsStore` via Combine; changes in the Settings window propagate to the running `SessionEngine` via the `$settings` publisher → `updateListenMode`.

`SettingsStore` auto-migrates stale model names (`deepseek-chat`, `deepseek-coder` → `deepseek-v4-flash`).
