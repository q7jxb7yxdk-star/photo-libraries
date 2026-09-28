import AVFoundation
import AVKit
import Combine
import Photos
import PhotosUI
import SwiftUI

/// The badge is the only hover target, matching Photos' one-play-per-entry behavior.
private struct LivePhotoBadge: View {
    let imageSize: CGSize
    let containerSize: CGSize
    let onHoverChange: (Bool) -> Void

    private var inset: CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let scale = min(containerSize.width / imageSize.width,
                        containerSize.height / imageSize.height)
        return CGSize(
            width: max(0, (containerSize.width - imageSize.width * scale) / 2),
            height: max(0, (containerSize.height - imageSize.height * scale) / 2)
        )
    }

    var body: some View {
        Label("Live", systemImage: "livephoto")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(16)
            .offset(x: inset.width, y: inset.height)
            .onHover(perform: onHoverChange)
            .accessibilityLabel("Live Photo. Point here to play once.")
    }
}

struct SystemLivePhotoView<Still: View>: View {
    let assetID: String
    let imageSize: CGSize
    @ViewBuilder let still: () -> Still

    @State private var provider = SystemPhotoLibraryProvider()
    @State private var requestID: PHImageRequestID?
    @State private var livePhoto: PHLivePhoto?
    @State private var loadToken = UUID()
    @State private var playSequence = 0
    @State private var isPlaying = false
    @State private var pointerInsideBadge = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                still()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let livePhoto {
                    NativeLivePhotoView(
                        photo: livePhoto,
                        playSequence: playSequence,
                        onEnded: { isPlaying = false }
                    )
                    .opacity(isPlaying ? 1 : 0)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LivePhotoBadge(imageSize: imageSize, containerSize: proxy.size) { entered in
                        if !entered { pointerInsideBadge = false; return }
                        guard !pointerInsideBadge, !isPlaying else { return }
                        pointerInsideBadge = true
                        isPlaying = true
                        playSequence += 1
                    }
                }
            }
            .task(id: assetID) {
                if let requestID { provider.cancelLivePhotoRequest(requestID) }
                requestID = nil
                livePhoto = nil
                isPlaying = false
                pointerInsideBadge = false
                let token = UUID()
                loadToken = token
                let target = CGSize(
                    width: max(1, proxy.size.width * 2),
                    height: max(1, proxy.size.height * 2)
                )
                requestID = try? provider.requestLivePhoto(
                    for: assetID,
                    targetSize: target
                ) { photo, _ in
                    Task { @MainActor in
                        guard loadToken == token else { return }
                        livePhoto = photo
                        requestID = nil
                    }
                }
            }
        }
        .onDisappear {
            loadToken = UUID()
            if let requestID { provider.cancelLivePhotoRequest(requestID) }
            requestID = nil
            livePhoto = nil
            isPlaying = false
        }
    }
}

private struct NativeLivePhotoView: NSViewRepresentable {
    let photo: PHLivePhoto
    let playSequence: Int
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .aspectFit
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onEnded = onEnded
        if view.livePhoto !== photo { view.livePhoto = photo }
        if context.coordinator.lastPlaySequence != playSequence {
            context.coordinator.lastPlaySequence = playSequence
            if playSequence > 0 { view.startPlayback(with: .full) }
        }
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var lastPlaySequence = 0
        var onEnded: (() -> Void)?

        func livePhotoView(_ livePhotoView: PHLivePhotoView,
                           didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            onEnded?()
        }
    }
}

struct DirectRegisteredLivePhotoView<Still: View>: View {
    let provider: RegisteredPhotoLibraryProvider
    let assetID: String
    let imageSize: CGSize
    @ViewBuilder let still: () -> Still

    @State private var videoURL: URL?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let videoURL {
                RegisteredLivePhotoView(videoURL: videoURL, imageSize: imageSize) {
                    still()
                }
            } else {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        still()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        LivePhotoBadge(imageSize: imageSize, containerSize: proxy.size) { _ in }
                            .help(loadError ?? "Loading Live Photo motion clip")
                    }
                }
            }
        }
        .task(id: assetID) {
            videoURL = nil
            loadError = nil
            do {
                let loaded = try await provider.videoURL(for: assetID, live: true)
                guard !Task.isCancelled else { return }
                videoURL = loaded
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }
}

struct RegisteredLivePhotoView<Still: View>: View {
    let videoURL: URL
    let imageSize: CGSize
    @ViewBuilder let still: () -> Still

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var pointerInsideBadge = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                still()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let player {
                    NativeLiveVideoView(player: player, onEnded: { isPlaying = false })
                        .opacity(isPlaying ? 1 : 0)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LivePhotoBadge(imageSize: imageSize, containerSize: proxy.size) { entered in
                        if !entered { pointerInsideBadge = false; return }
                        guard !pointerInsideBadge, !isPlaying else { return }
                        pointerInsideBadge = true
                        isPlaying = true
                        player.seek(to: .zero)
                        player.play()
                    }
                }
            }
        }
        .task(id: videoURL) {
            player?.pause()
            player = AVPlayer(url: videoURL)
            isPlaying = false
            pointerInsideBadge = false
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            isPlaying = false
        }
    }
}

