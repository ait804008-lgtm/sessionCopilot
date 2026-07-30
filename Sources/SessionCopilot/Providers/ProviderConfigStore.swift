import Foundation

/// Manages provider configurations (API endpoints, models).
/// Persists in UserDefaults for non-secret fields; keys in Keychain.
@MainActor
public final class ProviderConfigStore: ObservableObject {
    @Published public var configs: [ProviderConfig] = []
    private let keychain = KeychainStore()
    private let defaultsKey = "com.sessioncopilot.providerConfigs"

    public init() {
        load()
        if configs.isEmpty {
            seedDefaults()
        }
        // ponytail: migrate stale default model names to current DeepSeek models
        migrateModelNames()
    }

    /// Pre-populate with well-known provider endpoints (keys must be added separately).
    private func seedDefaults() {
        configs = [
            ProviderConfig(
                provider: .deepseek,
                baseURL: "https://api.deepseek.com",
                model: "deepseek-v4-flash",
                apiKeyRef: "com.sessioncopilot.deepseek-key",
                isDefault: true
            ),
            ProviderConfig(
                provider: .anthropic,
                baseURL: "https://api.anthropic.com",
                model: "claude-sonnet-4-20250514",
                apiKeyRef: "com.sessioncopilot.anthropic-key",
                isDefault: false
            ),
            ProviderConfig(
                provider: .openai,
                baseURL: "https://api.openai.com",
                model: "gpt-4o",
                apiKeyRef: "com.sessioncopilot.openai-key",
                isDefault: false
            ),
            ProviderConfig(
                provider: .deepgram,
                baseURL: "https://api.deepgram.com",
                model: "nova-3",
                apiKeyRef: "com.sessioncopilot.deepgram-key",
                isDefault: false
            ),
            ProviderConfig(
                provider: .gemini,
                baseURL: "https://generativelanguage.googleapis.com",
                model: "gemini-2.5-pro",
                apiKeyRef: "com.sessioncopilot.gemini-key",
                isDefault: false
            ),
            ProviderConfig(
                provider: .nemotron,
                baseURL: "http://localhost:8000",
                model: "nemotron-3.5",
                apiKeyRef: "com.sessioncopilot.nemotron-key",
                isDefault: false
            ),
        ]
        save()
    }

    // MARK: - CRUD

    public func add(_ config: ProviderConfig) throws {
        var newConfig = config
        // Store API key in Keychain
        // ponytail: key stored separately; ref is the config's apiKeyRef
        configs.append(newConfig)
        save()
    }

    public func remove(_ config: ProviderConfig) {
        configs.removeAll { $0.id == config.id }
        try? keychain.delete(key: config.apiKeyRef)
        save()
    }

    public func setDefault(_ config: ProviderConfig) {
        for i in configs.indices {
            configs[i].isDefault = (configs[i].id == config.id)
        }
        save()
    }

    /// Store API key in Keychain for a provider config.
    public func setKey(_ key: String, for config: ProviderConfig) throws {
        try keychain.save(key: config.apiKeyRef, value: key)
    }

    /// Load API key from Keychain for a provider config.
    public func getKey(for config: ProviderConfig) -> String? {
        try? keychain.load(key: config.apiKeyRef)
    }

    public func defaultConfig(for provider: ProviderConfig.Provider? = nil) -> ProviderConfig? {
        if let provider {
            return configs.first { $0.provider == provider && $0.isDefault }
                ?? configs.first { $0.provider == provider }
        }
        // When no specific provider is requested (LLM call sites), only
        // consider LLM-capable providers. Otherwise an STT provider like
        // Deepgram that's marked as default would be picked up for LLM
        // calls and fail with a nonsensical "NO API KEY for deepgram" error.
        return configs.first { $0.isDefault && $0.provider.isLLM }
            ?? configs.first { $0.provider.isLLM }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            configs = decoded
        }
    }

    /// Update stale DeepSeek model names in persisted configs.
    private func migrateModelNames() {
        var changed = false
        for i in configs.indices where configs[i].provider == .deepseek {
            if configs[i].model == "deepseek-chat" || configs[i].model == "deepseek-coder" {
                configs[i] = ProviderConfig(
                    id: configs[i].id,
                    provider: configs[i].provider,
                    baseURL: configs[i].baseURL,
                    model: "deepseek-v4-flash",
                    apiKeyRef: configs[i].apiKeyRef,
                    isDefault: configs[i].isDefault
                )
                changed = true
            }
        }
        if changed { save() }
    }
}
