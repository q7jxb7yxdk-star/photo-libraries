import Combine
import SwiftUI

@MainActor
private final class MemoriesViewModel: ObservableObject {
    @Published private(set) var memories: [PhotoMemory] = []
    @Published private(set) var systemAssets: [String: PhotoAssetSummary] = [:]
    @Published private(set) var registeredItems: [String: PhotosAutomationMediaItem] = [:]
    @Published private(set) var isGrouping = false

    private var generation = UUID()
    private var groupingTask: Task<Void, Never>?

    func refresh(
        registry: LibraryRegistry,
        store: LibraryPreviewStore,
        systemModel: SystemPhotoLibraryViewModel,
        searchModel: UnifiedSearchViewModel
    ) {
        groupingTask?.cancel()
        generation = UUID()
        let currentGeneration = generation
        var input: [MemoryPhoto] = []
        var system: [String: PhotoAssetSummary] = [:]
        var registered: [String: PhotosAutomationMediaItem] = [:]

        for library in registry.libraries {
            let libraryID = library.id
            let libraryName = library.descriptor.metadata.displayName
            if library.descriptor.kind.isSystemPhotoLibrary {
                guard systemModel.authorization.permitsReading else { continue }
                for asset in systemModel.assets {
                    guard let date = asset.creationDate, !asset.isHidden else { continue }
                    let place = searchModel.place(libraryID: libraryID, assetID: asset.id)
                    let id = UnifiedSearchDocument.identifier(
                        libraryID: libraryID, assetID: asset.id
                    )
                    system[id] = asset
                    input.append(MemoryPhoto(
                        libraryID: libraryID, assetID: asset.id,
                        libraryName: libraryName, date: date,
                        coordinate: asset.coordinate,
                        placeName: place?.city, regionName: place?.country,
                        isFavorite: asset.isFavorite,
                        pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                        isVideo: asset.mediaType == "video"
                    ))
                }
            } else if let manifest = store.manifest(for: libraryID) {
                for item in manifest.items {
                    guard let date = item.captureDate else { continue }
                    let place = searchModel.place(libraryID: libraryID, assetID: item.id)
                    let id = UnifiedSearchDocument.identifier(
                        libraryID: libraryID, assetID: item.id
                    )
                    registered[id] = item
                    input.append(MemoryPhoto(
                        libraryID: libraryID, assetID: item.id,
                        libraryName: libraryName, date: date,
                        coordinate: UnifiedSearchViewModel.coordinate(
                            from: item.locationDescription
                        ),
                        placeName: place?.city, regionName: place?.country,
                        isFavorite: item.isFavorite,
                        pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
                        isVideo: UnifiedSearchViewModel.mediaType(for: item.filename) == "video"
                    ))
                }
            }
        }
        systemAssets = system
        registeredItems = registered
        isGrouping = true
        let photos = input
        groupingTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                MemoryGenerator.generate(from: photos, now: Date())
            }.value
            guard !Task.isCancelled,
                  let self, self.generation == currentGeneration else { return }
            self.memories = result
            self.isGrouping = false
            self.groupingTask = nil
        }
    }

    func cancel() {
        groupingTask?.cancel()
        groupingTask = nil
        isGrouping = false
    }
}

struct MemoriesView: View {
    @Environment(\.displayScale) private var displayScale
    @ObservedObject var registry: LibraryRegistry
    @ObservedObject var store: LibraryPreviewStore
    @ObservedObject var systemModel: SystemPhotoLibraryViewModel
    @ObservedObject var searchModel: UnifiedSearchViewModel

