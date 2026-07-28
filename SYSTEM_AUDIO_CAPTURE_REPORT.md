# System Audio Capture — Investigation Report (Corrected)

## Goal

Capture **system audio output** (interviewer speech from Teams/Zoom) on macOS for real-time transcription and question detection in SessionCopilot.

The app must distinguish **interviewer speech** (system audio) from **candidate speech** (microphone) to:

1. Route transcripts with correct speaker attribution (`.system` vs `.mic`)
2. Fire question-detection VAD only when the **interviewer** stops speaking

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

## The Bug

System audio capture delivers **zero audio buffers** on the development machine. The `systemDetector` never sees speech, never detects silence transitions, and `onQuestionDetected` never fires. No interviewer transcripts appear in the overlay.

## Environment

| Item | Value |
|------|-------|
| macOS | 26.5.2 (25F84) |
| Xcode | 26.5 SDK |
| Swift | 6.3.3 |
| Machine | MacBook Pro (Apple Silicon) |
| Audio device | Built-in, 48 kHz Float32 stereo |
| Execution | `swift run` from SPM project (no `.app` bundle) |

## Corrected Root Cause Analysis

The original report concluded:

> "Three fundamentally different audio capture APIs … all exhibit identical behavior on macOS 26 … This pattern strongly suggests a system-level policy change in macOS 26 that blocks programmatic system audio capture."

**This conclusion is incorrect.** Two of the three APIs attempted are architecturally incapable of capturing speaker output on any version of macOS — their failure is expected behavior, not a regression. The third (SCStream) is the correct API and is failing for an entirely different reason: **TCC permission instability caused by `swift run` execution**.

### Why AUHAL and `AudioDeviceCreateIOProcID` Cannot Work

The HAL output AudioUnit (`kAudioUnitSubType_HALOutput`) has two buses:

- **Element 0 (output scope)** — produces audio that gets played through the device.
- **Element 1 (input scope)** — pulls from the device's *recording* input stream.

Built-in speakers are an **output-only device**. They have no input stream. Enabling IO on element 1's input scope against the speakers gives the AUHAL nothing to pull from — the render callback is never scheduled because there is no IO cycle to schedule it against.

This is true on macOS 11, 12, 13, 14, 15, and 26. It is not a Darwin 26 change.

`AudioDeviceCreateIOProcID` on the default output device has the same architectural limitation. Installing an IO proc on the output scope makes you a *producer* of audio (you supply samples that get played). Installing it on the input scope is a no-op because the device has no input scope.

The only way to obtain loopback audio via these lower-level CoreAudio APIs on built-in hardware is to construct a **programmatic aggregate device with a tap sub-device** — this is what Audio Hijack and Loopback do internally. It is complex, partially undocumented, and unnecessary when `SCStream` exists.

There is also a **secondary bug in the AUHAL render callback** that would have prevented it from working even on a real input device. The callback currently reads `ioData` directly:

```swift
let rawData = Data(bytes: mData, count: byteCount)
```

For `kAudioOutputUnitProperty_SetInputCallback`, the AU does **not** pre-fill `ioData`. The contract is that the callback must call `AudioUnitRender` itself to pull audio from the input bus:

```swift
let err = AudioUnitRender(
    inUnit,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    inNumberFrames,
    ioData
)
// NOW ioData contains audio
```

Without that call, `mData` is `nil` or uninitialized.

### Why SCStream Fails Silently

`SCStream` with `capturesAudio = true` is the Apple-blessed API for system audio capture. It works on macOS 14, 15, and 26. The failure mode described in the original report (setup succeeds, no callbacks, no errors) is the documented behavior when **Screen Recording permission is denied or the executable's TCC identity is unstable**.

`swift run` causes the following problems for TCC:

