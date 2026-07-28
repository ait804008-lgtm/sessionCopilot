import Foundation
import Testing
@testable import SessionCopilot

@Suite("OverlayViewModel") @MainActor struct OverlayViewModelTests {

    @Test("initializes with default values")
    func defaults() {
        let vm = OverlayViewModel()
        #expect(vm.opacity == 0.8)
        #expect(vm.clickThrough == false)
        #expect(vm.isVisible == false)
        #expect(vm.isLive == false)
    }

    @Test("opacity clamps to valid range")
    func opacityClamp() {
        let vm = OverlayViewModel()
        vm.opacity = 1.5
        #expect(vm.opacity == 1.0)
        vm.opacity = -0.5
        #expect(vm.opacity == 0.1)
        vm.opacity = 0.3
        #expect(vm.opacity == 0.3)
    }

    @Test("clickThrough toggles")
    func clickThroughToggle() {
        let vm = OverlayViewModel()
        #expect(vm.clickThrough == false)
        vm.clickThrough = true
        #expect(vm.clickThrough == true)
    }

    @Test("show/hide toggles isVisible")
    func showHide() {
        let vm = OverlayViewModel()
        vm.show()
        #expect(vm.isVisible == true)
        vm.hide()
        #expect(vm.isVisible == false)
    }

    @Test("toggle alternates")
    func toggle() {
        let vm = OverlayViewModel()
        vm.toggle()
        #expect(vm.isVisible == true)
        vm.toggle()
        #expect(vm.isVisible == false)
    }

    @Test("goLive/endSession transitions")
    func liveState() {
        let vm = OverlayViewModel()
        #expect(vm.isLive == false)
        vm.goLive()
        #expect(vm.isLive == true)
        vm.endSession()
        #expect(vm.isLive == false)
    }

    @Test("appendTranscript adds user chat message")
    func transcript() {
        let vm = OverlayViewModel()
        let segment = TranscriptSegment(
            id: UUID(), sessionId: UUID(), timestamp: Date(),
            speaker: .mic, text: "Hello", isFinal: true
        )
        vm.appendTranscript(segment)
        #expect(vm.chatMessages.count == 1)
        #expect(vm.chatMessages.first?.role == .user)
        #expect(vm.chatMessages.first?.text == "Hello")
    }

    @Test("assistant response lifecycle")
    func assistantResponse() {
        let vm = OverlayViewModel()
        #expect(vm.chatMessages.isEmpty)
        vm.startAssistantResponse()
        #expect(vm.chatMessages.count == 1)
        #expect(vm.chatMessages.first?.role == .assistant)
        #expect(vm.chatMessages.first?.isStreaming == true)
        vm.updateAssistantResponse("## Outline\n- Point 1")
        #expect(vm.chatMessages.first?.text.contains("Outline") == true)
        vm.finalizeAssistantResponse()
        #expect(vm.chatMessages.first?.isStreaming == false)
        #expect(vm.lastAssistantResponse.contains("Outline") == true)
        vm.clearChat()
        #expect(vm.chatMessages.isEmpty)
    }
}
