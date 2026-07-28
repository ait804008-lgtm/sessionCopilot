import SwiftUI
import AVFoundation
import os

/// Audio playback view for a single session's WAV recording.
///
/// Resolves `Session.audioFilePath` against `AudioStorage.directory`,
/// constructs an `AVAudioPlayer`, and exposes play/pause/seek controls
/// plus a timeline slider.
///
/// Used in `SessionDetailView` — shown only when `session.audioFilePath`
/// is non-nil and the file exists on disk.
struct AudioPlaybackView: View {
    let sessionId: UUID
    let audioFilePath: String

    @StateObject private var playerModel = AudioPlayerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: playerModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .onTapGesture {
                        playerModel.togglePlay()
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Audio recording")
                        .font(.headline)
                    Text(formattedDuration)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let err = playerModel.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let duration = playerModel.duration {
                Slider(
                    value: Binding(
                        get: { playerModel.currentTime },
                        set: { newValue in playerModel.seek(to: newValue) }
                    ),
                    in: 0...max(duration, 0.1)
                )
                .disabled(duration == 0)

                HStack {
                    Text(formatTime(playerModel.currentTime))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            playerModel.load(audioFilePath: audioFilePath)
        }
        .onDisappear {
            playerModel.stop()
        }
    }

    private var formattedDuration: String {
        if let d = playerModel.duration {
            return "\(formatTime(d)) • \(AudioStorage().relativeFilename(forSessionId: sessionId))"
        }
        return AudioStorage().relativeFilename(forSessionId: sessionId)
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// `ObservableObject` wrapper around `AVAudioPlayer` for SwiftUI binding.
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval?
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(audioFilePath: String) {
        let storage = AudioStorage()
        guard let url = storage.resolve(audioFilePath) else {
            errorMessage = "Audio file not found"
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            currentTime = 0
            errorMessage = nil
            Log.recording.info("Loaded audio for playback: \(url.lastPathComponent, privacy: .public), duration=\(p.duration, privacy: .public)s")
        } catch {
            errorMessage = "Failed to load audio: \(error.localizedDescription)"
            Log.recording.error("Audio load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        timer?.invalidate()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }
}
