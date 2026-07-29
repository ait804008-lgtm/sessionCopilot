import SwiftUI

// MARK: - STT Language Support

/// Languages supported by each STT provider.
struct SttLanguageSupport {
    /// All languages Apple SFSpeechRecognizer supports (common subset).
    static let appleLanguages: [(code: String, label: String)] = [
        ("en", "English"), ("fr", "Français"), ("es", "Español"), ("de", "Deutsch"),
        ("zh", "中文 (Chinese)"), ("ja", "日本語 (Japanese)"), ("ko", "한국어 (Korean)"),
        ("pt", "Português"), ("it", "Italiano"), ("ru", "Русский (Russian)"),
        ("ar", "العربية (Arabic)"), ("hi", "हिन्दी (Hindi)"), ("nl", "Nederlands"),
        ("sv", "Svenska"), ("tr", "Türkçe"), ("pl", "Polski"),
        ("th", "ไทย (Thai)"), ("vi", "Tiếng Việt"), ("id", "Bahasa Indonesia"),
        ("ms", "Bahasa Melayu"),
    ]

    /// Languages Deepgram Nova-3 model supports.
    static let deepgramLanguages: [(code: String, label: String)] = [
        ("en", "English"), ("fr", "Français"), ("es", "Español"), ("de", "Deutsch"),
        ("zh", "中文 (Chinese)"), ("ja", "日本語 (Japanese)"), ("ko", "한국어 (Korean)"),
        ("pt", "Português"), ("it", "Italiano"), ("ru", "Русский (Russian)"),
        ("ar", "العربية (Arabic)"), ("hi", "हिन्दी (Hindi)"), ("nl", "Nederlands"),
        ("sv", "Svenska"), ("tr", "Türkçe"), ("pl", "Polski"),
        ("vi", "Tiếng Việt"), ("th", "ไทย (Thai)"), ("id", "Bahasa Indonesia"),
        ("ms", "Bahasa Melayu"),
    ]

    static func languages(for provider: String) -> [(code: String, label: String)] {
        provider == "deepgram" ? deepgramLanguages : appleLanguages
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var providerStore: ProviderConfigStore
    @ObservedObject var profileStore: ProfileStore
    @State private var editingProfile: Profile?
    @State private var showCreateProfile = false
    @State private var profileToDelete: Profile?
    @State private var showDeleteConfirmation = false
    @State private var selectedProfileIds: Set<UUID> = []
    @State private var showDeleteSelectedConfirmation = false
    @State private var selectedTab = "General"

    private let navItems: [(id: String, icon: String, label: String)] = [
        ("General", "gearshape", "General"),
        ("Providers", "key", "Providers"),
        ("STT", "waveform", "STT"),
        ("Models", "slider.horizontal.3", "Models"),
        ("Profiles", "person.crop.circle", "Profiles"),
    ]

    private var allProfilesSelected: Bool {
        !profileStore.profiles.isEmpty && selectedProfileIds.count == profileStore.profiles.count
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VStack(spacing: 0) {
                ForEach(navItems, id: \.id) { item in
                    Button(action: { selectedTab = item.id }) {
                        HStack(spacing: 8) {
                            Image(systemName: item.icon)
                                .frame(width: 18)
                            Text(item.label)
                                .fontWeight(selectedTab == item.id ? .semibold : .regular)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == item.id ? Color.accentColor.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 160)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

    // MARK: - Content
    ScrollView {
        tabContent
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity)
        }
        .frame(width: 680, height: 500)
        .sheet(isPresented: $showCreateProfile) {
            ProfileEditView { name, resumeText, jd in
                profileStore.add(Profile(name: name, resumeText: resumeText, defaultJD: jd))
            }
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditView(profile: profile) { name, resumeText, jd in
                var updated = profile
                updated.name = name
                updated.resumeText = resumeText
                updated.defaultJD = jd
                profileStore.update(updated)
            }
        }
        .alert("Delete Profile?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let p = profileToDelete {
                    profileStore.remove(p)
                    profileToDelete = nil
                    selectedProfileIds.remove(p.id)
                }
            }
        } message: {
            Text("Delete \"\(profileToDelete?.name ?? "")\"? This action cannot be undone.")
        }
        .alert("Delete Selected Profiles?", isPresented: $showDeleteSelectedConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(selectedProfileIds.count) Profiles", role: .destructive) {
                profileStore.removeAll(ids: selectedProfileIds)
                selectedProfileIds.removeAll()
            }
        } message: {
            Text("This will permanently delete \(selectedProfileIds.count) selected profile(s).")
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case "General": generalContent
        case "Providers": providersContent
        case "STT": sttContent
        case "Models": modelsContent
        case "Profiles": profilesContent
        default: generalContent
        }
    }

