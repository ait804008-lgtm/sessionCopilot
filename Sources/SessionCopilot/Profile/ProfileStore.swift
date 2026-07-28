import Foundation

/// Manages user profiles. Persists to a local JSON file.
/// ponytail: JSON file store; migrate to SQLite in Task 13 if needed.
@MainActor
public final class ProfileStore: ObservableObject {
    @Published public var profiles: [Profile] = []
    private let fileURL: URL

    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SessionCopilot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("profiles.json")
        load()
    }

    // MARK: - CRUD

    public func add(_ profile: Profile) {
        profiles.append(profile)
        save()
    }

    public func update(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
            profiles[i].updatedAt = Date()
            save()
        }
    }

    public func remove(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    /// Remove all profiles matching the given set of IDs.
    public func removeAll(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        profiles.removeAll { ids.contains($0.id) }
        save()
    }

    public func get(id: UUID) -> Profile? {
        profiles.first { $0.id == id }
    }

    // MARK: - Import

    /// Import resume text from a file URL.
    public func importResume(url: URL, into profile: inout Profile) throws {
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            // Basic PDF text extraction via PDFKit (available on macOS)
            // ponytail: simplified import; full PDF parsing if quality matters
            text = try extractPDFText(url: url)
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        profile.resumeText = text
        profile.updatedAt = Date()
    }

    private func extractPDFText(url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw ProfileError.pdfReadFailed
        }
        return (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: fileURL)
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        }
    }
}

enum ProfileError: Error {
    case pdfReadFailed
}

// MARK: - PDFKit import

import PDFKit
