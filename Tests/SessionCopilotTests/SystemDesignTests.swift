import Foundation
import Testing
@testable import SessionCopilot

// MARK: - System Design Context Builder Tests

@Suite("ContextBuilder System Design") struct ContextBuilderSystemDesignTests {

    @Test("buildSystemDesignVariables produces all required keys")
    func producesAllKeys() {
        let vars = ContextBuilder.buildSystemDesignVariables(
            problemText: "Design a URL shortener"
        )
        #expect(vars["problem"] != nil)
    }

    @Test("buildSystemDesignVariables includes problem text")
    func includesProblem() {
        let vars = ContextBuilder.buildSystemDesignVariables(
            problemText: "Design Twitter"
        )
        #expect(vars["problem"] == "Design Twitter")
    }

    @Test("buildSystemDesignVariables + PromptLoader renders system design template")
    func buildAndRenderSystemDesignTemplate() throws {
        let vars = ContextBuilder.buildSystemDesignVariables(
            problemText: "Design a chat system"
        )
        let loader = PromptLoader()
        let rendered = try loader.loadAndRender("coding/system_design", variables: vars)

        #expect(rendered.contains("Design a chat system"))
        #expect(!rendered.contains("{{problem}}"))
    }
}

// MARK: - Session Mode Picker Tests

@Suite("Session Mode Selection") @MainActor struct SessionModeTests {

    @Test("OverlayViewModel sessionMode defaults to behavioral")
    func defaultMode() {
        let vm = OverlayViewModel()
        #expect(vm.sessionMode == .behavioral)
    }

    @Test("OverlayViewModel sessionMode can be set to coding")
    func setCodingMode() {
        let vm = OverlayViewModel()
        vm.sessionMode = .coding
        #expect(vm.sessionMode == .coding)
    }

    @Test("OverlayViewModel sessionMode can be set to systemDesign")
    func setSystemDesignMode() {
        let vm = OverlayViewModel()
        vm.sessionMode = .systemDesign
        #expect(vm.sessionMode == .systemDesign)
    }

    @Test("OverlayViewModel sessionMode can be set to meeting")
    func setMeetingMode() {
        let vm = OverlayViewModel()
        vm.sessionMode = .meeting
        #expect(vm.sessionMode == .meeting)
    }
}
