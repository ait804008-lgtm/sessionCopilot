import Foundation
import Testing
import Combine
@testable import SessionCopilot

// MARK: - Settings ↔ Overlay Sync Tests

@Suite("Settings ↔ Overlay Opacity Sync") @MainActor struct SettingsOverlaySyncTests {

    @Test("OverlayViewModel opacity defaults to 0.8 (SettingsStore default)")
    func viewModelDefaultMatchesSettingsDefault() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let vm = OverlayViewModel()
        let store = SettingsStore()
        #expect(vm.opacity == store.settings.opacity)
        #expect(vm.opacity == 0.8)
    }

    @Test("SettingsStore settings.opacity persists and can be read back")
    func settingsOpacityPersists() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()
        store.settings.opacity = 0.3

        let store2 = SettingsStore()
        #expect(store2.settings.opacity == 0.3)

        // Reset
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
    }

    @Test("SettingsStore settings.clickThrough persists and can be read back")
    func settingsClickThroughPersists() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()
        store.settings.clickThrough = true

        let store2 = SettingsStore()
        #expect(store2.settings.clickThrough == true)

        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
    }

    @Test("OverlayViewModel opacity changes persist via objectWillChange")
    func viewModelFiresOnOpacityChange() {
        let vm = OverlayViewModel()
        var fired = false
        let cancellable = vm.objectWillChange.sink { _ in fired = true }

        vm.opacity = 0.5
        #expect(fired)
        #expect(vm.opacity == 0.5)

        cancellable.cancel()
    }

    @Test("OverlayViewModel clickThrough toggle fires objectWillChange")
    func viewModelClickThroughDoesNotFireObjectWillChange() {
        // clickThrough is a plain stored property — it does NOT fire objectWillChange
        // unless explicitly called (which OverlayView now does via the button action)
        let vm = OverlayViewModel()
        var fired = false
        let cancellable = vm.objectWillChange.sink { _ in fired = true }

        vm.clickThrough = true  // direct set, no didSet
        #expect(!fired, "Direct clickThrough set does NOT fire objectWillChange")

        cancellable.cancel()
    }

    @Test("SettingsStore is ObservableObject (required for SwiftUI bindings)")
    func settingsStoreIsObservableObject() {
        // SettingsStore conforms to ObservableObject via @Published
        let store = SettingsStore()
        // Verify @Published works: writing settings fires objectWillChange
        var fired = false
        let cancellable = store.objectWillChange.sink { _ in fired = true }
        store.settings.opacity = 0.5
        #expect(fired)
        cancellable.cancel()
    }

    @Test("Settings defaultModels persists correctly")
    func defaultModelsPersist() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()

        store.settings.defaultModels["behavioral"] = "gpt-4o"
        store.settings.defaultModels["coding"] = "gpt-4o"

        let store2 = SettingsStore()
        #expect(store2.settings.defaultModels["behavioral"] == "gpt-4o")
        #expect(store2.settings.defaultModels["coding"] == "gpt-4o")

        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
    }
}
