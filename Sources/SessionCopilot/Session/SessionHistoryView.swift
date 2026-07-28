import SwiftUI

/// Window showing past sessions with date, mode, duration, and counts.
/// Supports multi-select deletion and bulk delete-all.
struct SessionHistoryView: View {
    let store: SessionStoreImpl
    @State private var sessions: [Session] = []
    @State private var selectedIds: Set<UUID> = []
    @State private var selectedSession: Session?
    @State private var showDeleteAllConfirmation = false
    @State private var showDeleteSelectedConfirmation = false

    private var allSelected: Bool {
        !sessions.isEmpty && selectedIds.count == sessions.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No sessions yet")
                            .font(.headline)
                        Text("Start a session to see it here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedIds) {
                        ForEach(sessions) { session in
                            SessionRow(session: session, isSelected: selectedIds.contains(session.id)) {
                                selectedSession = session
                            }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if selectedIds.contains(session.id) {
                                        selectedIds.remove(session.id)
                                    } else {
                                        selectedIds.insert(session.id)
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Session History")
            .frame(minWidth: 550, minHeight: 350)
            .toolbar {
                if !sessions.isEmpty {
                    Button(action: toggleSelectAll) {
                        Text(allSelected ? "Deselect All" : "Select All")
                    }
                    if !selectedIds.isEmpty {
                        Button("Delete Selected (\(selectedIds.count))") {
                            showDeleteSelectedConfirmation = true
                        }
                        .foregroundColor(.red)
                    }
                    Button("Refresh") { loadSessions() }
                    Button("Delete All") {
                        showDeleteAllConfirmation = true
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .onAppear { loadSessions() }
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session, store: store) {
                loadSessions()
                selectedSession = nil
            }
        }
        .alert("Delete Selected Sessions?", isPresented: $showDeleteSelectedConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(selectedIds.count) Sessions", role: .destructive) {
                let ids = selectedIds
                Task {
                    try? await store.deleteSessions(ids)
                    selectedIds.removeAll()
                    loadSessions()
                }
            }
        } message: {
            Text("This will permanently delete \(selectedIds.count) selected sessions. This action cannot be undone.")
        }
        .alert("Delete All Sessions?", isPresented: $showDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                Task {
                    try? await store.deleteAllSessions()
                    selectedIds.removeAll()
                    loadSessions()
                }
            }
        } message: {
            Text("This will permanently delete all \(sessions.count) sessions. This action cannot be undone.")
        }
    }

    private func loadSessions() {
        Task {
            sessions = try await store.fetchSessions(limit: 50)
        }
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedIds.removeAll()
        } else {
            selectedIds = Set(sessions.map(\.id))
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    var isSelected: Bool = false
    var onView: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? "Untitled Session")
                    .font(.body)
                HStack(spacing: 8) {
                    Label(session.mode.rawValue.capitalized, systemImage: modeIcon)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(durationText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Label("\(session.segments.count)", systemImage: "text.bubble")
                        .font(.caption)
                    Label("\(session.suggestions.count)", systemImage: "lightbulb")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            statusBadge

            if let onView {
                Button(action: onView) {
                    Image(systemName: "info.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("View session details")
            }
        }
        .padding(.vertical, 4)
    }

    private var modeIcon: String {
        switch session.mode {
        case .behavioral: return "person.wave.2"
        case .technicalVerbal: return "gearshape.2"
        case .meeting: return "person.3"
        case .coding: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private var durationText: String {
        guard let ended = session.endedAt else { return "In progress" }
        let duration = ended.timeIntervalSince(session.startedAt)
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }

    private var statusBadge: some View {
        let (color, text): (Color, String) = {
            switch session.status {
            case .live: return (.red, "Live")
            case .done: return (.green, "Done")
            case .preflight: return (.orange, "Preflight")
            case .paused: return (.yellow, "Paused")
            }
        }()
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}