    @StateObject private var model = MemoriesViewModel()
    @StateObject private var soundtrack = MemorySoundtrackPlayer()
    @State private var selectedMemoryID: String?
    @State private var selectedPhoto: MemoryPhoto?
    @State private var slideshowMemoryID: String?
    @State private var slideshowIndex = 0
    @State private var slideTask: Task<Void, Never>?
    @State private var pendingAdvanceID: String?
    @State private var photoRemainingSeconds: TimeInterval = 2
    @State private var photoTimerStartedAt: Date?
    @State private var isSlideshowPaused = false
    @State private var showsPauseButton = false
    @State private var pauseZoneHovered = false

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 18)]
    private let photoColumns = [GridItem(.adaptive(minimum: 150), spacing: 3)]

    private var selectedMemory: PhotoMemory? {
        model.memories.first { $0.id == selectedMemoryID }
    }

    private var slideshowPhoto: MemoryPhoto? {
        guard let memory = selectedMemory, memory.id == slideshowMemoryID else { return nil }
        let photos = visiblePhotos(in: memory)
        return photos.indices.contains(slideshowIndex) ? photos[slideshowIndex] : nil
    }

    private var listedMemories: [PhotoMemory] {
        model.memories
    }

    var body: some View {
        Group {
            if let memory = selectedMemory {
                detail(memory)
            } else {
                overview
            }
        }
        .navigationTitle(selectedMemory.map { title(for: $0) } ?? "Memories")
        .navigationSubtitle(selectedMemory.map { subtitle(for: $0) } ?? "")
        .background {
            PhotoViewerWindowPresenter(
                isPresented: selectedMemory != nil && (selectedPhoto != nil || slideshowPhoto != nil),
                onEscape: {
                    if slideshowMemoryID != nil { stopSlideshow() }
                    else { selectedPhoto = nil }
                },
                onPrevious: slideshowMemoryID != nil
                    ? { moveSlideshow(by: -1) }
                    : selectedPhoto.flatMap { adjacentPhoto(to: $0, offset: -1) }.map { previous in
                        { selectedPhoto = previous }
                    },
                onNext: slideshowMemoryID != nil
                    ? { moveSlideshow(by: 1) }
                    : selectedPhoto.flatMap { adjacentPhoto(to: $0, offset: 1) }.map { next in
                        { selectedPhoto = next }
                    },
                onPlayPause: slideshowMemoryID != nil ? { toggleSlideshowPause() } : nil
            ) {
                if let slideshowPhoto {
                    expandedSlideshowPhoto(slideshowPhoto)
                } else if let selectedPhoto, selectedMemory != nil {
                    expandedPhoto(selectedPhoto)
                        .id(selectedPhoto.id)
                }
            }
        }
        .toolbar {
            if let selectedMemory {
                ToolbarItem(placement: .navigation) {
                    Button("Back to Memories", systemImage: "arrow.left") {
                        stopSlideshow()
                        selectedPhoto = nil
                        selectedMemoryID = nil
                    }
                    .help("Back to Memories")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button("Play Memory", systemImage: "play.fill") {
                        startSlideshow(selectedMemory)
                    }
                    .disabled(visiblePhotos(in: selectedMemory).isEmpty)
                }
            }
        }
        .onAppear(perform: refresh)
        .onDisappear {
            model.cancel()
            stopSlideshow()
        }
        .onChange(of: selectedMemory?.id) { _, newID in
            if slideshowMemoryID != nil && newID != slideshowMemoryID { stopSlideshow() }
        }
        .onReceive(systemModel.$assets.dropFirst().debounce(
            for: .milliseconds(200), scheduler: RunLoop.main
        )) { _ in refresh() }
        .onReceive(store.$manifests.dropFirst().debounce(
            for: .milliseconds(200), scheduler: RunLoop.main
        )) { _ in refresh() }
        .onReceive(registry.$descriptors.dropFirst()) { _ in refresh() }
        .onReceive(searchModel.$placesByDocumentID.dropFirst().debounce(
            for: .milliseconds(400), scheduler: RunLoop.main
        )) { _ in refresh() }
    }

    private var overview: some View {
        Group {
            if model.isGrouping && model.memories.isEmpty {
                ProgressView("Finding memories…")
            } else if listedMemories.isEmpty {
                ContentUnavailableView(
                    "No Memories Yet",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Memories appear when registered libraries contain enough dated photos. Try synchronizing a library.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(listedMemories) { memory in
                            Button {
                                selectedMemoryID = memory.id
                            } label: {
                                memoryCard(memory)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private func memoryCard(_ memory: PhotoMemory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cover = coverPhoto(in: memory) {
                thumbnail(cover, pixelSize: 700)
                    .frame(height: 190)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView("No Included Photos", systemImage: "photo")
                    .frame(height: 190)
            }
            Text(title(for: memory)).font(.headline).lineLimit(1)
            Text(subtitle(for: memory)).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ memory: PhotoMemory) -> some View {
        VStack(spacing: 0) {
            let offline = unavailableLibraryNames(in: memory)
            if !offline.isEmpty {
                Label(
                    "Some source libraries are unavailable: \(offline.joined(separator: ", "))",
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            Divider()
            ScrollView {
                if visiblePhotos(in: memory).isEmpty {
                    ContentUnavailableView(
                        "No Included Photos", systemImage: "photo",
                        description: Text("No photos are available in this memory.")
                    )
                    .padding(24)
                } else {
                    LazyVGrid(columns: photoColumns, spacing: 3) {
                        ForEach(visiblePhotos(in: memory)) { photo in
                            Button { selectedPhoto = photo } label: {
                                thumbnail(photo, pixelSize: 440)
                                    .aspectRatio(1, contentMode: .fit)
                                    .clipped()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(photo.libraryName), \(photo.date.formatted())")
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func adjacentPhoto(to photo: MemoryPhoto, offset: Int) -> MemoryPhoto? {
        guard let selectedMemory else { return nil }
        return PhotoSequence.adjacent(
            in: visiblePhotos(in: selectedMemory), selectedID: photo.id, offset: offset
        )
    }

    private func expandedPhoto(_ photo: MemoryPhoto) -> some View {
        ExpandedPhotoContainer(
            title: photoTitle(photo),
            previous: adjacentPhoto(to: photo, offset: -1).map { previous in
                { selectedPhoto = previous }
            },
            next: adjacentPhoto(to: photo, offset: 1).map { next in
                { selectedPhoto = next }
            },
            close: { selectedPhoto = nil }
        ) {
            viewerPhoto(photo)
        }
    }

    private func expandedSlideshowPhoto(_ photo: MemoryPhoto) -> some View {
        ExpandedPhotoContainer(
            title: photoTitle(photo),
            previous: slideshowIndex > 0 ? { moveSlideshow(by: -1) } : nil,
            next: { moveSlideshow(by: 1) },
            close: stopSlideshow
        ) {
            viewerPhoto(photo, autoAdvance: true)
                .id(photo.id)
        }
        .overlay(alignment: .bottom) {
            if let errorMessage = soundtrack.errorMessage {
                Label(errorMessage, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(18)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                Button {
                    toggleSlideshowPause()
                } label: {
                    Image(systemName: isSlideshowPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .overlay {
                                    Circle().strokeBorder(.white.opacity(0.18))
                                }
                        }
                }
                .buttonStyle(.plain)
                .opacity(showsPauseButton ? 1 : 0)
                .allowsHitTesting(showsPauseButton)
                .accessibilityHidden(!showsPauseButton)
                .accessibilityLabel(isSlideshowPaused ? "Resume Memory" : "Pause Memory")
            }
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
            .onHover { hovering in
                pauseZoneHovered = hovering
                showsPauseButton = hovering || isSlideshowPaused
            }
            .padding(18)
        }
    }

    private func photoTitle(_ photo: MemoryPhoto) -> String {
        if let asset = model.systemAssets[photo.id], !asset.originalFilename.isEmpty {
            return asset.originalFilename
        }
        if let item = model.registeredItems[photo.id] {
            return item.name.isEmpty ? item.filename : item.name
        }
        return photo.date.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func viewerPhoto(_ photo: MemoryPhoto, autoAdvance: Bool = false) -> some View {
        if let asset = model.systemAssets[photo.id] {
            if asset.mediaType == "video" {
                SystemLibraryVideoPlayer(
                    assetID: asset.id,
                    autoPlay: autoAdvance,
                    isPaused: autoAdvance && isSlideshowPaused,
                    onFinished: autoAdvance ? { advanceSlideshow(after: photo.id) } : nil
                )
            } else if asset.isLivePhoto {
                SystemLivePhotoView(
                    assetID: asset.id,
                    imageSize: CGSize(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))
                ) {
                    systemViewerImage(asset)
                }
            } else {
                systemViewerImage(asset)
            }
        } else if let item = model.registeredItems[photo.id] {
            if photo.isVideo {
                RegisteredLibraryVideoPlayer(
                    item: item, libraryID: photo.libraryID, store: store,
                    autoPlay: autoAdvance,
                    isPaused: autoAdvance && isSlideshowPaused,
                    onFinished: autoAdvance ? { advanceSlideshow(after: photo.id) } : nil
                )
            } else if store.isDirectLivePhoto(item.id, libraryID: photo.libraryID),
                      let provider = store.directProvider(for: photo.libraryID) {
                DirectRegisteredLivePhotoView(
                    provider: provider, assetID: item.id,
                    imageSize: CGSize(width: CGFloat(item.pixelWidth), height: CGFloat(item.pixelHeight))
                ) {
                    registeredViewerImage(photo)
                }
            } else if let videoURL = store.livePhotoVideoURL(
                for: item.id, libraryID: photo.libraryID
            ) {
                RegisteredLivePhotoView(
                    videoURL: videoURL,
                    imageSize: CGSize(width: CGFloat(item.pixelWidth), height: CGFloat(item.pixelHeight))
                ) {
                    registeredViewerImage(photo)
                }
            } else {
                registeredViewerImage(photo)
            }
        } else {
            ContentUnavailableView("Photo Unavailable", systemImage: "photo")
        }
    }

    private func systemViewerImage(_ asset: PhotoAssetSummary) -> some View {
        GeometryReader { proxy in
            let targetSize = SystemPhotoLibraryViewModel.viewerTargetSize(
                for: proxy.size, displayScale: displayScale
            )
            Group {
                if let image = systemModel.viewerImages[asset.id]
                    ?? systemModel.thumbnails[asset.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: "\(asset.id):\(Int(targetSize.width))x\(Int(targetSize.height)):g\(systemModel.thumbnailRequestGeneration)") {
                systemModel.requestViewerImage(for: asset, size: targetSize)
            }
        }
        .onDisappear {
            systemModel.cancelViewerImageRequest(for: asset.id)
        }
    }

    private func registeredViewerImage(_ photo: MemoryPhoto) -> some View {
        CachedLibraryThumbnailView(
            store: store, libraryID: photo.libraryID,
            itemID: photo.assetID,
            revision: store.viewerPreviewRevision(
                for: photo.assetID, libraryID: photo.libraryID
            ),
            placeholderSystemImage: "photo",
            hasError: store.manifest(for: photo.libraryID)?.itemErrors[photo.assetID] != nil,
            contentMode: .fit,
            prefersViewerPreview: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func thumbnail(_ photo: MemoryPhoto, pixelSize: CGFloat) -> some View {
        if let asset = model.systemAssets[photo.id] {
            SystemPhotoLibraryThumbnailView(
                model: systemModel, asset: asset,
                targetSize: CGSize(width: pixelSize * displayScale, height: pixelSize * displayScale),
                requestGeneration: systemModel.thumbnailRequestGeneration,
                placeholderSystemImage: photo.isVideo ? "video" : "photo"
            )
            .equatable()
        } else if model.registeredItems[photo.id] != nil {
            let viewerPreview = pixelSize > 1_000
            CachedLibraryThumbnailView(
                store: store, libraryID: photo.libraryID,
                itemID: photo.assetID,
                revision: viewerPreview
                    ? store.viewerPreviewRevision(for: photo.assetID, libraryID: photo.libraryID)
                    : store.thumbnailRevision(for: photo.assetID, libraryID: photo.libraryID),
                placeholderSystemImage: photo.isVideo ? "video" : "photo",
                hasError: store.manifest(for: photo.libraryID)?.itemErrors[photo.assetID] != nil,
                prefersViewerPreview: viewerPreview
            )
            .equatable()
        } else {
            ContentUnavailableView("Photo Unavailable", systemImage: "photo")
        }
    }

    private func visiblePhotos(in memory: PhotoMemory) -> [MemoryPhoto] {
        memory.photos
    }

    private func startSlideshow(_ memory: PhotoMemory) {
        guard !visiblePhotos(in: memory).isEmpty else { return }
        stopSlideshow()
        selectedPhoto = nil
        slideshowIndex = 0
        slideshowMemoryID = memory.id
        pendingAdvanceID = nil
        isSlideshowPaused = false
        showsPauseButton = false
        pauseZoneHovered = false
        soundtrack.startRandom()
        scheduleNextSlide(resetDuration: true)
    }

    private func stopSlideshow() {
        slideTask?.cancel()
        slideTask = nil
        pendingAdvanceID = nil
        photoTimerStartedAt = nil
        slideshowMemoryID = nil
        isSlideshowPaused = false
        showsPauseButton = false
        pauseZoneHovered = false
        soundtrack.stop()
    }

    private func moveSlideshow(by offset: Int) {
        guard let memory = selectedMemory, memory.id == slideshowMemoryID else { return }
        let nextIndex = slideshowIndex + offset
        if nextIndex < 0 { return }
        if nextIndex >= visiblePhotos(in: memory).count {
            stopSlideshow()
            return
        }
        slideshowIndex = nextIndex
        pendingAdvanceID = nil
        scheduleNextSlide(resetDuration: true)
    }

    private func advanceSlideshow(after photoID: String) {
        guard slideshowPhoto?.id == photoID else { return }
        if isSlideshowPaused {
            pendingAdvanceID = photoID
            return
        }
        moveSlideshow(by: 1)
    }

    private func scheduleNextSlide(resetDuration: Bool) {
        slideTask?.cancel()
        slideTask = nil
        photoTimerStartedAt = nil
        if resetDuration { photoRemainingSeconds = 2 }
        guard let photo = slideshowPhoto else {
            stopSlideshow()
            return
        }
        if isPlayableVideo(photo) || isSlideshowPaused {
            soundtrack.pause()
            return
        }
        soundtrack.resume()
        photoTimerStartedAt = Date()
        let remaining = max(0.01, photoRemainingSeconds)
        slideTask = Task {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            advanceSlideshow(after: photo.id)
        }
    }

    private func isPlayableVideo(_ photo: MemoryPhoto) -> Bool {
        photo.isVideo && (model.systemAssets[photo.id] != nil
            || model.registeredItems[photo.id] != nil)
    }

    private func toggleSlideshowPause() {
        if isSlideshowPaused { resumeSlideshow() }
        else { pauseSlideshow() }
    }

    private func pauseSlideshow() {
        guard slideshowMemoryID != nil, !isSlideshowPaused else { return }
        if let photo = slideshowPhoto, !isPlayableVideo(photo),
           let startedAt = photoTimerStartedAt {
            photoRemainingSeconds = max(0, photoRemainingSeconds
                - Date().timeIntervalSince(startedAt))
        }
        slideTask?.cancel()
        slideTask = nil
        photoTimerStartedAt = nil
        isSlideshowPaused = true
        showsPauseButton = true
        soundtrack.pause()
    }

    private func resumeSlideshow() {
        guard slideshowMemoryID != nil, isSlideshowPaused else { return }
        isSlideshowPaused = false
        showsPauseButton = pauseZoneHovered
        if pendingAdvanceID == slideshowPhoto?.id {
            pendingAdvanceID = nil
            moveSlideshow(by: 1)
        } else if let photo = slideshowPhoto, !isPlayableVideo(photo) {
            scheduleNextSlide(resetDuration: false)
        }
    }

    private func coverPhoto(in memory: PhotoMemory) -> MemoryPhoto? {
        let photos = visiblePhotos(in: memory)
        return photos.max {
            let left = ($0.isFavorite ? 1_000_000_000.0 : 0)
                + min(Double($0.pixelWidth) * Double($0.pixelHeight), 100_000_000)
            let right = ($1.isFavorite ? 1_000_000_000.0 : 0)
                + min(Double($1.pixelWidth) * Double($1.pixelHeight), 100_000_000)
            return left < right
        }
    }

    private func title(for memory: PhotoMemory) -> String {
        memory.suggestedTitle
    }

    private func subtitle(for memory: PhotoMemory) -> String {
        "\(memory.dateRange) · \(visiblePhotos(in: memory).count) items"
    }

    private func unavailableLibraryNames(in memory: PhotoMemory) -> [String] {
        let ids = Set(memory.photos.map(\.libraryID))
        return registry.libraries.filter {
            ids.contains($0.id) && $0.availability != .online
        }.map { $0.descriptor.metadata.displayName }
    }

    private func refresh() {
        model.refresh(
            registry: registry, store: store,
            systemModel: systemModel, searchModel: searchModel
        )
    }
}
