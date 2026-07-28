import Foundation
import os
import Testing
@testable import SessionCopilot

// MARK: - AppSettings New Fields Tests

@Suite("AppSettings New Fields") struct AppSettingsNewFieldsTests {

    @Test("semanticDetectionEnabled defaults to true")
    func defaultSemanticDetection() {
        let s = AppSettings()
        #expect(s.semanticDetectionEnabled == true)
    }

    @Test("silenceThreshold defaults to 1.5")
    func defaultSilenceThreshold() {
        let s = AppSettings()
        #expect(s.silenceThreshold == 1.5)
    }

    @Test("audioRecordingEnabled defaults to true")
    func defaultAudioRecording() {
        let s = AppSettings()
        #expect(s.audioRecordingEnabled == true)
    }

    @Test("All new fields can be set in init")
    func setInInit() {
        let s = AppSettings(
            semanticDetectionEnabled: false,
            silenceThreshold: 2.5,
            audioRecordingEnabled: false
        )
        #expect(s.semanticDetectionEnabled == false)
        #expect(s.silenceThreshold == 2.5)
        #expect(s.audioRecordingEnabled == false)
    }

    @Test("All new fields are Codable")
    func codable() throws {
        let s = AppSettings(
            semanticDetectionEnabled: false,
            silenceThreshold: 3.0,
            audioRecordingEnabled: false
        )
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.semanticDetectionEnabled == false)
        #expect(decoded.silenceThreshold == 3.0)
        #expect(decoded.audioRecordingEnabled == false)
    }

    // MARK: - Backward-compatible decoding

    @Test("Old settings JSON without new fields decodes with defaults")
    func oldJSONDecodesWithDefaults() throws {
        // Construct JSON as it would have been before the new fields
        // were added — only the original keys present.
        let json = """
        {
            "hotkeys": {
                "showHide": "cmd+shift+o",
                "startStop": "cmd+shift+s",
                "regionCapture": "cmd+shift+a",
                "copyLast": "cmd+shift+c",
                "pushToTalk": "ctrl+shift+space"
            },
            "opacity": 0.8,
            "clickThrough": false,
            "retentionDays": 30,
            "defaultModels": {},
            "exportPath": null,
            "sttProvider": "apple",
            "sttLanguage": "en",
            "listenMode": "auto"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        // New fields should default.
        #expect(decoded.semanticDetectionEnabled == true)
        #expect(decoded.silenceThreshold == 1.5)
        #expect(decoded.audioRecordingEnabled == true)
        // Original fields should be preserved.
        #expect(decoded.opacity == 0.8)
        #expect(decoded.retentionDays == 30)
        #expect(decoded.sttProvider == "apple")
    }

    @Test("Partial old JSON (some new fields present) decodes correctly") throws {
        let json = """
        {
            "opacity": 0.5,
            "semanticDetectionEnabled": false
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.opacity == 0.5)
        #expect(decoded.semanticDetectionEnabled == false)
        // Missing fields should default.
        #expect(decoded.silenceThreshold == 1.5)
        #expect(decoded.audioRecordingEnabled == true)
    }

    @Test("Empty JSON object decodes to all defaults") throws {
        let json = "{}"
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.opacity == 0.8)
        #expect(decoded.semanticDetectionEnabled == true)
        #expect(decoded.silenceThreshold == 1.5)
        #expect(decoded.audioRecordingEnabled == true)
    }
}

// MARK: - Services Container Tests

@Suite("Services Container") @MainActor struct ServicesContainerTests {

    @Test("makeDefault builds all services")
    func makeDefault() {
        let services = Services.makeDefault()
        #expect(services.viewModel != nil as OverlayViewModel?)
        #expect(services.profileStore != nil as ProfileStore?)
        #expect(services.preflightVM != nil as PreflightViewModel?)
        #expect(services.settingsStore != nil as SettingsStore?)
        #expect(services.providerStore != nil as ProviderConfigStore?)
        #expect(services.sessionStore != nil as SessionStoreImpl?)
    }

    @Test("Services can be constructed with custom instances")
    func customInit() {
        let viewModel = OverlayViewModel()
        let profileStore = ProfileStore()
        let preflightVM = PreflightViewModel(profileStore: profileStore)
        let settingsStore = SettingsStore()
        let providerStore = ProviderConfigStore()
        let sessionStore = SessionStoreImpl()
        let services = Services(
            viewModel: viewModel,
            profileStore: profileStore,
            preflightVM: preflightVM,
            settingsStore: settingsStore,
            providerStore: providerStore,
            sessionStore: sessionStore
        )
        #expect(services.viewModel === viewModel)
        #expect(services.profileStore === profileStore)
        #expect(services.preflightVM === preflightVM)
        #expect(services.settingsStore === settingsStore)
        #expect(services.providerStore === providerStore)
        #expect(services.sessionStore === sessionStore)
    }

    @Test("Services is a value type — passing copies references")
    func valueTypeSemantics() {
        let services = Services.makeDefault()
        let copy = services
        // Both should reference the same underlying instances.
        #expect(services.viewModel === copy.viewModel)
        #expect(services.settingsStore === copy.settingsStore)
    }
}

// MARK: - Log Module Tests

@Suite("Log Module") struct LogModuleTests {

    @Test("Log.subsystem is the bundle ID")
    func subsystemIsBundleID() {
        #expect(Log.subsystem == "com.sessioncopilot.app")
    }

    @Test("All log categories are accessible")
    func allCategoriesAccessible() {
        // Just verify each Logger exists and can be referenced.
        // (If any were missing, this wouldn't compile.)
        _ = Log.capture
        _ = Log.scAudio
        _ = Log.stt
        _ = Log.llm
        _ = Log.session
        _ = Log.ui
        _ = Log.hotkey
        _ = Log.settings
        _ = Log.permissions
        _ = Log.recording
        _ = Log.classifier
        _ = Log.app
    }
}