1. **No Info.plist reaches the system.** The plist in `Resources/` contains `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, and `NSSpeechRecognitionUsageDescription`. None of these load when the binary runs unbundled. Without usage descriptions, TCC may silently deny without prompting.

2. **No stable bundle identifier.** TCC tracks permissions by `(bundle ID, executable CDHash, executable path)`. A `swift run` binary has no bundle ID — it's tracked purely by path + ad-hoc signature.

3. **Unstable executable path.** `.build/debug/SessionCopilot` is regenerated on every build. Even if you grant Screen Recording to it once, the next `swift build` produces a different CDHash, and TCC silently invalidates the grant.

4. **No proper code signature.** Ad-hoc signing works for some TCC categories but is fragile for Screen Recording on macOS 15+. macOS 26 tightened TCC further for processes without a stable code-signing identity.

5. **`LSUIElement` is ignored.** The plist sets it, but unbundled execution doesn't honor it. (This affects menu bar behavior, not audio capture directly.)

SCStream does **not** raise an error when permission is missing. It enters a "running" state and produces nothing. This is by design — Apple's intent is that the API surface appears to work even when the app is sandboxed or denied, to avoid leaking information about what's playing.

The CGError 1003 observed when setting `width: 128, height: 128` is the same root cause: 1003 (`kCGErrorFailure`) on SCStream typically indicates missing Screen Recording permission, not invalid dimensions. The 1×1 case is the same — 1×1 is a valid size; permission was the blocker.

## Solutions Attempted (Corrected Interpretations)

### Attempt 1: SCStream (ScreenCaptureKit) — Original Code

**API**: `SCStream` with `SCContentFilter(display:excludingWindows:[])`, `capturesAudio: true`

**Result**: `startCapture()` succeeds. Delegate callback never fires. No video frames, no audio buffers, no stream errors.

**Original interpretation**: "Root cause: SCStream's display-based audio capture pipeline silently produces nothing on macOS 26."

**Correct interpretation**: SCStream is the correct API and works on macOS 26. The silent no-op is the documented behavior when Screen Recording permission is denied or the executable's TCC identity is unstable. The most likely cause is `swift run` execution (no bundle, unstable path, no usage descriptions loaded). Retained `SCStream` instance and delegate issues may also contribute — see "Action Plan" below.

### Attempt 2: CoreAudio HAL I/O Proc (`AudioDeviceCreateIOProcID`)

**API**: `AudioDeviceCreateIOProcID` on default output device

**Result**: IO proc created, `AudioDeviceStart` returns `noErr`. IO proc callback never fires.

**Original interpretation**: "Same systemic issue — callback registered but never invoked."

**Correct interpretation**: This API cannot capture speaker output by design. The default output device has no input stream, so the IO proc on the input scope is never scheduled. The Swift 6.3 `SendNonSendable` compiler crash and the `dlsym` workaround are real issues but orthogonal — even with the workaround working correctly, no audio would be delivered.

### Attempt 3: AUHAL AudioUnit (`kAudioUnitSubType_HALOutput`)

**API**: `AudioComponentInstanceNew` with `kAudioUnitSubType_HALOutput`, `kAudioOutputUnitProperty_SetInputCallback`

**Result**: `AudioUnitInitialize` and `AudioOutputUnitStart` return `noErr`. Render callback never fires.

**Original interpretation**: "Same as above — AudioUnit initialized and started successfully, zero render callbacks."

**Correct interpretation**: Same architectural limitation as Attempt 2 — AUHAL element 1's input scope has no source on an output-only device. Additionally, the render callback is missing the mandatory `AudioUnitRender` call, so even if the callback *were* invoked, `ioData` would be empty or uninitialized.

## Key Finding (Revised)

Three capture APIs were attempted, but only one (`SCStream`) is architecturally capable of capturing system audio output. The other two (`AUHAL`, `AudioDeviceCreateIOProcID`) cannot capture speaker output on any version of macOS, regardless of OS version, permissions, or code structure.

The actual failure mode is:

> **`SCStream` requires Screen Recording permission. `swift run` produces an executable with an unstable TCC identity (no bundle ID, regenerated path on each build, ad-hoc signature). macOS 15+ silently invalidates Screen Recording grants for such executables, and SCStream's API surface returns success without producing audio when the grant is missing.**

The Swift 6.3 compiler crash in `SendNonSendable` (worked around with `dlsym`) and the CGError 1003 with small video dimensions are real but secondary issues. They are unrelated to the fundamental capture problem and should not be conflated with it.

## Transcript Format Issue (Secondary)

`AppleSttClient.sendAudio()` assumes Int16 16 kHz mono PCM. SCStream produces Float32 at the configured sample rate (recommend 48 kHz stereo to match device native). Conversion should happen via `AVAudioConverter` after the SCStream callback fires — not in SCStream's configuration. Configuring SCStream to output 16 kHz Int16 directly is unsupported.

## Action Plan

In priority order:

### 1. Bundle as a `.app`

Either move the project into Xcode, or write a small build script that assembles the bundle:

```
SessionCopilot.app/
└── Contents/
    ├── Info.plist
    ├── SessionCopilot.entitlements
    └── MacOS/
        └── SessionCopilot
