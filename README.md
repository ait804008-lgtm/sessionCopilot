# SessionCopilot

A macOS menu-bar app that captures **microphone audio** and **system audio output** (interviewer speech from Teams/Zoom/etc.) for real-time transcription and AI-assisted interview coaching.

> **Status**: This fork fixes the system audio capture pipeline that was broken in the original investigation. The fix is documented in [`SYSTEM_AUDIO_CAPTURE_REPORT.md`](./SYSTEM_AUDIO_CAPTURE_REPORT.md) and implemented in [`Sources/SessionCopilot/Capture/CaptureEngineImpl.swift`](./Sources/SessionCopilot/Capture/CaptureEngineImpl.swift).

---

## What was broken

The original code attempted three different APIs to capture system audio:

| API | Result | Reason |
|-----|--------|--------|
| `SCStream` (ScreenCaptureKit) | Setup succeeds, no callbacks | TCC permission issue (running via `swift run` with no `.app` bundle) |
| `AudioDeviceCreateIOProcID` | Setup succeeds, no callbacks | **Architecturally impossible** — built-in speakers have no input stream |
| `AUHAL` (`kAudioUnitSubType_HALOutput`) | Setup succeeds, no callbacks | **Architecturally impossible** — same reason as above |

Two of the three were never going to work on any version of macOS. The third (SCStream) is the correct API but was failing silently due to **missing TCC permissions caused by `swift run` execution**.

## What was fixed

1. **Deleted the AUHAL and `AudioDeviceCreateIOProcID` code paths.** They cannot capture speaker output by design — built-in speakers are an output-only device. The fix is documented in the code comments.

2. **Rewrote the system audio capture path using `SCStream`** with:
   - Strong retention of `SCStream` and its delegate boxes (the original was likely getting ARC-deallocated)
   - A dedicated serial `DispatchQueue` for sample delivery (replaces `.global()` which is concurrent and can drop samples)
   - `SCStreamDelegate.stream(_:didStopWithError:)` implementation for error visibility
   - Proper `CMSampleBuffer` → `AVAudioPCMBuffer` unwrapping with interleaved/non-interleaved handling
   - `AVAudioConverter`-based downstream conversion (Float32 48kHz stereo → Int16 16kHz mono)

3. **Added a hybrid fallback.** If SCStream doesn't deliver audio within 2 seconds of starting (e.g., due to missing TCC permission), the mic tap starts feeding `systemDetector` so question detection still works — with degraded speaker attribution. This is logged to stderr as `"[DEBUG-sc] SCStream silent for 2.0s — falling back to mic for systemDetector"`.

4. **Populated `Info.plist`** with all required TCC usage descriptions (`NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSAppleEventsUsageDescription`).

5. **Populated `SessionCopilot.entitlements`** with the keys required for non-sandboxed audio capture and network access.

6. **Added `scripts/build_app_bundle.sh`** which assembles a proper `.app` bundle and ad-hoc signs it with a stable identifier. This is the critical fix — without a `.app` bundle and stable code signature, TCC permissions don't persist across rebuilds and SCStream silently fails.

7. **Lowered `swift-tools-version` from 6.3 to 6.0** for broader compatibility (6.3 is not yet widely available on stable Xcode).

8. **Raised the macOS deployment target to 14.0** (was 14.0 already, made explicit) — SCStream audio capture requires macOS 13+, `minimumNumberOfFrames` requires macOS 14+.

9. **Added comprehensive tests** covering:
   - PCM format conversion (Float32 48kHz → Int16 16kHz, silent/max-amplitude/sine-wave inputs)
   - Float buffer builder (interleaved/non-interleaved, edge cases)
   - `CaptureError` equality and wrapping
   - Hybrid fallback state
   - `QuestionDetector` extended coverage (multi-cycle detection, idempotent enable/disable, edge cases)
   - STT format invariants

---

## New Features (v0.2)

Five enhancements layered on top of the original fix:

### 1. Menu bar live status indicator

The menu bar icon is now a **colored dot** that reflects capture state in real time:

