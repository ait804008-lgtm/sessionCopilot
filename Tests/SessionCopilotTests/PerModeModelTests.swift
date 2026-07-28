import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Per-Mode Model Selection Tests

@Suite("Per-Mode Model Selection") @MainActor struct PerModeModelTests {

    @Test("defaultModels starts empty")
    func defaultModelsEmpty() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()
        #expect(store.settings.defaultModels.isEmpty)
    }

    @Test("setting model for behavioral mode persists")
    func setBehavioralModel() {
        let store = SettingsStore()
        store.settings.defaultModels["behavioral"] = "gpt-4o"

        let store2 = SettingsStore()
        #expect(store2.settings.defaultModels["behavioral"] == "gpt-4o")
    }

    @Test("setting model for coding mode persists")
    func setCodingModel() {
        let store = SettingsStore()
        store.settings.defaultModels["coding"] = "gpt-4o"

        let store2 = SettingsStore()
        #expect(store2.settings.defaultModels["coding"] == "gpt-4o")
    }

    @Test("setting model for systemDesign mode persists")
    func setSystemDesignModel() {
        let store = SettingsStore()
        store.settings.defaultModels["system_design"] = "claude-sonnet-4-20250514"

        let store2 = SettingsStore()
        #expect(store2.settings.defaultModels["system_design"] == "claude-sonnet-4-20250514")
    }

    @Test("setting model for meeting mode persists")
    func setMeetingModel() {
        let store = SettingsStore()
        store.settings.defaultModels["meeting"] = "claude-sonnet-4-20250514"

        let store2 = SettingsStore()
        #expect(store2.settings.defaultModels["meeting"] == "claude-sonnet-4-20250514")
    }

    @Test("defaultModelKey for session mode returns correct key")
    func defaultModelKeyMapping() {
        #expect(SessionMode.behavioral.defaultModelKey == "behavioral")
        #expect(SessionMode.coding.defaultModelKey == "coding")
        #expect(SessionMode.systemDesign.defaultModelKey == "system_design")
        #expect(SessionMode.meeting.defaultModelKey == "meeting")
    }
}

// MARK: - STT Provider Selection Tests

@Suite("STT Provider Selection") @MainActor struct STTProviderSelectionTests {

    @Test("AppSettings has sttProvider field")
    func sttProviderExists() {
        let settings = AppSettings()
        #expect(settings.sttProvider != nil)
    }

    @Test("sttProvider defaults to apple")
    func sttProviderDefaultsApple() {
        let settings = AppSettings()
        #expect(settings.sttProvider == "apple")
    }

    @Test("sttProvider can be set to deepgram")
    func sttProviderSetDeepgram() {
        var settings = AppSettings()
        settings.sttProvider = "deepgram"
        #expect(settings.sttProvider == "deepgram")
    }

    @Test("sttProvider persists across instances")
    func sttProviderPersists() {
        let store = SettingsStore()
        store.settings.sttProvider = "deepgram"

        let store2 = SettingsStore()
        #expect(store2.settings.sttProvider == "deepgram")

        // Reset
        store2.settings.sttProvider = "apple"
    }
}
