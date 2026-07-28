import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Non-MainActor types (PermissionStatus, PermissionKind, PermissionChecker)

@Suite("PermissionStatus") struct PermissionStatusTests {

    @Test("permission states have correct raw values")
    func states() {
        #expect(PermissionStatus.State.notDetermined.rawValue == "notDetermined")
        #expect(PermissionStatus.State.granted.rawValue == "granted")
        #expect(PermissionStatus.State.denied.rawValue == "denied")
    }

    @Test("permission types have all 4 kinds")
    func types() {
        #expect(PermissionKind.allCases.count == 4)
        #expect(PermissionKind.microphone.rawValue == "microphone")
        #expect(PermissionKind.screenRecording.rawValue == "screenRecording")
        #expect(PermissionKind.accessibility.rawValue == "accessibility")
    }

    @Test("PermissionStatus initializes as notDetermined")
    func defaults() {
        let status = PermissionStatus(kind: .microphone)
        #expect(status.state == .notDetermined)
        #expect(status.kind == .microphone)
    }

    @Test("PermissionStatus state transitions work")
    func stateTransitions() {
        var status = PermissionStatus(kind: .screenRecording)
        status.state = .granted
        #expect(status.state == .granted)
        #expect(status.isGranted == true)
        status.state = .denied
        #expect(status.state == .denied)
        #expect(status.isGranted == false)
    }

    @Test("PermissionKind settings URLs are valid x-apple.systempreferences")
    func settingsURLs() {
        for kind in PermissionKind.allCases {
            let url = kind.settingsURL
            #expect(url != nil, "\(kind.rawValue) should have a settings URL")
            #expect(url?.scheme == "x-apple.systempreferences")
        }
    }

    @Test("PermissionKind label is non-empty")
    func labels() {
        for kind in PermissionKind.allCases {
            #expect(!kind.label.isEmpty)
        }
    }

    @Test("PermissionChecker.check returns a valid state for each kind")
    func checkerDoesNotCrash() {
        for kind in PermissionKind.allCases {
            let state = PermissionChecker.check(kind)
            // Just checking it returns a valid state without crashing
            #expect([.notDetermined, .granted, .denied].contains(state))
        }
    }
}

// MARK: - @MainActor types (PreflightViewModel)

@Suite("PreflightViewModel") @MainActor struct PreflightViewModelTests {
    @Test("initializes with 4 permissions")
    func defaults() {
        let vm = PreflightViewModel()
        #expect(vm.permissions.count == 4)
        // State depends on actual machine permissions — can't assert exact values
    }

    @Test("allGranted reflects actual permission state")
    func allGranted() {
        let vm = PreflightViewModel()
        vm.refresh()
        // Just verify the computed property doesn't crash and is consistent
        let allG = vm.permissions.allSatisfy { $0.isGranted }
        #expect(vm.allGranted == allG)
    }
}
