import Foundation
import os

/// Resolves audio file paths and manages cleanup.
///
/// Audio files live at `~/Library/Application Support/SessionCopilot/audio/`.
/// Filenames are `<session-uuid>.wav`. Only the relative filename is
/// stored on `Session.audioFilePath` so the directory can be relocated
/// without breaking stored sessions.
public struct AudioStorage: Sendable {
    /// The base directory for audio files. Created lazily by
    /// `ensureDirectory()`.
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = appSupport
                .appendingPathComponent("SessionCopilot")
                .appendingPathComponent("audio")
        }
    }

    /// Create the audio directory if it doesn't exist. Safe to call
    /// multiple times.
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    /// Absolute URL for a session's audio file.
    public func url(forSessionId id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Relative filename (e.g. "ABC-123.wav") for storage on
    /// `Session.audioFilePath`. Includes the `.wav` extension.
    public func relativeFilename(forSessionId id: UUID) -> String {
        return "\(id.uuidString).wav"
    }

    /// Resolve a stored `audioFilePath` to an absolute URL.
    /// Returns nil if the path is nil or the file doesn't exist.
    public func resolve(_ audioFilePath: String?) -> URL? {
        guard let path = audioFilePath, !path.isEmpty else { return nil }
        let url = directory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete the audio file for a session. Safe to call if the file
    /// doesn't exist or `audioFilePath` is nil.
    public func delete(audioFilePath: String?) {
        guard let path = audioFilePath, !path.isEmpty else { return }
        let url = directory.appendingPathComponent(path)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                Log.recording.info("Deleted audio file: \(path, privacy: .public)")
            }
        } catch {
            Log.recording.error("Failed to delete audio file \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Delete audio files older than `days`. Used by retention.
    /// Mirrors `SessionStoreImpl.deleteSessionsOlderThan(days:)`.
    @discardableResult
    public func deleteOlderThan(days: Int) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return 0 }

        var deleted = 0
        for url in entries where url.pathExtension == "wav" {
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let mod = attrs?.contentModificationDate, mod < cutoff {
                try? fm.removeItem(at: url)
                deleted += 1
            }
        }
        if deleted > 0 {
            Log.recording.info("Deleted \(deleted, privacy: .public) audio files older than \(days, privacy: .public) days")
        }
        return deleted
    }
}
