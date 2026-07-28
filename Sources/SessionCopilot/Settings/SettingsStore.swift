import Foundation
import SwiftUI

/// Manages app settings persisted in UserDefaults.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet { save() }
    }

    private let defaultsKey = "com.sessioncopilot.settings"

    public init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
        migrateDefaultModels()
    }

    private func migrateDefaultModels() {
        let stale = ["deepseek-chat", "deepseek-coder"]
        var changed = false
        for mode in SessionMode.allCases {
            if let model = settings.defaultModels[mode.defaultModelKey], stale.contains(model) {
                settings.defaultModels[mode.defaultModelKey] = "deepseek-v4-flash"
                changed = true
            }
        }
        if changed { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    public func reset() {
        settings = AppSettings()
    }
}

/// Tracks whether the Responsible Use screen has been shown.
public struct OnboardingState {
    private static let key = "com.sessioncopilot.responsibleUseShown"

    public static var hasShownResponsibleUse: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
