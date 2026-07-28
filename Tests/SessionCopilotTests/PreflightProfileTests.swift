import Foundation
import Testing
@testable import SessionCopilot

// MARK: - PreflightViewModel Profile Selection Tests

@Suite("PreflightViewModel Profile Selection") @MainActor struct PreflightViewModelProfileTests {

    @Test("PreflightViewModel loads profiles from ProfileStore")
    func loadsProfiles() {
        let store = ProfileStore()
        store.add(Profile(name: "Test User", resumeText: "SWE"))
        let vm = PreflightViewModel(profileStore: store)
        #expect(vm.profiles.contains { $0.name == "Test User" })
    }

    @Test("selectedProfileId starts nil")
    func selectedProfileStartsNil() {
        let vm = PreflightViewModel()
        #expect(vm.selectedProfileId == nil)
    }

    @Test("selectedProfile returns nil when no selection")
    func selectedProfileNilWhenNoSelection() {
        let vm = PreflightViewModel()
        #expect(vm.selectedProfile == nil)
    }

    @Test("selecting a profile makes it available via selectedProfile")
    func selectProfile() {
        let store = ProfileStore()
        let profile = Profile(name: "Test User", resumeText: "SWE")
        store.add(profile)
        let vm = PreflightViewModel(profileStore: store)
        vm.selectedProfileId = profile.id
        #expect(vm.selectedProfile?.id == profile.id)
        #expect(vm.selectedProfile?.name == "Test User")
    }

    @Test("isProfileSelected is false when no profile selected")
    func isProfileSelectedFalse() {
        let vm = PreflightViewModel()
        #expect(!vm.isProfileSelected)
    }

    @Test("isProfileSelected is true when profile selected")
    func isProfileSelectedTrue() {
        let store = ProfileStore()
        let profile = Profile(name: "Test User", resumeText: "SWE")
        store.add(profile)
        let vm = PreflightViewModel(profileStore: store)
        vm.selectedProfileId = profile.id
        #expect(vm.isProfileSelected)
    }

    @Test("addProfile creates a new profile and selects it")
    func addProfileCreatesAndSelects() {
        let store = ProfileStore()
        let vm = PreflightViewModel(profileStore: store)
        vm.addProfile(name: "New User", resumeText: "Resume", jd: "JD")
        #expect(store.profiles.contains { $0.name == "New User" })
        #expect(vm.profiles.contains { $0.name == "New User" })
        #expect(vm.selectedProfile?.name == "New User")
    }

    @Test("addProfile with nil JD stores nil")
    func addProfileNilJD() {
        let store = ProfileStore()
        let vm = PreflightViewModel(profileStore: store)
        vm.addProfile(name: "No JD", resumeText: "Resume", jd: nil)
        #expect(vm.selectedProfile?.defaultJD == nil)
    }

    @Test("clearSelection resets selectedProfileId to nil")
    func clearSelection() {
        let store = ProfileStore()
        let profile = Profile(name: "Test User", resumeText: "SWE")
        store.add(profile)
        let vm = PreflightViewModel(profileStore: store)
        vm.selectedProfileId = profile.id
        vm.clearSelection()
        #expect(vm.selectedProfileId == nil)
        #expect(vm.selectedProfile == nil)
        #expect(!vm.isProfileSelected)
    }

    @Test("Profile add → select → retrieve round-trip via PreflightViewModel")
    func profileRoundTripViaViewModel() {
        let store = ProfileStore()
        let vm = PreflightViewModel(profileStore: store)

        // Add
        vm.addProfile(name: "Round Trip", resumeText: "Resume text", jd: "JD text")

        // Retrieve via selectedProfile
        #expect(vm.selectedProfile?.name == "Round Trip")
        #expect(vm.selectedProfile?.resumeText == "Resume text")
        #expect(vm.selectedProfile?.defaultJD == "JD text")

        // Clear and re-select from store
        vm.clearSelection()
        #expect(vm.selectedProfile == nil)

        let added = vm.profiles.first { $0.name == "Round Trip" }!
        vm.selectedProfileId = added.id
        #expect(vm.selectedProfile?.name == "Round Trip")
    }

    @Test("selectedProfile returns nil for invalid UUID")
    func selectedProfileInvalidUUID() {
        let store = ProfileStore()
        let vm = PreflightViewModel(profileStore: store)
        vm.selectedProfileId = UUID()  // not in store
        #expect(vm.selectedProfile == nil)
        #expect(!vm.isProfileSelected)
    }

    @Test("refresh clears stale selection when profile deleted from store")
    func refreshClearsStaleSelection() {
        let store = ProfileStore()
        let profile = Profile(name: "To Delete", resumeText: "SWE")
        store.add(profile)
        let vm = PreflightViewModel(profileStore: store)
        vm.selectedProfileId = profile.id
        #expect(vm.isProfileSelected)

        // Simulate deletion in Settings: remove directly from store
        store.remove(profile)
        // Profile should no longer be in store (but other test profiles may exist)
        #expect(!vm.profiles.contains { $0.id == profile.id })
        // selectedProfile returns nil since the profile is gone
        #expect(vm.selectedProfile == nil)
        #expect(vm.selectedProfileId != nil, "selectedProfileId still set before refresh")

        // After refresh, stale selection should be cleared
        vm.refresh()
        #expect(vm.selectedProfileId == nil, "stale selectedProfileId cleared after refresh")
        #expect(!vm.isProfileSelected)
    }

    @Test("profiles computed property reflects store changes reactively")
    func profilesReflectsStoreChanges() {
        let store = ProfileStore()
        let vm = PreflightViewModel(profileStore: store)
        let initialCount = vm.profiles.count

        // Add a profile directly to the store
        store.add(Profile(name: "Reactive Test", resumeText: "SWE"))

        // profiles should reflect the addition immediately (same store instance)
        #expect(vm.profiles.count == initialCount + 1)
        #expect(vm.profiles.contains { $0.name == "Reactive Test" })

        // Remove it directly from the store
        if let added = vm.profiles.first(where: { $0.name == "Reactive Test" }) {
            store.remove(added)
        }
        #expect(vm.profiles.count == initialCount)
        #expect(!vm.profiles.contains { $0.name == "Reactive Test" })
    }
}
