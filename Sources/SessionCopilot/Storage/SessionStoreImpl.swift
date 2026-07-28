import Foundation

/// JSON file-based session storage implementing SessionStore protocol.
/// ponytail: JSON file store; migrate to SQLite when query performance matters.
@MainActor
public final class SessionStoreImpl: SessionStore {
    private let fileURL: URL
    private var sessions: [Session] = []

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SessionCopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("sessions.json")
        load()
    }

    // MARK: - SessionStore

    public func createSession(_ session: Session) async throws -> Session {
        sessions.append(session)
        save()
        return session
    }

    public func appendSegment(_ segment: TranscriptSegment, to sessionId: UUID) async throws {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[i].segments.append(segment)
        save()
    }

    public func appendSuggestion(_ suggestion: Suggestion, to sessionId: UUID) async throws {
        guard let i = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[i].suggestions.append(suggestion)
        save()
    }

    public func fetchSession(_ id: UUID) async throws -> Session? {
        sessions.first { $0.id == id }
    }

    public func fetchSessions(limit: Int = 50) async throws -> [Session] {
        Array(sessions.suffix(limit).reversed())
    }

    public func deleteSession(_ id: UUID) async throws {
        sessions.removeAll { $0.id == id }
        save()
    }

    public func deleteSessions(_ ids: Set<UUID>) async throws {
        guard !ids.isEmpty else { return }
        sessions.removeAll { ids.contains($0.id) }
        save()
    }

    public func deleteAllSessions() async throws {
        sessions.removeAll()
        save()
    }

    /// Delete sessions that are older than the specified number of days.
    /// Only deletes sessions with status `.done` (not live/paused sessions).
    /// Returns the number of sessions deleted.
    @discardableResult
    public func deleteSessionsOlderThan(days: Int) async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let toDelete = sessions.filter { session in
            session.status == .done &&
            session.startedAt < cutoff
        }
        let count = toDelete.count
        sessions.removeAll { session in
            session.status == .done && session.startedAt < cutoff
        }
        if count > 0 {
            save()
        }
        return count
    }

    public func exportSession(_ id: UUID, format: ExportFormat) async throws -> URL {
        guard let session = sessions.first(where: { $0.id == id }) else {
            throw SessionStoreError.notFound
        }
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("SessionCopilotExports")
        try? FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)

        switch format {
        case .markdown:
            let md = renderMarkdown(session)
            let url = exportDir.appendingPathComponent("\(session.title ?? "session")-\(id.uuidString.prefix(8)).md")
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url

        case .json:
            let data = try JSONEncoder().encode(session)
            let url = exportDir.appendingPathComponent("\(session.title ?? "session")-\(id.uuidString.prefix(8)).json")
            try data.write(to: url)
            return url
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Session].self, from: data) {
            sessions = decoded
        }
    }

    // MARK: - Markdown Rendering

    private func renderMarkdown(_ session: Session) -> String {
        var md = "# Session: \(session.title ?? "Untitled")\n\n"
        md += "**Mode:** \(session.mode.rawValue) | **Date:** \(session.startedAt.formatted())\n\n"

        // Combine segments and suggestions by timestamp
        var items: [(Date, String)] = []
        for seg in session.segments {
            let speaker = seg.speaker == .mic ? "You" : "Them"
            items.append((seg.timestamp, "**\(speaker):** \(seg.text)"))
        }
        for sug in session.suggestions {
            items.append((sug.timestamp, "\n> **Suggestion:** \(sug.content)"))
        }
        items.sort { $0.0 < $1.0 }

        for (_, text) in items {
            md += "\(text)\n\n"
        }

        return md
    }
}

enum SessionStoreError: Error {
    case notFound
}
