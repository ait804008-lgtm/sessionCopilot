import Foundation

/// Container for shared services passed through the app.
///
/// Avoids having each controller reach into `AppDelegate` for stores.
/// All members are `@MainActor`-bound reference types — `Services` itself
/// is a value type for cheap passing.
public struct Services {
    public let viewModel: OverlayViewModel
    public let profileStore: ProfileStore
    public let preflightVM: PreflightViewModel
    public let settingsStore: SettingsStore
    public let providerStore: ProviderConfigStore
    public let sessionStore: SessionStoreImpl

    public init(
        viewModel: OverlayViewModel,
        profileStore: ProfileStore,
        preflightVM: PreflightViewModel,
        settingsStore: SettingsStore,
        providerStore: ProviderConfigStore,
        sessionStore: SessionStoreImpl
    ) {
        self.viewModel = viewModel
        self.profileStore = profileStore
        self.preflightVM = preflightVM
        self.settingsStore = settingsStore
        self.providerStore = providerStore
        self.sessionStore = sessionStore
    }

    /// Convenience factory — instantiates all stores with default
    /// configuration. The standard entry point used by `AppDelegate`.
    @MainActor
    public static func makeDefault() -> Services {
        let profileStore = ProfileStore()
        let settingsStore = SettingsStore()
        let providerStore = ProviderConfigStore()
        let sessionStore = SessionStoreImpl()
        let viewModel = OverlayViewModel()
        let preflightVM = PreflightViewModel(profileStore: profileStore)
        return Services(
            viewModel: viewModel,
            profileStore: profileStore,
            preflightVM: preflightVM,
            settingsStore: settingsStore,
            providerStore: providerStore,
            sessionStore: sessionStore
        )
    }
}
