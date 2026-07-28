import Foundation
import Testing
@testable import SessionCopilot

// MARK: - OverlayViewModel Network/Error State Tests

@Suite("OverlayViewModel Network & Error State") @MainActor struct OverlayViewModelStateTests {

    @Test("isStreaming starts false")
    func streamingStartsFalse() {
        let vm = OverlayViewModel()
        #expect(!vm.isStreaming)
    }

    @Test("setStreaming true activates streaming state")
    func setStreamingTrue() {
        let vm = OverlayViewModel()
        vm.setStreaming(true)
        #expect(vm.isStreaming)
    }

    @Test("setStreaming false deactivates streaming state")
    func setStreamingFalse() {
        let vm = OverlayViewModel()
        vm.setStreaming(true)
        vm.setStreaming(false)
        #expect(!vm.isStreaming)
    }

    @Test("errorMessage starts nil")
    func errorStartsNil() {
        let vm = OverlayViewModel()
        #expect(vm.errorMessage == nil)
    }

    @Test("setError sets error message")
    func setError() {
        let vm = OverlayViewModel()
        vm.setError("LLM connection failed")
        #expect(vm.errorMessage == "LLM connection failed")
    }

    @Test("clearError removes error message")
    func clearError() {
        let vm = OverlayViewModel()
        vm.setError("STT disconnected")
        vm.clearError()
        #expect(vm.errorMessage == nil)
    }

    @Test("hasError is true when error is set")
    func hasErrorTrue() {
        let vm = OverlayViewModel()
        vm.setError("Test error")
        #expect(vm.hasError)
    }

    @Test("hasError is false when no error")
    func hasErrorFalse() {
        let vm = OverlayViewModel()
        #expect(!vm.hasError)
    }
}

// MARK: - Markdown Rendering Tests

@Suite("Suggestion Markdown") struct SuggestionMarkdownTests {

    @Test("markdown text with headers produces AttributedString")
    func markdownHeaders() throws {
        let markdown = "## Outline\n- Point 1\n- Point 2"
        let attributed = try AttributedString(markdown: markdown)
        // Just verify it doesn't throw and produces non-empty result
        #expect(!attributed.characters.isEmpty)
    }

    @Test("markdown with code block produces AttributedString")
    func markdownCodeBlock() throws {
        let markdown = "## Code\n```python\nprint('hello')\n```"
        let attributed = try AttributedString(markdown: markdown)
        #expect(!attributed.characters.isEmpty)
    }

    @Test("markdown with bold produces AttributedString")
    func markdownBold() throws {
        let markdown = "**Important** text"
        let attributed = try AttributedString(markdown: markdown)
        #expect(attributed.characters.contains("Important"))
    }
}
