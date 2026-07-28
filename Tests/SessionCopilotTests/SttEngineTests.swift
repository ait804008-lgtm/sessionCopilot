import Foundation
import Testing
@testable import SessionCopilot

@Suite("SttClient") @MainActor struct SttClientTests {

    @Test("DeepgramSttClient conforms to SttClient")
    func deepgramConforms() {
        let client = DeepgramSttClient()
        #expect(client is SttClient)
    }

    @Test("NemoSttClient conforms to SttClient")
    func nemoConforms() {
        let client = NemoSttClient()
        #expect(client is SttClient)
    }

    @Test("SttConfig with deepgram provider encodes correctly")
    func deepgramConfig() async throws {
        let config = SttConfig(provider: .deepgram, model: "nova-3", language: "en")
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SttConfig.self, from: encoded)
        #expect(decoded.provider == .deepgram)
        #expect(decoded.model == "nova-3")
    }

    @Test("SttConfig with nemo provider encodes correctly")
    func nemoConfig() async throws {
        let config = SttConfig(provider: .nemo, model: "nemotron-stt-3.5", language: "en")
        #expect(config.provider == .nemo)
    }
}

@Suite("SessionEngine") @MainActor struct SessionEngineTests {

    @Test("SessionEngine initializes with all components")
    func initialization() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)
        #expect(engine.captureEngine is MockCaptureEngine)
        #expect(engine.sttClient is DeepgramSttClient)
    }

    @Test("SessionEngine start/stop transitions view model live state")
    func startStopTransitions() async throws {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)

        try await stt.configure(SttConfig(provider: .deepgram, model: "nova-3"))
        #expect(vm.isLive == false)
        try await engine.startSession()
        #expect(vm.isLive == true)
        try await engine.stopSession()
        #expect(vm.isLive == false)
    }
}