```

Place the resulting `.app` in `/Applications/`. Ad-hoc sign with a stable identifier:

```bash
codesign --force --identifier com.sessioncopilot.app \
  --sign - --entitlements SessionCopilot.entitlements \
  SessionCopilot.app
```

### 2. Reset TCC

```bash
tccutil reset ScreenCapture
tccutil reset Microphone
tccutil reset SpeechRecognition
```

Inspect what's actually granted (read-only):

```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client, client_type, auth_value FROM access \
   WHERE service IN ('kTCCServiceScreenCapture','kTCCServiceMicrophone','kTCCServiceSpeechRecognition');"
```

### 3. Delete the AUHAL and `AudioDeviceCreateIOProcID` code paths

They cannot capture speaker output. Document this in the codebase so the next maintainer doesn't waste time re-attempting them. Keep `AVAudioEngine` for the mic — that's correct.

### 4. Rewrite the system audio path using SCStream

See the companion file `CaptureEngineImpl.swift` for a complete implementation. Key requirements:

- Retain the `SCStream` instance as a strong property on a long-lived object.
- Implement `SCStreamDelegate.stream(_:didStopWithError:)` for error visibility.
- Use a dedicated serial `DispatchQueue` for `sampleHandlerQueue` (not `.global()`, which is concurrent and can drop buffers under load).
- Use device-native format (48 kHz Float32 stereo) in `SCStreamConfiguration`. Convert to 16 kHz Int16 mono downstream via `AVAudioConverter`.
- Do not set `width`/`height` for audio-only capture — leave them at 0.
- Set `excludesCurrentProcessAudio = true` to avoid feedback loops.

### 5. Add Console.app / log filtering during development

```bash
log stream --predicate \
  'subsystem == "com.apple.ScreenCaptureKit" OR subsystem == "com.apple.TCC"' \
  --level debug
```

Denied entries from `com.apple.TCC` confirm permission issues.

### 6. Fallback: BlackHole

If SCStream still fails after bundling + TCC reset, install [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), create a Multi-Output Device (Speakers + BlackHole) in Audio MIDI Setup, then capture BlackHole as if it were a microphone via `AVAudioEngine`. This bypasses all TCC complexity for ScreenCapture but requires user installation and configuration.

## Remaining Options

1. **Primary**: SCStream, bundled `.app`, TCC reset, stable code signature. See `CaptureEngineImpl.swift`.
2. **Fallback**: BlackHole virtual audio driver. User-install required.
3. **Hybrid fallback**: Feed `systemDetector` from mic tap when system audio is unavailable. Correct attribution when SCStream works, graceful degradation when it doesn't. Recommend implementing this as a runtime detection (attempt SCStream; if no callbacks within 2 seconds, fall back to mic).
4. **Wait for Apple**: Only if a real OS-level regression is confirmed. File a Feedback Assistant report after verifying bundling + TCC + retained stream do not resolve the issue.
