import Foundation
import AppKit
import Combine

/// Manages the permissions preflight checklist state.
@MainActor
public final class PreflightViewModel: ObservableObject {
    @Published public var permissions: [PermissionStatus] = PermissionKind.allCases.map {
        PermissionStatus(kind: $0, state: PermissionChecker.check($0))
    }

    @Published public var selectedProfileId: UUID?

    public let profileStore: ProfileStore
    private var cancellables = Set<AnyCancellable>()

    /// Convenience accessor for profiles in the store.
    public var profiles: [Profile] {
        profileStore.profiles
    }

    /// The currently selected profile, if any.
    public var selectedProfile: Profile? {
        guard let id = selectedProfileId else { return nil }
        return profileStore.get(id: id)
    }

    /// True when a profile has been selected.
    public var isProfileSelected: Bool {
        selectedProfile != nil
    }

    public var allGranted: Bool {
        permissions.allSatisfy { $0.isGranted }
    }

    public init(profileStore: ProfileStore = ProfileStore()) {
        self.profileStore = profileStore
        // Forward profile store changes so the PreflightView picker updates
        // when profiles are added/edited/deleted in Settings.
        profileStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Refresh all permission states from the system.
    public func refresh() {
        for i in permissions.indices {
            permissions[i].state = PermissionChecker.check(permissions[i].kind)
        }
        // Clear stale selection if profile was deleted elsewhere (e.g. in Settings)
        if let id = selectedProfileId, profileStore.get(id: id) == nil {
            selectedProfileId = nil
        }
    }

    /// Request a specific permission (shows system prompt if notDetermined).
    public func request(_ kind: PermissionKind) async {
        let state = await PermissionChecker.request(kind)
        if let i = permissions.firstIndex(where: { $0.kind == kind }) {
            permissions[i].state = state
        }
    }

    /// Open System Settings for a specific permission kind.
    public func openSettings(for kind: PermissionKind) {
        if let url = kind.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Profile Selection

    /// Create a new profile, store it, and select it.
    public func addProfile(name: String, resumeText: String, jd: String?) {
        let profile = Profile(
            name: name,
            resumeText: resumeText,
            defaultJD: jd
        )
        profileStore.add(profile)
        selectedProfileId = profile.id
    }

    /// Clear the current profile selection.
    public func clearSelection() {
        selectedProfileId = nil
    }
}
