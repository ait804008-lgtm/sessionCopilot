import SwiftUI

/// Detail view showing a session's timeline (interleaved transcript + suggestions).
/// Includes export and delete actions.
struct SessionDetailView: View {
    let session: Session
    let store: SessionStoreImpl
    var onDismiss: () -> Void

    @State private var showDeleteConfirmation = false
    @State private var exportError: String?
    @State private var showExportError = false
    @State private var scores: [String: Int]?
    @State private var isScoring = false
    @State private var scoreError: String?
    @State private var showScoreError = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? "Untitled Session")
                        .font(.headline)
                    Text(session.startedAt.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()

                // Export buttons
                Button("Export MD") { exportMarkdown() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Export JSON") { exportJSON() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Close button
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Close")

                // Score Session button
                Button {
                    scoreSession()
                } label: {
                    if isScoring {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "chart.bar.fill")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isScoring || session.segments.isEmpty)
                .help("Score Session")
            }
            .padding(12)

            Divider()

            // Scores section (shown when scores are available)
            if let scores {
                ScoreCardView(scores: scores)
                    .padding(12)
                Divider()
            } else if let scoreError {
                Text("Scoring failed: \(scoreError)")
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(12)
                Divider()
            } else if isScoring {
                HStack {
                    ProgressView()
                    Text("Scoring session...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                Divider()
            }

            // Audio playback section (shown when audio file exists)
            if let audioPath = session.audioFilePath, !audioPath.isEmpty {
                AudioPlaybackView(sessionId: session.id, audioFilePath: audioPath)
                    .padding(12)
                Divider()
            }

            // Chat history
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(chatMessages) { message in
                        ChatBubble(message: message)
                    }
                    if chatMessages.isEmpty {
                        Text("No transcript or suggestions in this session.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 600, height: 500)
        .alert("Delete Session?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await store.deleteSession(session.id)
                    onDismiss()
                }
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Export Failed", isPresented: $showExportError) {
            Button("OK") {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    // MARK: - Chat Messages

    /// Interleave segments (questions) and suggestions (answers) as chat messages,
    /// matching the overlay's ChatBubble look.
    private var chatMessages: [ChatMessage] {
        var messages: [ChatMessage] = []
        for seg in session.segments {
            messages.append(ChatMessage(
                role: seg.speaker == .mic ? .user : .assistant,
                text: seg.text,
                timestamp: seg.timestamp,
                segmentId: seg.id
            ))
        }
        for sug in session.suggestions {
            messages.append(ChatMessage(
                role: .assistant,
                text: sug.content,
                timestamp: sug.timestamp
            ))
        }
        return messages.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Scoring

    private func scoreSession() {
        isScoring = true
        scoreError = nil
        scores = nil

        Task {
            do {
                // Use the default provider config
                let config = ProviderConfigStore().defaultConfig() ?? ProviderConfig(
                    provider: .deepseek,
                    baseURL: "https://api.deepseek.com",
                    model: "deepseek-chat",
                    apiKeyRef: "com.sessioncopilot.deepseek-key"
                )

                let apiKey = (try? KeychainStore().load(key: config.apiKeyRef))
                    ?? ProcessInfo.processInfo.environment["\(config.provider.rawValue.uppercased())_API_KEY"] ?? ""
                let client = LlmClientImpl()
                try client.configure(config, apiKey: apiKey)

                let result = try await PostScorer.score(session: session, using: client)
                await MainActor.run {
                    self.scores = result
                    self.isScoring = false
                }
            } catch {
                await MainActor.run {
                    self.scoreError = error.localizedDescription
                    self.showScoreError = true
                    self.isScoring = false
                }
            }
        }
    }

    // MARK: - Export

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(session.title ?? "session").md"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let exportedURL = try await store.exportSession(session.id, format: .markdown)
                    let content = try String(contentsOf: exportedURL, encoding: .utf8)
                    try content.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    exportError = error.localizedDescription
                    showExportError = true
                }
            }
        }
    }

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(session.title ?? "session").json"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    let exportedURL = try await store.exportSession(session.id, format: .json)
                    let data = try Data(contentsOf: exportedURL)
                    try data.write(to: url)
                } catch {
                    exportError = error.localizedDescription
                    showExportError = true
                }
            }
        }
    }
}

// MARK: - Score Card View

struct ScoreCardView: View {
    let scores: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Scores")
                .font(.headline)

            HStack(spacing: 16) {
                ForEach(sortedScores, id: \.0) { key, value in
                    VStack(spacing: 4) {
                        Text("\(value)")
                            .font(.title2)
                            .foregroundColor(scoreColor(value))
                        Text(key.capitalized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 70)
                }
            }
        }
    }

    private var sortedScores: [(String, Int)] {
        scores.sorted { $0.key < $1.key }
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 5: return .green
        case 4: return .blue
        case 3: return .yellow
        default: return .orange
        }
    }
}


