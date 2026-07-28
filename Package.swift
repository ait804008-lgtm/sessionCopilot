// swift-tools-version: 6.0
//
// SessionCopilot — Swift Package manifest.
//
// Notes:
// - swift-tools-version pinned to 6.0 (was 6.3). The 6.3 tools-version
//   is not yet widely available on stable Xcode releases. 6.0 is the
//   minimum that supports Swift 6 language mode and is available in
//   Xcode 16+. The codebase still compiles in Swift 6 language mode.
// - macOS deployment target set to 14.0. SCStream audio capture
//   (`SCStreamConfiguration.capturesAudio`, `sampleRate`, `channelCount`,
//   `queueDepth`) requires macOS 13+. Raising to 14.0 simplifies
//   availability checks and matches what the code actually uses.
// - System frameworks (ScreenCaptureKit, AVFoundation, CoreMedia,
//   AudioToolbox, CoreAudio, AppKit, SwiftUI, Speech, PDFKit) are
//   auto-linked by SwiftPM on Apple platforms. No explicit linker
//   settings are required.
// - Info.plist and entitlements are NOT SPM resources. They live at
//   `Resources/` at the package root and are assembled into the final
//   `.app` by `scripts/build_app_bundle.sh`. SPM does not support
//   bundling arbitrary files into executables without a wrapper, so
//   the build script handles it directly.

import PackageDescription

let package = Package(
    name: "SessionCopilot",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SessionCopilot"
        ),
        .testTarget(
            name: "SessionCopilotTests",
            dependencies: ["SessionCopilot"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