| Color | Status | Meaning |
|-------|--------|---------|
| Gray | `idle` | No session active |
| Blue | `micOnly` | Mic capture active, system audio disabled or initializing |
| Green | `systemActive` | Mic + SCStream both delivering audio (ideal state) |
| Amber | `systemFallback` | SCStream silent for 2s+, mic feeding systemDetector (check Screen Recording permission) |
| Red | `failed` | Capture pipeline error |

The status updates via `CaptureEngineImpl.onStatusChange` callbacks fired on state transitions (idle→running→failed) and on the first SCStream buffer arrival / fallback latch. Implementation: `Sources/SessionCopilot/App/Controllers/MenuBarController.swift`.

### 2. Structured logging via `os.Logger`

All `fputs(stderr, ...)` calls replaced with `os.Logger` instances organized by subsystem + category. Filter in Console.app or `log stream`:

```bash
# All SessionCopilot logs:
log stream --predicate 'subsystem == "com.sessioncopilot.app"' --level debug

# Just the SCStream audio pipeline:
log stream --predicate 'subsystem == "com.sessioncopilot.app" AND category == "sc-audio"' --level debug

# Just TCC / permission issues:
log stream --predicate 'subsystem == "com.sessioncopilot.app" AND category == "permissions"'
```

Categories: `capture`, `sc-audio`, `stt`, `llm`, `session`, `ui`, `hotkey`, `settings`, `permissions`, `recording`, `classifier`, `app`. Implementation: `Sources/SessionCopilot/Logging/Log.swift`.

### 3. Semantic question detection via LLM

Pure-VAD question detection (silence threshold) fires on any pause — including the candidate's own thinking pauses. The new semantic gate asks the LLM to confirm the candidate text is actually a question before generating an answer.

**Flow**: VAD silence detected → `LlmQuestionClassifier.classify(text, context:)` → if `isQuestion == true`, fire LLM answer; otherwise skip silently.

**Tunable in Settings → General**:
- **Semantic Question Detection** toggle (default: on)
- **Silence Threshold** slider (0.5s–5.0s, default: 1.5s)

**Graceful degradation**: If the classifier can't be constructed (no API key) or the LLM call fails, returns `.assumedYes` so the LLM answer fires anyway — preserves pre-feature behavior.

**Future**: A `QuestionClassifier` protocol is defined (`Sources/SessionCopilot/Protocols/Protocols.swift`) so a local on-device model (e.g., MiniLM) can replace the LLM call without changing call sites.

Implementation:
- `Sources/SessionCopilot/LLM/LlmQuestionClassifier.swift` — LLM-backed classifier
- `Sources/SessionCopilot/Models/Models.swift` — `QuestionClassification` struct
- `prompts/classification/question.md` — classification prompt template
- `Sources/SessionCopilot/LLM/ContextBuilder.swift` — `classification(text:transcript:)` builder

### 4. Audio replay storage (WAV per session)

Each session's audio (mic + system, interleaved by arrival) is recorded to a WAV file at `~/Library/Application Support/SessionCopilot/audio/<session-uuid>.wav`. The file is written incrementally — each `append(_:)` call updates the WAV header in-place, so the file is always valid even if the app crashes mid-session.

**Format**: 16kHz Int16 mono PCM (matches STT input format). ~10 MB per 30-min session.

**Settings → General → Audio Recording** toggle (default: on).

**Playback**: Open **Session History** → select a session → the detail view shows an `AudioPlaybackView` with play/pause and a timeline slider.

**Cleanup**: Audio files are deleted when their session is deleted (`SessionStoreImpl.deleteSession`, `deleteSessions`, `deleteAllSessions`, `deleteSessionsOlderThan`). Orphaned audio files (no session in the store) are cleaned up by retention.

Implementation:
- `Sources/SessionCopilot/Audio/AudioRecorder.swift` — WAV writer with in-place header updates
- `Sources/SessionCopilot/Audio/AudioStorage.swift` — path resolution + cleanup
- `Sources/SessionCopilot/Session/AudioPlaybackView.swift` — SwiftUI playback UI
- `Sources/SessionCopilot/Engine/SessionEngine.swift` — recording task wired into `startSession`/`stopSession`

### 5. AppDelegate split + Services container

The original `AppDelegate` was 685 lines owning everything (menu bar, hotkeys, overlay, session lifecycle, LLM orchestration, settings sync, retention). Split into:

