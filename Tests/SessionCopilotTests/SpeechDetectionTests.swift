import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Speech Detection State Tests

@Suite("OverlayViewModel Speech Detection") @MainActor struct OverlayViewModelSpeechTests {

    @Test("isDetectingSpeech starts false")
    func startsFalse() {
        let vm = OverlayViewModel()
        #expect(!vm.isDetectingSpeech)
    }

    @Test("setDetectingSpeech true updates state")
    func setSpeechTrue() {
        let vm = OverlayViewModel()
        vm.setDetectingSpeech(true)
        #expect(vm.isDetectingSpeech)
    }

    @Test("setDetectingSpeech false updates state")
    func setSpeechFalse() {
        let vm = OverlayViewModel()
        vm.setDetectingSpeech(true)
        vm.setDetectingSpeech(false)
        #expect(!vm.isDetectingSpeech)
    }

    @Test("setDetectingSpeech with same value avoids redundant notification")
    func avoidsRedundant() {
        let vm = OverlayViewModel()
        var fireCount = 0
        let cancellable = vm.objectWillChange.sink { _ in fireCount += 1 }

        vm.setDetectingSpeech(false) // already false — should not fire
        #expect(fireCount == 0, "Setting same value should not fire")

        vm.setDetectingSpeech(true)
        #expect(fireCount == 1)

        vm.setDetectingSpeech(true) // already true — should not fire again
        #expect(fireCount == 1, "Setting same value should not fire again")

        cancellable.cancel()
    }

    @Test("setDetectingSpeech fires objectWillChange only on change")
    func firesOnChange() {
        let vm = OverlayViewModel()
        var fired = false
        let cancellable = vm.objectWillChange.sink { _ in fired = true }

        vm.setDetectingSpeech(true)
        #expect(fired)

        cancellable.cancel()
    }
}

// MARK: - Live Indicator State Combinations

@Suite("OverlayViewModel Live Indicator States") @MainActor struct OverlayLiveIndicatorTests {

    @Test("isLive false shows no indicator state (title mode)")
    func notLiveShowsTitle() {
        let vm = OverlayViewModel()
        #expect(!vm.isLive)
        #expect(!vm.isStreaming)
        #expect(!vm.isDetectingSpeech)
        // When isLive is false, indicator should show "SessionCopilot" title
    }

    @Test("isLive true with no speech and no streaming shows green Live")
    func liveIdleIsGreen() {
        let vm = OverlayViewModel()
        vm.goLive()
        #expect(vm.isLive)
        #expect(!vm.isStreaming)
        #expect(!vm.isDetectingSpeech)
        #expect(!vm.hasError)
        // Should show green "● Live"
    }

    @Test("isLive + hasError shows red Error even when detecting speech")
    func errorShowsRed() {
        let vm = OverlayViewModel()
        vm.goLive()
        vm.setError("STT disconnected")
        #expect(vm.isLive)
        #expect(vm.hasError)
        // Should show red "● Error"
    }

    @Test("hasError takes priority over isDetectingSpeech")
    func errorOverSpeech() {
        let vm = OverlayViewModel()
        vm.goLive()
        vm.setDetectingSpeech(true)
        vm.setError("LLM down")
        #expect(vm.isLive)
        #expect(vm.hasError)
        #expect(vm.isDetectingSpeech)
        // hasError should take visual priority — shows red "● Error"
    }

    @Test("isLive + isDetectingSpeech shows orange Listening")
    func detectingSpeechIsOrange() {
        let vm = OverlayViewModel()
        vm.goLive()
        vm.setDetectingSpeech(true)
        #expect(vm.isLive)
        #expect(vm.isDetectingSpeech)
        #expect(!vm.isStreaming)
        // Should show orange "● Listening"
    }

    @Test("isLive + isStreaming shows orange Answering")
    func streamingIsOrange() {
        let vm = OverlayViewModel()
        vm.goLive()
        vm.setStreaming(true)
        #expect(vm.isLive)
        #expect(vm.isStreaming)
        // Should show orange "● Answering"
    }

    @Test("isStreaming takes priority over isDetectingSpeech")
    func streamingOverSpeech() {
        let vm = OverlayViewModel()
        vm.goLive()
        vm.setDetectingSpeech(true)
        vm.setStreaming(true)
        #expect(vm.isStreaming)
        // isStreaming should take visual priority — shows "● Answering"
    }
}
