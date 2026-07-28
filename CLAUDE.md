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

# Run all tests
swift test

# Open in Xcode
open Package.swift
```

The build script assembles `SessionCopilot.app/Contents/{MacOS,Resources}/`, copies `Info.plist` and entitlements from `Resources/`, and ad-hoc signs with identifier `com.sessioncopilot.app`. Bundle ID must match Info.plist's `CFBundleIdentifier` for TCC grants to be stable.

Tests use the **Swift Testing** framework (`@Suite`, `@Test`, `#expect`), not XCTest. Tests depend on `AVFoundation`/`AVAudioConverter` — they only run on macOS.

## Architecture

### Core protocol layer (`Protocols/Protocols.swift`)

Four protocols define the app's seams — everything else is implementation:

- **`CaptureEngine`** — `AsyncStream<AudioBuffer>` for audio, `AsyncStream<Float>` for level meter, VAD control (`enableVAD`/`disableVAD`/`resetSilence`), `isSystemSpeaking`/`isMicSpeaking` flags. Implemented by `CaptureEngineImpl` and `MockCaptureEngine` (for testing).
- **`SttClient`** — `AsyncStream<TranscriptSegment>` for transcripts, `configure`/`start`/`stop`/`sendAudio`. Implemented by `AppleSttClient` (on-device) and `DeepgramSttClient` (cloud).
- **`LlmClient`** — `streamCompletion` returns `AsyncStream<LlmToken>`, `complete` returns `LlmResponse`. Implemented by `LlmClientImpl`.
- **`SessionStore`** — CRUD for `Session`/`TranscriptSegment`/`Suggestion` + export. Implemented by `SessionStoreImpl`.

### Data flow

```
Mic (AVAudioEngine) ──┐
                       ├──▶ audioStream (AsyncStream<AudioBuffer>, 16kHz Int16 mono)
System Audio (SCStream)┘       │
                                ├──▶ SttClient.sendAudio() → transcriptStream
                                │         │
                                │         └──▶ OverlayViewModel.appendTranscript()
                                │                    │
                                │                    └──▶ SessionEngine.resolveSpeaker()
                                │                         (system-active → .system, mic-active → .mic)
                                │
                                ├──▶ systemDetector (VAD, 1.5s silence → onQuestionDetected)
                                │         │
                                │         └──▶ LLM streaming → overlay chat
                                │
                                └──▶ micDetector (VAD → isMicSpeaking — attribution only, never fires LLM)
```

### SCStream audio capture (`CaptureEngineImpl.swift`)

The system audio path uses `SCStream` with `capturesAudio = true`, receiving `CMSampleBuffer` (Float32 48kHz stereo). A lazily-built `AVAudioConverter` converts to 16kHz Int16 mono on a dedicated **serial** `DispatchQueue` (`.global()` is concurrent and can drop/reorder samples). Important details:

- **Delegate boxes** (`SCStreamDelegateBox`, `SCAudioOutputBox`) are strongly retained by `CaptureEngineImpl` — `SCStream.delegate` is weak and `addStreamOutput` doesn't retain, so without strong references ARC deallocates them mid-stream.
- **`minimumNumberOfFrames = 1`** is gated behind `#available(macOS 15.0, *)`. On macOS 14 the default minimum is higher, adding a few hundred ms of delay to the first callback.
- **Hybrid fallback**: If `scBufferCount` is still 0 after `systemAudioFallbackSeconds` (default 2.0s), the mic tap starts feeding `systemDetector` so question detection works — with degraded speaker attribution (both sides tagged as mic). The `didFallbackToMic` flag latches true.
- **Format conversion** (`convertPCM`, `makeFloatBuffer`, `computeRMS`) are `internal static` — intentionally testable without instantiating the full engine.

### Listen modes

Two modes, toggled via `SettingsStore.settings.listenMode`:

- **`"auto"`** — VAD is always on. `systemDetector` detects 1.5s of silence after speech, fires `onQuestionDetected`, then STT is restarted.
- **`"pushToTalk"`** — VAD is off by default. User holds `ctrl+shift+space` (configurable) to enable listening. Audio only flows to STT while the key is held. Key-up triggers question detection with the accumulated transcript, then disables VAD and clears the indicator.

`SessionEngine.updateListenMode(_:)` propagates mode changes to a running session. The PTT hotkey handler in `AppDelegate` is the only call site for `startListening()`/`triggerPTTAnswer()`/`stopListening()`.

### Session lifecycle

`AppDelegate` is the coordinator. Flow:

1. Menu bar → "Show Overlay" or `cmd+shift+o`
2. `PreflightView` checks microphone + speech recognition permissions (polls every 1s)
3. On grant → `goLive()` creates `CaptureEngineImpl`, picks STT client (Apple or Deepgram based on settings), wires `SessionEngine`, and starts capture
4. `SessionEngine.startSession()` creates a `Session` via `SessionStore`, routes audio → STT, routes transcripts → overlay, and wires question detection → LLM
5. Stop (menu bar or `cmd+shift+s`) tears down capture first, then STT, marks session `.done`

### LLM integration (`App.swift:252-358`)

`handleQuestion(_:)` loads a provider config from `ProviderConfigStore`, fetches the API key from `KeychainStore` (falling back to env vars like `DEEPSEEK_API_KEY`), builds a prompt via `ContextBuilder`/`PromptLoader` (template with `{{variable}}` substitution from `prompts/` directory or bundle resources), and streams tokens to the overlay. Completed responses are persisted as `Suggestion` objects.

### Domain model (`Models/Models.swift`)

Key types: `AudioBuffer` (source-tagged PCM), `TranscriptSegment` (speaker-tagged, isFinal), `Session` (preflight → live → paused → done), `Profile` (resume + STAR stories), `Suggestion` (answer_outline / coach_tip / follow_up / code_solution), `AppSettings` (hotkeys, opacity, clickThrough, retention, listenMode), `SessionMode` (behavioral / coding / systemDesign / meeting), `ProviderConfig` (deepseek / anthropic / openai / nemotron / deepgram / gemini / custom).

### Swift 6 concurrency

The codebase uses Swift 6 strict concurrency. Patterns to follow:

- `@MainActor` on all UI-adjacent classes (`AppDelegate`, `OverlayViewModel`, `AppleSttClient`, `SessionEngine`)
- `@unchecked Sendable` for classes that bridge to non-Sendable C/Obj-C types (`CaptureEngineImpl`, SCStream delegate boxes)
- `AsyncStream` continuations for pub/sub (audio, transcripts, level meter, LLM tokens)
- `NSLock` for thread-safe property access on non-`@MainActor` classes
- `nonisolated(unsafe)` for window references held across actor boundaries in `AppDelegate`

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

`SettingsStore` uses `@Published` with custom `Codable` serialization to `UserDefaults`. Settings sync is bidirectional: changes in the overlay (opacity slider, click-through toggle) write back to `SettingsStore` via Combine; changes in the Settings window propagate to the running `SessionEngine` via `$settings` publisher.