| Controller | Responsibility | Lines |
|------------|----------------|-------|
| `MenuBarController` | Status item + menu, status dot rendering | ~170 |
| `HotkeyController` | Global / local hotkey registration | ~90 |
| `WindowController` | Preflight, settings, history, responsible-use, overlay panel | ~160 |
| `SessionLifecycleController` | Capture→STT→overlay pipeline lifecycle | ~140 |
| `LlmOrchestrator` | Question handling, coding capture, classification | ~310 |

`AppDelegate` is now a thin ~190-line composition root that wires the controllers together and routes menu/hotkey actions via delegate protocols.

A `Services` struct bundles the shared stores (`viewModel`, `settingsStore`, `providerStore`, `sessionStore`, `profileStore`, `preflightVM`) so controllers receive dependencies via init rather than reaching into `AppDelegate`.

Implementation: `Sources/SessionCopilot/App/Controllers/*.swift` + `Sources/SessionCopilot/App/Services.swift`.

---

## Requirements

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| macOS | 14.0 (Sonoma) | 15.0+ (Sequoia) or 26 (Tahoe) |
| Xcode | 16.0 | 16.5+ |
| Swift toolchain | 6.0 | 6.0+ |
| Architecture | Apple Silicon | Apple Silicon |

SCStream audio capture is supported on macOS 13+. The `minimumNumberOfFrames` property used in the configuration requires macOS 14+.

---

## How to build and run

### Option A: Use the build script (recommended)

```bash
cd SessionCopilot

# Build release, assemble .app bundle, ad-hoc sign
./scripts/build_app_bundle.sh

# Optional: also install to /Applications/
./scripts/build_app_bundle.sh --install

# Or build debug configuration
./scripts/build_app_bundle.sh --debug
```

The script:
1. Runs `swift build` (release or debug)
2. Assembles `SessionCopilot.app/Contents/{MacOS,Resources}/`
3. Copies `Info.plist` and `SessionCopilot.entitlements` into the bundle
4. Ad-hoc signs with `codesign --identifier com.sessioncopilot.app --sign - --options runtime`
5. Verifies the signature

The staged bundle is at `.build/app-stage/SessionCopilot.app`. With `--install`, it's copied to `/Applications/SessionCopilot.app`.

### Option B: Open in Xcode

```bash
cd SessionCopilot
open Package.swift
```

Xcode will recognize the Swift Package. Set the run destination to "My Mac" and press ⌘R. Xcode will handle bundling and signing automatically.

> **Note**: If you run via `swift run` directly (without bundling), **SCStream will silently fail to deliver audio buffers**. This is the core issue that the build script fixes. Always run from a `.app` bundle.

---

## First-launch TCC setup

On first launch, macOS will prompt for three permissions. Approve all three:

1. **Microphone** — for AVAudioEngine input tap
2. **Speech Recognition** — for SFSpeechRecognizer
3. **Screen Recording** — for SCStream audio capture (this is the one that was silently failing before)

For Screen Recording:
- The prompt appears on first SCStream start
- If denied or missed, open **System Settings → Privacy & Security → Screen Recording** and enable **SessionCopilot**
- You may need to restart the app after toggling

### If permissions are stale or corrupted

If you previously ran via `swift run` and granted permission to the wrong binary identity, reset TCC:

```bash
tccutil reset ScreenCapture
tccutil reset Microphone
tccutil reset SpeechRecognition
```

Then relaunch SessionCopilot and re-grant.

### Verifying permissions are granted

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, auth_value FROM access \
   WHERE service IN ('kTCCServiceScreenCapture','kTCCServiceMicrophone','kTCCServiceSpeechRecognition') \
   AND client = 'com.sessioncopilot.app';"
```

`auth_value = 2` means "allowed". If you see no rows for `com.sessioncopilot.app`, the permission was never granted to the bundled identity.

---

## Verifying system audio capture works

After launching, start a session (menu bar → "Show Overlay" or ⌘⇧O). Then in a terminal:

```bash
# Watch for SCStream debug logs
log stream --predicate \
  'process == "SessionCopilot"' \
  --level debug | grep DEBUG-sc
