import Foundation
import AVFoundation
import os

/// Writes 16kHz Int16 mono PCM audio to a WAV file in append mode.
///
/// Used by `SessionEngine` to record each session's audio (mic + system,
/// interleaved by arrival order) for replay in `SessionDetailView`.
///
/// ## File format
///
/// Standard WAV (RIFF/WAVE container, format chunk, data chunk). The
/// file is written incrementally — each `append(_:)` call extends the
/// data chunk and updates the length fields in the header. This means
/// the file is always valid WAV, even if the app crashes mid-session.
///
/// ## Thread safety
///
/// `AudioRecorder` is `@unchecked Sendable`. All public methods take an
/// internal `NSLock` so concurrent `append(_:)` calls from multiple
/// audio sources (mic tap, SCStream callback) are safe.
///
/// ## Storage location
///
/// Files live at `~/Library/Application Support/SessionCopilot/audio/`.
/// The filename is `<session-uuid>.wav`. The relative filename is stored
/// on `Session.audioFilePath` so the directory can be relocated without
/// breaking stored sessions.
public final class AudioRecorder: @unchecked Sendable {
    /// Output format: 16kHz Int16 mono — matches `CaptureEngineImpl.sttFormat`
    /// and `AppleSttClient`'s expected input. Keeps file size modest
    /// (~10 MB / 30 min session) while remaining high-quality for replay.
    public static let sampleRate: Double = 16_000
    public static let channels: UInt32 = 1
    public static let bitsPerSample: UInt32 = 16

    private let fileURL: URL
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var totalDataBytes: UInt32 = 0
    private(set) var isRecording = false

    /// - Parameter fileURL: Absolute URL for the output WAV file. The
    ///   parent directory must exist — call `AudioStorage.ensureDirectory()`
    ///   before constructing the recorder.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL

        // Create the file with an empty WAV header. Subsequent appends
        // extend the data chunk and update lengths in-place.
        let header = Self.wavHeader(dataBytes: 0)
        try header.write(to: fileURL)

        fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle?.synchronize()  // ensure header is on disk
    }

    deinit {
        try? close()
    }

    /// Append PCM Int16 mono samples to the data chunk. Updates the WAV
    /// header lengths in-place so the file is always valid.
    ///
    /// - Parameter data: Raw Int16 PCM samples, little-endian (native
    ///   on Apple Silicon / Intel). `data.count` must be a multiple of 2
    ///   (one Int16 = 2 bytes). Trailing odd bytes are dropped.
    public func append(_ data: Data) {
        // Drop trailing odd byte if present (defensive — should never
        // happen since capture yields full Int16 frames).
        let byteCount = data.count & ~1
        guard byteCount > 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        guard isRecording, let handle = fileHandle else { return }

        // Seek to end of data chunk and write new samples.
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data.prefix(byteCount))
            totalDataBytes += UInt32(byteCount)

            // Update header lengths in-place. RIFF chunk size = 4 + 8 + dataBytes + 8.
            // Data chunk size = dataBytes.
            let riffSize: UInt32 = 4 + 8 + totalDataBytes + 8
            let dataSize: UInt32 = totalDataBytes

            // RIFF size at offset 4 (little-endian UInt32)
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: Self.uint32LE(riffSize))

            // Data chunk size at offset 40 (RIFF=4 + fmt chunk=24 + data chunk header=8 + 4 = 40? Recompute: 4+8+16+4=32, no — let me re-derive.)
            // Standard WAV layout:
            //   0-3:  "RIFF"
            //   4-7:  riffSize (UInt32 LE)
            //   8-11: "WAVE"
            //   12-15: "fmt "
            //   16-19: fmt chunk size (16)
            //   20-21: audio format (1 = PCM)
            //   22-23: channels
            //   24-27: sample rate
            //   28-31: byte rate
            //   32-33: block align
            //   34-35: bits per sample
            //   36-39: "data"
            //   40-43: data chunk size (UInt32 LE)
            //   44+:  PCM data
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Self.uint32LE(dataSize))

            // Seek back to end so the next append extends cleanly.
            try handle.seekToEnd()
        } catch {
            Log.recording.error("AudioRecorder append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Finalize the file: flush, close the handle, mark not recording.
    /// Safe to call multiple times.
    public func close() throws {
        lock.lock()
        defer { lock.unlock() }
        isRecording = false
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        Log.recording.info("Closed audio file: \(self.fileURL.lastPathComponent, privacy: .public), \(self.totalDataBytes, privacy: .public) bytes")
    }

    /// Mark recording as started. Called by `SessionEngine` after init.
    public func startRecording() {
        lock.lock()
        defer { lock.unlock() }
        isRecording = true
        Log.recording.info("Started recording: \(self.fileURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - WAV header

    /// Build a 44-byte canonical WAV header for the given data size.
    /// Used both for the initial empty file and (with the actual size)
    /// for in-place length updates.
    static func wavHeader(dataBytes: UInt32) -> Data {
        var d = Data()
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46])  // "RIFF"
        d.append(contentsOf: Self.uint32LE(4 + 8 + dataBytes + 8))  // riffSize
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45])  // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])  // "fmt "
        d.append(contentsOf: Self.uint32LE(16))  // fmt chunk size
        d.append(contentsOf: Self.uint16LE(1))   // audio format = 1 (PCM)
        d.append(contentsOf: Self.uint16LE(UInt16(channels)))
        d.append(contentsOf: Self.uint32LE(UInt32(sampleRate)))
        let byteRate = UInt32(sampleRate) * channels * bitsPerSample / 8
        d.append(contentsOf: Self.uint32LE(byteRate))
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        d.append(contentsOf: Self.uint16LE(blockAlign))
        d.append(contentsOf: Self.uint16LE(UInt16(bitsPerSample)))
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61])  // "data"
        d.append(contentsOf: Self.uint32LE(dataBytes))
        return d
    }

    private static func uint32LE(_ value: UInt32) -> [UInt8] {
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }

    private static func uint16LE(_ value: UInt16) -> [UInt8] {
        return [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
        ]
    }
}
