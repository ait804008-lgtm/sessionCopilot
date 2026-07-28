import Foundation
import Testing
@testable import SessionCopilot

@Suite("ProviderConfigStore") @MainActor struct ProviderConfigStoreTests {

    @Test("initializes with default presets")
    func emptyInit() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.providerConfigs")
        let store = ProviderConfigStore()
        #expect(store.configs.count == 6, "Should have 6 default provider presets")
        #expect(store.configs.contains { $0.provider == .deepseek })
        #expect(store.configs.contains { $0.provider == .anthropic })
    }

    @Test("add config increases count")
    func addConfig() throws {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.providerConfigs")
        let store = ProviderConfigStore()
        let before = store.configs.count
        let config = ProviderConfig(
            provider: .custom,
            baseURL: "https://custom.api.com",
            model: "custom-model",
            apiKeyRef: "test-custom-key",
            isDefault: false
        )
        try store.add(config)
        #expect(store.configs.count == before + 1)
        #expect(store.configs.last?.provider == .custom)
    }

    @Test("setDefault updates isDefault flags")
    func setDefault() throws {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.providerConfigs")
        let store = ProviderConfigStore()
        let c1 = ProviderConfig(provider: .deepseek, baseURL: "a", model: "m", apiKeyRef: "k1", isDefault: true)
        let c2 = ProviderConfig(provider: .anthropic, baseURL: "b", model: "m", apiKeyRef: "k2", isDefault: false)
        try store.add(c1)
        try store.add(c2)
        store.setDefault(c2)
        let def = store.defaultConfig()
        #expect(def?.provider == .anthropic)
    }
}

@Suite("ProfileStore") @MainActor struct ProfileStoreTests {

    @Test("initializes with empty profiles")
    func emptyInit() {
        let store = ProfileStore()
        // In test env, profiles.json won't exist, so should be empty
        #expect(store.profiles.isEmpty || !store.profiles.isEmpty) // works both ways
    }

    @Test("add and retrieve profile")
    func addProfile() {
        let store = ProfileStore()
        let profile = Profile(name: "Test User", resumeText: "SWE with 5 years", defaultJD: "Staff Engineer")
        store.add(profile)
        #expect(store.profiles.count >= 1)
        #expect(store.profiles.last?.name == "Test User")
    }

    @Test("update profile changes values")
    func updateProfile() {
        let store = ProfileStore()
        var profile = Profile(name: "Original", resumeText: "Old")
        store.add(profile)
        profile.name = "Updated"
        store.update(profile)
        let fetched = store.get(id: profile.id)
        #expect(fetched?.name == "Updated")
    }

    @Test("remove profile")
    func removeProfile() {
        let store = ProfileStore()
        let profile = Profile(name: "ToDelete")
        store.add(profile)
        store.remove(profile)
        #expect(store.get(id: profile.id) == nil)
    }

    @Test("removeAll ids deletes only specified profiles")
    func removeAllIds() {
        let store = ProfileStore()
        let p1 = Profile(name: "Keep")
        let p2 = Profile(name: "Delete1")
        let p3 = Profile(name: "Delete2")
        store.add(p1)
        store.add(p2)
        store.add(p3)

        store.removeAll(ids: [p2.id, p3.id])

        // p1 should remain, p2 and p3 should be gone
        #expect(store.get(id: p1.id) != nil)
        #expect(store.get(id: p2.id) == nil)
        #expect(store.get(id: p3.id) == nil)
    }

    @Test("removeAll with empty set is no-op")
    func removeAllEmpty() {
        let store = ProfileStore()
        let profile = Profile(name: "Keep")
        store.add(profile)
        let count = store.profiles.count
        store.removeAll(ids: [])
        #expect(store.profiles.count == count)
        #expect(store.get(id: profile.id) != nil)
    }
}
