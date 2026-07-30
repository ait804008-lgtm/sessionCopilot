import Foundation
import AVFoundation
import Testing
@testable import SessionCopilot

// MARK: - AudioStorage Tests

@Suite("AudioStorage") struct AudioStorageTests {

    @Test("AudioStorage init with default directory points to Application Support")
    func defaultDirectory() {
        let storage = AudioStorage()
        let path = storage.directory.path
        #expect(path.contains("SessionCopilot"))
        #expect(path.contains("audio"))
    }

    @Test("AudioStorage init with custom directory uses it")
    func customDirectory() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString)")
        let storage = AudioStorage(directory: tmp)
        #expect(storage.directory == tmp)
    }

    @Test("ensureDirectory creates the directory")
    func ensureDirectoryCreates() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString)")
        let storage = AudioStorage(directory: tmp)
        try storage.ensureDirectory()
        #expect(FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test("ensureDirectory is idempotent") throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString)")
        let storage = AudioStorage(directory: tmp)
        try storage.ensureDirectory()
        try storage.ensureDirectory()  // should not throw
        #expect(FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test("url(forSessionId:) returns URL with UUID and .wav extension")
    func urlForSession() {
        let storage = AudioStorage()
        let id = UUID()
        let url = storage.url(forSessionId: id)
        #expect(url.lastPathComponent == "\(id.uuidString).wav")
    }

    @Test("relativeFilename returns UUID.wav")
    func relativeFilename() {
        let storage = AudioStorage()
        let id = UUID()
        let filename = storage.relativeFilename(forSessionId: id)
        #expect(filename == "\(id.uuidString).wav")
    }

    @Test("resolve returns nil for nil path")
    func resolveNil() {
        let storage = AudioStorage()
        #expect(storage.resolve(nil) == nil)
    }

    @Test("resolve returns nil for empty path")
    func resolveEmpty() {
        let storage = AudioStorage()
        #expect(storage.resolve("") == nil)
    }

    @Test("resolve returns nil for non-existent file")
    func resolveNonExistent() {
        let storage = AudioStorage()
        #expect(storage.resolve("nonexistent.wav") == nil)
    }

    @Test("resolve returns URL for existing file") throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString)")
        let storage = AudioStorage(directory: tmp)
        try storage.ensureDirectory()
        let filename = "test.wav"
        let url = tmp.appendingPathComponent(filename)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        #expect(storage.resolve(filename) == url)
    }

    @Test("delete is safe for nil path")
    func deleteNilSafe() {
        let storage = AudioStorage()
        storage.delete(audioFilePath: nil)
        // No crash = pass.
    }

    @Test("delete is safe for non-existent file")
    func deleteNonExistentSafe() {
        let storage = AudioStorage()
        storage.delete(audioFilePath: "nonexistent.wav")
        // No crash = pass.
    }

    @Test("delete removes existing file") throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio-\(UUID().uuidString)")
        let storage = AudioStorage(directory: tmp)
        try storage.ensureDirectory()
        let filename = "to-delete.wav"
        let url = tmp.appendingPathComponent(filename)
        try Data([0x00]).write(to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        storage.delete(audioFilePath: filename)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

// MARK: - AudioRecorder Tests

@Suite("AudioRecorder") struct AudioRecorderTests {

    @Test("WAV header for 0 bytes is 44 bytes")
    func headerSizeZero() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        #expect(header.count == 44)
    }

    @Test("WAV header for non-zero bytes is 44 bytes")
    func headerSizeNonZero() {
        let header = AudioRecorder.wavHeader(dataBytes: 1024)
        #expect(header.count == 44)
    }

    @Test("WAV header starts with RIFF")
    func headerRIFF() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        #expect(header[0] == 0x52)  // 'R'
        #expect(header[1] == 0x49)  // 'I'
        #expect(header[2] == 0x46)  // 'F'
        #expect(header[3] == 0x46)  // 'F'
    }

    @Test("WAV header has WAVE at offset 8")
    func headerWAVE() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        #expect(header[8] == 0x57)  // 'W'
        #expect(header[9] == 0x41)  // 'A'
        #expect(header[10] == 0x56)  // 'V'
        #expect(header[11] == 0x45)  // 'E'
    }

    @Test("WAV header has 'fmt ' at offset 12")
    func headerFmtChunk() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        #expect(header[12] == 0x66)  // 'f'
        #expect(header[13] == 0x6D)  // 'm'
        #expect(header[14] == 0x74)  // 't'
        #expect(header[15] == 0x20)  // ' '
    }

    @Test("WAV header has 'data' at offset 36")
    func headerDataChunk() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        #expect(header[36] == 0x64)  // 'd'
        #expect(header[37] == 0x61)  // 'a'
        #expect(header[38] == 0x74)  // 't'
        #expect(header[39] == 0x61)  // 'a'
    }

    @Test("WAV header encodes correct sample rate")
    func headerSampleRate() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        // 16000 in little-endian UInt32 = 0x3E80
        #expect(header[24] == 0x80)
        #expect(header[25] == 0x3E)
        #expect(header[26] == 0x00)
        #expect(header[27] == 0x00)
    }

    @Test("WAV header encodes correct channels")
    func headerChannels() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        // 1 channel in little-endian UInt16
        #expect(header[22] == 0x01)
        #expect(header[23] == 0x00)
    }

    @Test("WAV header encodes correct bits per sample")
    func headerBitsPerSample() {
        let header = AudioRecorder.wavHeader(dataBytes: 0)
        // 16 bits in little-endian UInt16
        #expect(header[34] == 0x10)
        #expect(header[35] == 0x00)
    }

    @Test("WAV header encodes correct data size")
    func headerDataSize() {
        let header = AudioRecorder.wavHeader(dataBytes: 1024)
        // 1024 in little-endian UInt32 = 0x400
        #expect(header[40] == 0x00)
        #expect(header[41] == 0x04)
        #expect(header[42] == 0x00)
        #expect(header[43] == 0x00)
    }

    @Test("WAV header encodes correct RIFF size")
    func headerRiffSize() {
        let dataBytes: UInt32 = 1024
        let header = AudioRecorder.wavHeader(dataBytes: dataBytes)
        // RIFF size = 4 + 8 + dataBytes + 8 = 4 + 8 + 1024 + 8 = 1044
        // 1044 in little-endian = 0x414
        #expect(header[4] == 0x14)
        #expect(header[5] == 0x04)
        #expect(header[6] == 0x00)
        #expect(header[7] == 0x00)
    }

    @Test("Init creates valid file with empty data chunk")
    func initCreatesFile() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()
        try recorder.close()

        #expect(FileManager.default.fileExists(atPath: tmp.path))

        // Verify the file is a valid WAV with 0 data bytes.
        let data = try Data(contentsOf: tmp)
        #expect(data.count == 44)
        #expect(data[0] == 0x52)  // 'R'
        // Data chunk size should be 0.
        #expect(data[40] == 0x00)
        #expect(data[41] == 0x00)
        #expect(data[42] == 0x00)
        #expect(data[43] == 0x00)

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Append writes samples and updates data size")
    func appendUpdatesSize() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()

        // Append 100 Int16 samples (200 bytes).
        var samples = [Int16](repeating: 0, count: 100)
        let data = Data(bytes: &samples, count: samples.count * 2)
        recorder.append(data)
        try recorder.close()

        let fileData = try Data(contentsOf: tmp)
        // 44 byte header + 200 bytes data = 244
        #expect(fileData.count == 244)
        // Data chunk size at offset 40 should be 200 in little-endian.
        #expect(fileData[40] == 0xC8)
        #expect(fileData[41] == 0x00)
        // RIFF size at offset 4 should be 4 + 8 + 200 + 8 = 220 = 0xDC.
        #expect(fileData[4] == 0xDC)
        #expect(fileData[5] == 0x00)

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Multiple appends accumulate correctly")
    func multipleAppends() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()

        // Append 50 Int16 samples three times = 150 samples total.
        for _ in 0..<3 {
            var samples = [Int16](repeating: 0, count: 50)
            let data = Data(bytes: &samples, count: samples.count * 2)
            recorder.append(data)
        }
        try recorder.close()

        let fileData = try Data(contentsOf: tmp)
        // 44 byte header + 300 bytes data = 344
        #expect(fileData.count == 344)
        // Data chunk size = 300 = 0x12C
        #expect(fileData[40] == 0x2C)
        #expect(fileData[41] == 0x01)

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Append drops trailing odd byte")
    func dropsOddByte() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()

        // 5 bytes = 2 Int16 samples + 1 trailing byte.
        // The recorder should drop the trailing byte.
        recorder.append(Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        try recorder.close()

        let fileData = try Data(contentsOf: tmp)
        // 44 header + 4 data bytes = 48.
        #expect(fileData.count == 48)
        #expect(fileData[40] == 0x04)  // data size = 4

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Append after close is a no-op")
    func appendAfterClose() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()
        try recorder.close()

        // Append after close should be silently ignored.
        var samples = [Int16](repeating: 0, count: 100)
        let data = Data(bytes: &samples, count: samples.count * 2)
        recorder.append(data)

        let fileData = try Data(contentsOf: tmp)
        // File should still be just the header (44 bytes).
        #expect(fileData.count == 44)

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Empty data append is a no-op")
    func emptyAppend() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()
        recorder.append(Data())
        try recorder.close()

        let fileData = try Data(contentsOf: tmp)
        #expect(fileData.count == 44)  // header only, no data
        #expect(fileData[40] == 0x00)  // data size = 0

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Close is idempotent")
    func closeIdempotent() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()
        try recorder.close()
        try recorder.close()  // should not throw

        try? FileManager.default.removeItem(at: tmp)
    }

    @Test("Generated WAV is playable by AVAudioPlayer")
    @MainActor
    func playableByAVAudioPlayer() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rec-\(UUID().uuidString).wav")
        let recorder = try AudioRecorder(fileURL: tmp)
        recorder.startRecording()

        // Append 1 second of 440Hz sine wave at 16kHz.
        // (Silence would also work; we use a sine for realism.)
        var samples: [Int16] = []
        let sampleRate = 16_000.0
        let frequency = 440.0
        for i in 0..<Int(sampleRate) {
            let t = Double(i) / sampleRate
            let v = sin(2.0 * .pi * frequency * t) * 0.5
            samples.append(Int16(v * Double(Int16.max)))
        }
        let data = Data(bytes: &samples, count: samples.count * 2)
        recorder.append(data)
        try recorder.close()

        // Verify AVAudioPlayer can open and reports correct duration.
        let player = try AVAudioPlayer(contentsOf: tmp)
        #expect(player.duration > 0.99 && player.duration < 1.01)
        // 1 second at 16kHz Int16 mono = 32,000 bytes of data.
        // duration = 32000 / (16000 * 1 * 16/8) = 1.0

        try? FileManager.default.removeItem(at: tmp)
    }
}