    // MARK: - General

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // --- GENERAL ---
            SectionHeader("GENERAL")

            SettingsRow(label: "Transcribe Shortcut") {
                Text(settingsStore.settings.hotkeys.pushToTalk)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            SettingsRow(label: "Push To Talk") {
                Toggle("", isOn: Binding(
                    get: { settingsStore.settings.listenMode == "pushToTalk" },
                    set: { settingsStore.settings.listenMode = $0 ? "pushToTalk" : "auto" }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            SettingsRow(label: "Language") {
                let languages = SttLanguageSupport.languages(for: settingsStore.settings.sttProvider)
                Picker("", selection: $settingsStore.settings.sttLanguage) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }

            Divider().padding(.vertical, 4)

            // --- SOUND ---
            SectionHeader("SOUND")

            SettingsRow(label: "Opacity") {
                Slider(value: $settingsStore.settings.opacity, in: 0.1...1.0)
                    .frame(width: 140)
                Text("\(Int(settingsStore.settings.opacity * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            SettingsRow(label: "Click-through") {
                Toggle("", isOn: $settingsStore.settings.clickThrough)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider().padding(.vertical, 4)

            // --- DETECTION ---
            SectionHeader("DETECTION")

            SettingsRow(label: "Semantic Detection") {
                Toggle("", isOn: $settingsStore.settings.semanticDetectionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .help("When enabled, candidate questions are confirmed by an LLM call before answer generation fires. Prevents spurious LLM calls on thinking pauses.")

            SettingsRow(label: "Silence Threshold") {
                Slider(value: $settingsStore.settings.silenceThreshold, in: 0.5...5.0, step: 0.1)
                    .frame(width: 140)
                Text(String(format: "%.1fs", settingsStore.settings.silenceThreshold))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            SettingsRow(label: "Audio Recording") {
                Toggle("", isOn: $settingsStore.settings.audioRecordingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .help("Record mic + system audio to a WAV file for each session (~10 MB / 30 min). Disable to save disk space.")

            Divider().padding(.vertical, 4)

            // --- STT ---
            SectionHeader("SPEECH-TO-TEXT")

            SettingsRow(label: "Provider") {
                Picker("", selection: $settingsStore.settings.sttProvider) {
                    Text("Apple (On-Device)").tag("apple")
                    Text("Deepgram (Cloud)").tag("deepgram")
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            if settingsStore.settings.sttProvider == "deepgram" {
                SettingsRow(label: "") {
                    Text("Requires Deepgram API key in Providers tab.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            SettingsRow(label: "Keep History") {
                Stepper("\(settingsStore.settings.retentionDays) days",
                        value: $settingsStore.settings.retentionDays, in: 1...365)
            }

            Divider().padding(.vertical, 4)

            // --- HOTKEYS ---
            SectionHeader("HOTKEYS")

            SettingsRow(label: "Show/Hide") {
                Text(settingsStore.settings.hotkeys.showHide)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            SettingsRow(label: "Start/Stop") {
                Text(settingsStore.settings.hotkeys.startStop)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            SettingsRow(label: "Region Capture") {
                Text(settingsStore.settings.hotkeys.regionCapture)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            SettingsRow(label: "Push-to-Talk") {
                Text(settingsStore.settings.hotkeys.pushToTalk)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 4)

            // --- RESET ---
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    settingsStore.reset()
                }
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Providers

    private var providersContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("PROVIDERS")
            ForEach(providerStore.configs) { config in
                ProviderRow(config: config, providerStore: providerStore)
                Divider()
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - STT

    private var sttContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // --- Provider Selection ---
            SectionHeader("STT PROVIDER")

            SettingsRow(label: "Provider") {
                Picker("", selection: $settingsStore.settings.sttProvider) {
                    Text("Apple (On-Device)").tag("apple")
                    Text("Deepgram (Cloud)").tag("deepgram")
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            if settingsStore.settings.sttProvider == "deepgram" {
                Text("Requires Deepgram API key in Providers tab.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 4)

            // --- Default Language ---
            SectionHeader("DEFAULT LANGUAGE")

            SettingsRow(label: "Language") {
                let languages = SttLanguageSupport.languages(for: settingsStore.settings.sttProvider)
                Picker("", selection: $settingsStore.settings.sttLanguage) {
                    ForEach(languages, id: \.code) { lang in
                        Text(lang.label).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 180)
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Models

    private var modelsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader("MODEL PER SESSION MODE")
            ForEach(SessionMode.allCases, id: \.self) { mode in
                HStack {
                    Text(mode.label)
                        .frame(width: 110, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { settingsStore.settings.defaultModels[mode.defaultModelKey] ?? "" },
                        set: { settingsStore.settings.defaultModels[mode.defaultModelKey] = $0 }
                    )) {
                        Text("— Use Default —").tag("")
                        ForEach(providerStore.configs) { config in
                            Text("\(config.provider.rawValue.capitalized) — \(config.model)")
                                .tag(config.model)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 240)
                }
            }
            Spacer()
        }
        .padding(24)
    }

    // MARK: - Profiles

    private var profilesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionHeader("PROFILES")
                Spacer()
                Text("\(profileStore.profiles.count) profile(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("New Profile") { showCreateProfile = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.bottom, 8)

            if !profileStore.profiles.isEmpty {
                HStack(spacing: 8) {
                    Button(action: {
                        if allProfilesSelected {
                            selectedProfileIds.removeAll()
                        } else {
                            selectedProfileIds = Set(profileStore.profiles.map(\.id))
                        }
                    }) {
                        Text(allProfilesSelected ? "Deselect All" : "Select All")
                    }
                    .controlSize(.small)
                    if !selectedProfileIds.isEmpty {
                        Button("Delete Selected (\(selectedProfileIds.count))") {
                            showDeleteSelectedConfirmation = true
                        }
                        .foregroundColor(.red)
                        .controlSize(.small)
                    }
                }
                .padding(.bottom, 4)
            }

            if profileStore.profiles.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No profiles yet")
                        .font(.headline)
                    Text("Create a profile to personalize AI suggestions with your resume and target job.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(profileStore.profiles) { profile in
                    ProfileListRow(profile: profile,
                                   isSelected: selectedProfileIds.contains(profile.id),
                                   onEdit: { editingProfile = profile },
                                   onDelete: {
                                       profileToDelete = profile
                                       showDeleteConfirmation = true
                                   },
                                   onTap: {
                                       if selectedProfileIds.contains(profile.id) {
                                           selectedProfileIds.remove(profile.id)
                                       } else {
                                           selectedProfileIds.insert(profile.id)
                                       }
                                   })
                    Divider()
                }
            }
            Spacer()
        }
        .padding(24)
    }
}

// MARK: - Shared Components

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundColor(.secondary)
            .padding(.bottom, 4)
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            if !label.isEmpty {
                Text(label)
                    .frame(width: 140, alignment: .leading)
            }
            content()
            Spacer()
        }
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let config: ProviderConfig
    @ObservedObject var providerStore: ProviderConfigStore
    @State private var apiKey: String = ""
    @State private var showKey: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: config.isDefault ? "star.fill" : "star")
                    .foregroundColor(.yellow)
                VStack(alignment: .leading) {
                    Text(config.provider.rawValue.capitalized).font(.headline)
                    Text("\(config.model) — \(config.baseURL)")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !config.isDefault {
                    Button("Set Default") { providerStore.setDefault(config) }
                        .controlSize(.small)
                }
            }
            HStack {
                if showKey {
                    TextField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                    Button("Save") { try? providerStore.setKey(apiKey, for: config) }
                        .controlSize(.small)
                } else {
                    SecureField("API Key (enter to save)", text: $apiKey)
                        .textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { try? providerStore.setKey(apiKey, for: config) }
                }
                Button(action: { showKey.toggle() }) {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showKey ? "Hide key" : "Show key")
            }
        }
        .padding(.vertical, 4)
        .onAppear { apiKey = providerStore.getKey(for: config) ?? "" }
    }
}

// MARK: - Profile List Row

struct ProfileListRow: View {
    let profile: Profile
    var isSelected: Bool = false
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onTap: (() -> Void)?

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.body)
                if let jd = profile.defaultJD {
                    Text("JD: \(jd.prefix(60))\(jd.count > 60 ? "…" : "")")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
                Text("Resume: \(profile.resumeText.prefix(60))\(profile.resumeText.count > 60 ? "…" : "")")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                Button("Edit") { onEdit() }.buttonStyle(.bordered).controlSize(.small)
                Button("Delete") { onDelete() }.buttonStyle(.bordered).controlSize(.small).tint(.red)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}