```

You should see, in order:

1. `[DEBUG-sc] SCStream started (display: ...)` — SCStream initialized successfully
2. `[DEBUG-sc] Converter built: 48000.0Hz 2ch → 16kHz mono Int16` — first audio sample arrived, converter built
3. (No further logs unless `[DEBUG-sc] AU render fired #N` is uncommented — but `scBufferCount` will increment)

If you see only step 1 and then, after 2 seconds:
```
[DEBUG-sc] SCStream silent for 2.0s — falling back to mic for systemDetector
```

That means SCStream is not delivering audio — usually a TCC issue. Reset TCC and re-launch from the `.app` bundle.

To test system audio is actually being captured: play any audio (YouTube, Spotify, a Zoom call) and check that the overlay's speech indicator responds to **system audio** (not just mic).

---

## Running tests

```bash
cd SessionCopilot
swift test
```

Tests run on macOS only — several depend on `AVFoundation` / `AVAudioConverter` / `AVAudioFormat` which are not available on Linux.

### Test coverage

| Suite | What it covers |
|-------|----------------|
| `AudioBuffer Source` | Source tagging (mic/system/unknown), Codable round-trip |
| `RMS Edge Cases` | Single-sample, odd byte counts, alternating +/- samples |
| `PCM Conversion` | Float32 48kHz → Int16 16kHz conversion: silent, max-amplitude, sine wave, downsample ratio |
| `Float Buffer Builder` | Interleaved/non-interleaved buffer construction |
| `CaptureError` | Equality, wrapping arbitrary errors, passthrough of existing CaptureError |
| `Hybrid Fallback` | Initial state, fallback flag, timeout configuration |
| `CaptureEngine State` | Mock engine, stream exposure, speaking state, VAD toggle |
| `STT Format` | 16kHz Int16 mono invariant, bytesPerFrame |
| `QuestionDetector Extended` | Multi-cycle detection, idempotent enable/disable, edge cases (zero/negative deltaTime, negative level) |
| `CaptureEngine` | Mock protocol conformance, start/stop |
| `E2E-04: Capture → AudioBuffer Source → STT Pipeline` | End-to-end mic-only capture |

---

## Project layout

```
SessionCopilot/
├── Package.swift                       # SwiftPM manifest (macOS 14+, Swift 6)
├── Resources/
│   ├── Info.plist                      # TCC usage descriptions, bundle ID, LSUIElement
│   └── SessionCopilot.entitlements     # Audio input, speech recognition, network, files
├── scripts/
│   └── build_app_bundle.sh             # Assembles .app + ad-hoc signs
├── Sources/SessionCopilot/
│   ├── App/App.swift                   # AppDelegate, menu bar, hotkeys, lifecycle
│   ├── Capture/
│   │   ├── CaptureEngineImpl.swift     # ← REWRITTEN: SCStream + hybrid fallback
│   │   ├── QuestionDetector.swift      # VAD with silence threshold
│   │   └── RegionCapture.swift         # Screen region capture for coding assist
│   ├── Engine/SessionEngine.swift      # Orchestrates capture → STT → overlay
│   ├── STT/
│   │   ├── AppleSttClient.swift        # On-device SFSpeechRecognizer
│   │   └── SttClients.swift            # Deepgram STT client
│   ├── Overlay/                        # Floating overlay UI
│   ├── Permissions/                    # Preflight permission checks
│   ├── LLM/                            # LLM client, prompt templates
│   ├── Profile/                        # Resume / profile management
│   ├── Session/                        # Session history, export
│   ├── Settings/                       # Settings UI and store
│   ├── Storage/                        # SessionStore implementation
│   ├── Providers/                      # LLM provider config
│   ├── Keychain/                       # API key storage
│   ├── Onboarding/                     # Responsible-use notice
│   ├── Models/Models.swift             # Domain types
│   └── Protocols/Protocols.swift       # CaptureEngine, SttClient, etc.
├── Tests/SessionCopilotTests/
│   ├── SystemAudioTests.swift          # ← EXPANDED: PCM conversion, fallback, errors
│   ├── CaptureEngineTests.swift        # ← EXPANDED: QuestionDetector edge cases
│   └── ... (other existing test suites)
├── SYSTEM_AUDIO_CAPTURE_REPORT.md      # Root-cause analysis
└── README.md                           # This file
```

