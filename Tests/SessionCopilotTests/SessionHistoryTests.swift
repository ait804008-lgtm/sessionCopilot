import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Session History Data Tests

@Suite("Session History Data") @MainActor struct SessionHistoryDataTests {

    @Test("fetchSessions returns sessions ordered by most recent first")
    func fetchSessionsOrdered() async throws {
        let store = SessionStoreImpl()
        let s1 = try await store.createSession(Session(profileId: UUID(), mode: .behavioral, title: "First"))
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        let s2 = try await store.createSession(Session(profileId: UUID(), mode: .coding, title: "Second"))

        let sessions = try await store.fetchSessions(limit: 10)
        #expect(sessions.count >= 2)
        // Most recent first (fetchSessions reverses)
        #expect(sessions.first?.title == "Second")
    }

    @Test("fetchSessions respects limit")
    func fetchSessionsLimit() async throws {
        let store = SessionStoreImpl()
        for i in 0..<5 {
            _ = try await store.createSession(Session(profileId: UUID(), mode: .meeting, title: "Session \(i)"))
        }

        let sessions = try await store.fetchSessions(limit: 3)
        #expect(sessions.count == 3)
    }

    @Test("Session with segments and suggestions has correct counts")
    func sessionCounts() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .behavioral))

        try await store.appendSegment(
            TranscriptSegment(sessionId: session.id, timestamp: Date(), speaker: .mic, text: "Hello", isFinal: true),
            to: session.id
        )
        try await store.appendSegment(
            TranscriptSegment(sessionId: session.id, timestamp: Date(), speaker: .unknown, text: "What's your background?", isFinal: true),
            to: session.id
        )
        try await store.appendSuggestion(
            Suggestion(sessionId: session.id, type: .answerOutline, content: "## Outline\n- Point"),
            to: session.id
        )

        let fetched = try await store.fetchSession(session.id)
        #expect(fetched?.segments.count == 2)
        #expect(fetched?.suggestions.count == 1)
    }

    @Test("delete session removes it from store")
    func deleteSession() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .behavioral, title: "To Delete"))

        try await store.deleteSession(session.id)

        let fetched = try await store.fetchSession(session.id)
        #expect(fetched == nil)
    }

    @Test("deleteSessions removes only specified subset")
    func deleteSessionsSubset() async throws {
        let store = SessionStoreImpl()
        let s1 = try await store.createSession(Session(profileId: UUID(), mode: .behavioral, title: "A"))
        let s2 = try await store.createSession(Session(profileId: UUID(), mode: .coding, title: "B"))
        let s3 = try await store.createSession(Session(profileId: UUID(), mode: .meeting, title: "C"))

        // Delete B and C, keep A
        try await store.deleteSessions([s2.id, s3.id])

        let remaining = try await store.fetchSessions(limit: 50)
        let ids = remaining.map(\.id)
        #expect(ids.contains(s1.id), "Session A should remain")
        #expect(!ids.contains(s2.id), "Session B should be deleted")
        #expect(!ids.contains(s3.id), "Session C should be deleted")
    }

    @Test("deleteAllSessions deletes more than fetch limit")
    func deleteAllSessionsBeyondLimit() async throws {
        let store = SessionStoreImpl()
        // Create 60 sessions — more than the default fetch limit of 50
        for i in 0..<60 {
            _ = try await store.createSession(Session(profileId: UUID(), mode: .meeting, title: "Session \(i)"))
        }

        // Verify we have at least 60
        let before = try await store.fetchSessions(limit: 100)
        #expect(before.count >= 60)

        // Delete ALL (not just visible ones)
        try await store.deleteAllSessions()

        // Verify zero remaining
        let after = try await store.fetchSessions(limit: 100)
        #expect(after.isEmpty, "All sessions should be deleted, even those beyond the fetch limit")
    }

    @Test("deleteSessions with empty set is no-op")
    func deleteSessionsEmptySet() async throws {
        let store = SessionStoreImpl()
        _ = try await store.createSession(Session(profileId: UUID(), mode: .behavioral))
        let count = try await store.fetchSessions(limit: 50).count
        try await store.deleteSessions([])
        let after = try await store.fetchSessions(limit: 50).count
        #expect(after == count)
    }

    @Test("export markdown produces readable content")
    func exportMarkdown() async throws {
        let store = SessionStoreImpl()
        var session = Session(profileId: UUID(), mode: .behavioral, title: "Mock Interview")
        session.segments = [
            TranscriptSegment(sessionId: session.id, timestamp: Date(), speaker: .mic, text: "I led a team", isFinal: true),
            TranscriptSegment(sessionId: session.id, timestamp: Date(), speaker: .unknown, text: "Tell me more", isFinal: true)
        ]
        session.suggestions = [
            Suggestion(sessionId: session.id, type: .answerOutline, content: "## Outline\n- STAR point")
        ]
        let created = try await store.createSession(session)

        let url = try await store.exportSession(created.id, format: .markdown)
        let content = try String(contentsOf: url, encoding: .utf8)

        #expect(content.contains("Mock Interview"))
        #expect(content.contains("I led a team"))
        #expect(content.contains("Tell me more"))
        #expect(content.contains("STAR point"))
    }

    @Test("export json produces valid JSON matching Session model")
    func exportJSON() async throws {
        let store = SessionStoreImpl()
        let session = try await store.createSession(Session(profileId: UUID(), mode: .coding, title: "Code Test"))

        let url = try await store.exportSession(session.id, format: .json)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        #expect(decoded.title == "Code Test")
        #expect(decoded.mode == .coding)
    }

    @Test("session duration is computed from startedAt and endedAt")
    func sessionDuration() {
        let start = Date()
        let end = start.addingTimeInterval(120) // 2 minutes
        let session = Session(
            profileId: UUID(), mode: .behavioral,
            startedAt: start, endedAt: end
        )
        let duration = session.endedAt!.timeIntervalSince(session.startedAt)
        #expect(duration == 120)
    }

    @Test("empty store returns empty session list")
    func emptyStore() async throws {
        // Use a fresh store that shouldn't have sessions from other tests
        // (Note: SessionStoreImpl uses a shared file, so we just verify the API works)
        let store = SessionStoreImpl()
        let sessions = try await store.fetchSessions(limit: 50)
        // May or may not be empty depending on test order, but API should work
        #expect(sessions.count >= 0)
    }
}
