import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Retention Enforcement Tests

@Suite("Session Retention") @MainActor struct SessionRetentionTests {

    @Test("deleteSessionsOlderThan removes sessions past retention period")
    func deletesOldSessions() async throws {
        let store = SessionStoreImpl()

        // Create an old session (60 days ago)
        let oldDate = Date().addingTimeInterval(-60 * 24 * 3600) // 60 days ago
        let oldSession = Session(
            profileId: UUID(),
            mode: .behavioral,
            title: "Old Session",
            status: .done,
            startedAt: oldDate,
            endedAt: oldDate.addingTimeInterval(300)
        )
        _ = try await store.createSession(oldSession)

        // Create a recent session
        let recentSession = Session(
            profileId: UUID(),
            mode: .coding,
            title: "Recent Session",
            status: .done
        )
        _ = try await store.createSession(recentSession)

        // Delete sessions older than 30 days
        let deletedCount = try await store.deleteSessionsOlderThan(days: 30)

        #expect(deletedCount >= 1, "Should delete at least the old session")

        // Verify recent session still exists
        let sessions = try await store.fetchSessions(limit: 50)
        #expect(sessions.contains { $0.title == "Recent Session" })
    }

    @Test("deleteSessionsOlderThan with 0 days deletes all done sessions")
    func deleteAllWith0Days() async throws {
        let store = SessionStoreImpl()

        let session = Session(
            profileId: UUID(),
            mode: .behavioral,
            title: "To Delete",
            status: .done,
            startedAt: Date().addingTimeInterval(-10), // 10 seconds ago
            endedAt: Date()
        )
        _ = try await store.createSession(session)

        let deleted = try await store.deleteSessionsOlderThan(days: 0)
        #expect(deleted >= 1)
    }

    @Test("deleteSessionsOlderThan does not delete live sessions")
    func preservesLiveSessions() async throws {
        let store = SessionStoreImpl()

        let oldLiveSession = Session(
            profileId: UUID(),
            mode: .behavioral,
            title: "Old But Live",
            status: .live, // Still live!
            startedAt: Date().addingTimeInterval(-60 * 24 * 3600) // 60 days ago
        )
        _ = try await store.createSession(oldLiveSession)

        let deleted = try await store.deleteSessionsOlderThan(days: 30)
        // The old live session should NOT be deleted
        let sessions = try await store.fetchSessions(limit: 50)
        #expect(sessions.contains { $0.title == "Old But Live" })
    }

    @Test("deleteSessionsOlderThan with 365 days keeps recent sessions")
    func keepsRecentWith365Days() async throws {
        let store = SessionStoreImpl()

        let recent = Session(
            profileId: UUID(),
            mode: .meeting,
            title: "Recent",
            status: .done,
            startedAt: Date()
        )
        _ = try await store.createSession(recent)

        let deleted = try await store.deleteSessionsOlderThan(days: 365)
        let sessions = try await store.fetchSessions(limit: 50)
        #expect(sessions.contains { $0.title == "Recent" })
    }
}
