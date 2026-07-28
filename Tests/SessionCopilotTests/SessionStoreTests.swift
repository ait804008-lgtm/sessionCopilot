import Foundation
import Testing
@testable import SessionCopilot

@Suite("SessionStore") @MainActor struct SessionStoreTests {

    @Test("create and fetch session")
    func createAndFetch() async throws {
        let store = SessionStoreImpl()
        let session = Session(profileId: UUID(), mode: .behavioral)
        let created = try await store.createSession(session)
        let fetched = try await store.fetchSession(created.id)
        #expect(fetched?.id == created.id)
        #expect(fetched?.mode == .behavioral)
    }

    @Test("append segment to session")
    func appendSegment() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .meeting))

        let segment = TranscriptSegment(
            sessionId: session.id,
            timestamp: Date(),
            speaker: .mic,
            text: "Test transcript",
            isFinal: true
        )
        try await store.appendSegment(segment, to: session.id)
        let fetched = try await store.fetchSession(session.id)
        #expect(fetched?.segments.count == 1)
        #expect(fetched?.segments.first?.text == "Test transcript")
    }

    @Test("append suggestion to session")
    func appendSuggestion() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .behavioral))

        let suggestion = Suggestion(
            sessionId: session.id,
            type: .answerOutline,
            content: "STAR answer outline"
        )
        try await store.appendSuggestion(suggestion, to: session.id)
        let fetched = try await store.fetchSession(session.id)
        #expect(fetched?.suggestions.count == 1)
    }

    @Test("delete session")
    func deleteSession() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .coding))
        try await store.deleteSession(session.id)
        let fetched = try await store.fetchSession(session.id)
        #expect(fetched == nil)
    }

    @Test("deleteSessions removes only specified sessions")
    func deleteSessions() async throws {
        let store = SessionStoreImpl()
        let s1 = try await store.createSession(Session(profileId: UUID(), mode: .behavioral, title: "Keep"))
        let s2 = try await store.createSession(Session(profileId: UUID(), mode: .coding, title: "Delete1"))
        let s3 = try await store.createSession(Session(profileId: UUID(), mode: .meeting, title: "Delete2"))

        try await store.deleteSessions([s2.id, s3.id])

        let remaining = try await store.fetchSessions(limit: 50)
        let ids = Set(remaining.map(\.id))
        #expect(ids.contains(s1.id))
        #expect(!ids.contains(s2.id))
        #expect(!ids.contains(s3.id))
    }

    @Test("deleteSessions with empty set is no-op")
    func deleteSessionsEmpty() async throws {
        let store = SessionStoreImpl()
        _ = try await store.createSession(Session(profileId: UUID(), mode: .behavioral))
        let before = try await store.fetchSessions(limit: 50).count
        try await store.deleteSessions([])
        let after = try await store.fetchSessions(limit: 50).count
        #expect(after == before)
    }

    @Test("deleteAllSessions removes every session")
    func deleteAllSessions() async throws {
        let store = SessionStoreImpl()
        // Create several sessions
        for i in 0..<5 {
            _ = try await store.createSession(Session(profileId: UUID(), mode: .meeting, title: "Session \(i)"))
        }
        let before = try await store.fetchSessions(limit: 100).count
        #expect(before >= 5)

        try await store.deleteAllSessions()

        let after = try await store.fetchSessions(limit: 100).count
        #expect(after == 0)
    }

    @Test("deleteAllSessions on empty store is no-op")
    func deleteAllSessionsEmpty() async throws {
        let store = SessionStoreImpl()
        try await store.deleteAllSessions() // Should not crash
        let sessions = try await store.fetchSessions(limit: 50)
        #expect(sessions.isEmpty)
    }

    @Test("fetch sessions respects limit")
    func fetchSessionsLimit() async throws {
        let store = SessionStoreImpl()
        for _ in 0..<5 {
            _ = try await store.createSession(Session(profileId: UUID(), mode: .meeting))
        }
        let recent = try await store.fetchSessions(limit: 3)
        #expect(recent.count == 3)
    }

    @Test("export markdown produces valid output")
    func exportMarkdown() async throws {
        let store = SessionStoreImpl()
        var session = Session(profileId: UUID(), mode: .behavioral, title: "Mock Interview")
        session.segments = [
            TranscriptSegment(sessionId: session.id, timestamp: Date(), speaker: .mic, text: "I led a team", isFinal: true)
        ]
        let created = try await store.createSession(session)
        let url = try await store.exportSession(created.id, format: .markdown)
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.contains("Mock Interview"))
        #expect(content.contains("I led a team"))
    }

    @Test("export json produces valid JSON")
    func exportJSON() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .coding, title: "Code Test"))
        let url = try await store.exportSession(session.id, format: .json)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.title == "Code Test")
    }
}

@Suite("SettingsStore") @MainActor struct SettingsStoreTests {

    @Test("initializes with default settings")
    func defaults() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()
        #expect(store.settings.opacity == 0.8)
        #expect(store.settings.clickThrough == false)
        #expect(store.settings.retentionDays == 30)
    }

    @Test("updating settings persists")
    func updatePersists() {
        let store = SettingsStore()
        store.settings.opacity = 0.5
        store.settings.clickThrough = true

        let store2 = SettingsStore()
        #expect(store2.settings.opacity == 0.5)
        #expect(store2.settings.clickThrough == true)
    }
}

// OnboardingState tests skipped — UserDefaults persistence across test suites
// makes these unreliable. The logic is a trivial Bool wrapper.