---

## Troubleshooting

### "SCStream started" but no audio buffers

1. Confirm you're running from a `.app` bundle, not `swift run`:
   ```bash
   ps -p $(pgrep SessionCopilot) -o comm=
   # Should print: /Applications/SessionCopilot.app/Contents/MacOS/SessionCopilot
   # NOT: .build/debug/SessionCopilot
   ```

2. Reset TCC and re-grant:
   ```bash
   tccutil reset ScreenCapture
   # Then re-launch SessionCopilot and approve the prompt
   ```

3. Verify the permission was actually granted to the bundle ID:
   ```bash
   sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
     "SELECT * FROM access WHERE client = 'com.sessioncopilot.app';"
   ```

4. Check Console.app for TCC denials:
   ```bash
   log stream --predicate 'subsystem == "com.apple.TCC"' --level debug
   ```

### "Converter built" log appears but no transcripts

This means SCStream is delivering audio, but `AppleSttClient` isn't transcribing it. Check:
- The `audioStream` AsyncStream is being consumed (look for `for await buffer in self.captureEngine.audioStream` in `SessionEngine.swift`)
- The `sttClient.sendAudio(buffer.data)` call is receiving non-empty data
- SFSpeechRecognizer is available for the configured locale

### App crashes on launch

Most likely cause: missing entitlements or invalid Info.plist. Verify:
```bash
codesign --verify --verbose=2 /Applications/SessionCopilot.app
plutil -lint /Applications/SessionCopilot.app/Contents/Info.plist
```

### "CGError 1003" when starting SCStream

This error typically indicates **missing Screen Recording permission**, not invalid stream configuration. Reset TCC and re-grant (see above). The original report mentioned trying small video dimensions (1×1, 128×128) and seeing this error — that was a red herring. Audio-only SCStream (no width/height set) is correct.

### Falling back to mic permanently

If you consistently see the fallback message in logs, SCStream is failing on your machine. Possible causes:
- TCC permission not granted (most common)
- App not running from a `.app` bundle
- Running on macOS < 14.0 (SCStream audio requires 13+, `minimumNumberOfFrames` requires 14+)
- Display sleeping / no audio playing through speakers (try playing audio while testing)

If none of these resolve it, install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) and capture it as a microphone via `AVAudioEngine` — bypasses SCStream entirely.

---

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌──────────┐
│ System Audio    │────▶│ audioStream   │────▶│ STT      │──▶ overlay
│ (SCStream)      │     │ (AsyncStream) │     │ (16k Int16)
└─────────────────┘     └──────────────┘     └──────────┘
                                ▲
┌─────────────────┐             │
│ Mic Audio       │─────────────┘
│ (AVAudioEngine) │
└─────────────────┘

┌─────────────────┐
│ systemDetector  │──▶ onQuestionDetected ▶ LLM
│ (VAD, 1.5s)     │
└─────────────────┘
┌─────────────────┐
│ micDetector     │──▶ isMicSpeaking (attribution only)
│ (VAD)           │
└─────────────────┘
```

- **Mic audio** is captured via `AVAudioEngine` input tap, converted to 16kHz Int16 mono, and fed to `micDetector` (for speaker attribution) and the STT pipeline.
- **System audio** is captured via `SCStream` with `capturesAudio = true`, received as `CMSampleBuffer` (Float32 48kHz stereo), converted to 16kHz Int16 mono via `AVAudioConverter`, and fed to `systemDetector` (for question detection) and the STT pipeline.
- **Hybrid fallback**: If SCStream delivers no audio within 2 seconds, the mic tap also starts feeding `systemDetector` so question detection continues to work (with degraded speaker attribution).
- **Question detection**: `systemDetector` fires `onQuestionDetected` after 1.5s of silence following detected speech. This triggers LLM answer generation.
- **Speaker attribution**: `SessionEngine.resolveSpeaker()` checks `isSystemSpeaking` (interviewer) vs `isMicSpeaking` (candidate) to tag each transcript segment.

---

## License

See the original project for licensing. This fork is a bug-fix investigation.
