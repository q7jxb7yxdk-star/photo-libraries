import AVFoundation
import Combine
import Foundation

/// Keeps music local to one Memories slideshow. A new playback picks a different
/// bundled track when possible, then loops it until the slideshow closes.
@MainActor
final class MemorySoundtrackPlayer: ObservableObject {
    @Published private(set) var errorMessage: String?

    private static let trackNames = [
        "memory-warmth", "memory-dream", "memory-journey", "memory-stillness"
    ]

    private var player: AVAudioPlayer?
    private var previousTrackName: String?

    func startRandom() {
        stop()
        errorMessage = nil
        let available = Self.trackNames.compactMap { name -> (String, URL)? in
            let url = Bundle.main.url(forResource: name, withExtension: "caf")
                ?? Bundle.main.url(
                    forResource: name, withExtension: "caf",
                    subdirectory: "MemoryMusic"
                )
                ?? Bundle.main.url(
                    forResource: name, withExtension: "caf",
                    subdirectory: "Resources/MemoryMusic"
                )
            return url.map { (name, $0) }
        }
        guard !available.isEmpty else {
            errorMessage = "Background music is unavailable"
            return
        }
        let alternatives = available.filter { $0.0 != previousTrackName }
        guard let choice = (alternatives.isEmpty ? available : alternatives).randomElement() else {
            return
        }
        do {
            let loaded = try AVAudioPlayer(contentsOf: choice.1)
            loaded.numberOfLoops = -1
            loaded.volume = 0.45
            loaded.prepareToPlay()
            guard loaded.play() else {
                errorMessage = "Background music could not start"
                return
            }
            player = loaded
            previousTrackName = choice.0
        } catch {
            errorMessage = "Background music could not start"
        }
    }

    func pause() {
        player?.pause()
    }

    func resume() {
        guard let player, !player.isPlaying else { return }
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }
}