// MARK: - Session.audioFilePath Tests

@Suite("Session.audioFilePath") struct SessionAudioFilePathTests {

    @Test("audioFilePath defaults to nil")
    func defaultNil() {
        let session = Session(profileId: UUID(), mode: .behavioral)
        #expect(session.audioFilePath == nil)
    }

    @Test("audioFilePath can be set in init")
    func setInInit() {
        let session = Session(
            profileId: UUID(),
            mode: .behavioral,
            audioFilePath: "abc.wav"
        )
        #expect(session.audioFilePath == "abc.wav")
    }

    @Test("audioFilePath is Codable")
    func codable() throws {
        let session = Session(
            profileId: UUID(),
            mode: .behavioral,
            audioFilePath: "test.wav"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)
        #expect(decoded.audioFilePath == "test.wav")
    }

    @Test("Old session JSON without audioFilePath decodes with nil")
    func backwardCompat() throws {
        // Manually construct JSON without the audioFilePath key.
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "profileId": "12345678-1234-1234-1234-123456789013",
            "mode": "behavioral",
            "status": "done",
            "startedAt": 0,
            "endedAt": null,
            "segments": [],
            "suggestions": [],
            "metadata": {}
        }
        """
        let data = json.data(using: .utf8)!
        let session = try JSONDecoder().decode(Session.self, from: data)
        #expect(session.audioFilePath == nil)
    }
}