private struct NativeLiveVideoView: NSViewRepresentable {
    let player: AVPlayer
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        context.coordinator.onEnded = onEnded
        if view.player !== player { view.player = player }
        context.coordinator.observe(player.currentItem)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.observe(nil)
        view.player = nil
    }

    final class Coordinator {
        var onEnded: (() -> Void)?
        private var observedItem: AVPlayerItem?
        private var observer: NSObjectProtocol?

        func observe(_ item: AVPlayerItem?) {
            if observedItem === item { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedItem = item
            guard let item else { return }
            observer = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in self?.onEnded?() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// Playback stays local to the visible viewer. Closing or changing the item
/// releases the player.
struct SystemLibraryVideoPlayer: View {
    let assetID: String
    let autoPlay: Bool
    let isPaused: Bool
    let onFinished: (() -> Void)?

    init(
        assetID: String,
        autoPlay: Bool = false,
        isPaused: Bool = false,
        onFinished: (() -> Void)? = nil
    ) {
        self.assetID = assetID
        self.autoPlay = autoPlay
        self.isPaused = isPaused
        self.onFinished = onFinished
    }

    @State private var player: AVPlayer?
    @State private var requestID: PHImageRequestID?
    @State private var errorMessage: String?
    @State private var loadToken = UUID()
    @State private var desiredPaused = false
    @State private var provider = SystemPhotoLibraryProvider()

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if let errorMessage {
                ContentUnavailableView("Video Unavailable", systemImage: "video.slash", description: Text(errorMessage))
                    .foregroundStyle(.white)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            guard autoPlay, let item = notification.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            onFinished?()
        }
        .onChange(of: isPaused) { _, paused in
            guard autoPlay else { return }
            desiredPaused = paused
            if paused { player?.pause() }
            else { player?.play() }
        }
        .task(id: assetID) {
            desiredPaused = isPaused
            if let requestID { provider.cancelThumbnailRequest(requestID) }
            requestID = nil
            let token = UUID()
            loadToken = token
            player?.pause()
            player = nil
            errorMessage = nil
            do {
                requestID = try provider.requestPlayerItem(for: assetID) { item, _ in
                    Task { @MainActor in
                        guard loadToken == token else { return }
                        if let item {
                            let loadedPlayer = AVPlayer(playerItem: item)
                            player = loadedPlayer
                            if autoPlay && !desiredPaused { loadedPlayer.play() }
                        } else {
                            errorMessage = "The video is not available locally."
                            if autoPlay { onFinished?() }
                        }
                        requestID = nil
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                if autoPlay { onFinished?() }
            }
        }
        .onDisappear {
            loadToken = UUID()
            if let requestID { provider.cancelThumbnailRequest(requestID) }
            requestID = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }
}

struct RegisteredLibraryVideoPlayer: View {
    let item: PhotosAutomationMediaItem
    let libraryID: LibraryID
    @ObservedObject var store: LibraryPreviewStore
    let autoPlay: Bool
    let isPaused: Bool
    let onFinished: (() -> Void)?

    init(
        item: PhotosAutomationMediaItem,
        libraryID: LibraryID,
        store: LibraryPreviewStore,
        autoPlay: Bool = false,
        isPaused: Bool = false,
        onFinished: (() -> Void)? = nil
    ) {
        self.item = item
        self.libraryID = libraryID
        self.store = store
        self.autoPlay = autoPlay
        self.isPaused = isPaused
        self.onFinished = onFinished
    }

    @State private var player: AVPlayer?
    @State private var errorMessage: String?
    @State private var loadToken = UUID()
    @State private var desiredPaused = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if let errorMessage {
                ContentUnavailableView("Video Unavailable", systemImage: "video.slash", description: Text(errorMessage))
                    .foregroundStyle(.white)
            } else {
                ProgressView("Loading video…").controlSize(.large).tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
            guard autoPlay, let item = notification.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            onFinished?()
        }
        .onChange(of: isPaused) { _, paused in
            guard autoPlay else { return }
            desiredPaused = paused
            if paused { player?.pause() }
            else { player?.play() }
        }
        .task(id: "\(libraryID.rawValue):\(item.id):\(store.playbackVideoURL(for: item.id, libraryID: libraryID)?.path ?? "pending")") {
            desiredPaused = isPaused
            let token = UUID()
            loadToken = token
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            errorMessage = nil
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if loadToken == token, player == nil, errorMessage == nil {
                    errorMessage = "The local video is still being prepared. Large files may take longer; keep this preview open or try again later."
                    if autoPlay { onFinished?() }
                }
            }
            if let file = store.playbackVideoURL(for: item.id, libraryID: libraryID) {
                player = AVPlayer(url: file)
                if autoPlay && !desiredPaused { player?.play() }
            } else if let provider = store.directProvider(for: libraryID) {
                do {
                    let loaded = try await provider.videoURL(for: item.id, live: false)
                    guard loadToken == token, !Task.isCancelled else { return }
                    player = AVPlayer(url: loaded)
                    if autoPlay && !desiredPaused { player?.play() }
                } catch {
                    guard loadToken == token, !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                    if autoPlay { onFinished?() }
                }
            } else {
                errorMessage = "This video is not cached yet. Synchronize this library while it is open in Photos, then play it without Photos."
                if autoPlay { onFinished?() }
            }
        }
        .onDisappear {
            loadToken = UUID()
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
            store.directProvider(for: libraryID)?.releaseLocalVideo(for: item.id)
        }
    }
}
