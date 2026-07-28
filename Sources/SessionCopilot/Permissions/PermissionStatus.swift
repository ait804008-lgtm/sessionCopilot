import Foundation
import AppKit
import AVFoundation
import Speech

// MARK: - Permission Kind

public enum PermissionKind: String, CaseIterable, Sendable {
    case microphone
    case screenRecording
    case accessibility
    case speechRecognition

    public var label: String {
        switch self {
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .speechRecognition: return "Speech Recognition"
        }
    }

    public var settingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .speechRecognition:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        }
    }
}

// MARK: - Permission Status

public struct PermissionStatus: Identifiable, Sendable {
    public enum State: String, Sendable {
        case notDetermined
        case granted
        case denied
    }

    public var id: String { kind.rawValue }
    public let kind: PermissionKind
    public var state: State

    public var isGranted: Bool { state == .granted }

    public init(kind: PermissionKind, state: State = .notDetermined) {
        self.kind = kind
        self.state = state
    }
}

// MARK: - Permission Checker

public struct PermissionChecker {
    /// Check current state of each permission kind.
    public static func check(_ kind: PermissionKind) -> PermissionStatus.State {
        switch kind {
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            switch status {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }

        case .screenRecording:
            // CGPreflightScreenCaptureAccess requires an app bundle with
            // NSScreenCaptureUsageDescription in Info.plist + entitlements.
            // If running as raw binary, this always returns false.
            if CGPreflightScreenCaptureAccess() {
                return .granted
            }
            // Can't distinguish denied vs notDetermined pre-prompt.
            // The system prompt only appears from a proper .app bundle.
            return .notDetermined

        case .accessibility:
            let trusted = AXIsProcessTrusted()
            // If not trusted and we haven't been prompted, it's notDetermined
            // ponytail: AXIsProcessTrusted returns false for both denied and not-yet-asked
            return trusted ? .granted : .notDetermined

        case .speechRecognition:
            let status = SFSpeechRecognizer.authorizationStatus()
            switch status {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .notDetermined
            }
        }
    }

    /// Request permission if notDetermined. Returns new state.
    public static func request(_ kind: PermissionKind) async -> PermissionStatus.State {
        switch kind {
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied

        case .screenRecording:
            // CGRequestScreenCaptureAccess shows the system prompt (macOS 14+)
            let granted = CGRequestScreenCaptureAccess()
            return granted ? .granted : .denied

        case .accessibility:
            return Self.checkAccessibility()

        case .speechRecognition:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    switch status {
                    case .authorized: cont.resume(returning: .granted)
                    case .denied, .restricted: cont.resume(returning: .denied)
                    case .notDetermined: cont.resume(returning: .notDetermined)
                    @unknown default: cont.resume(returning: .notDetermined)
                    }
                }
            }
        }
    }

    private static func checkAccessibility() -> PermissionStatus.State {
        // kAXTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt" as NSString: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        return trusted ? .granted : .denied
    }
}
