import AppKit
import AVFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct LibraryPreviewManifest: Codable, Sendable {
    let libraryID: LibraryID
    var libraryDisplayName: String
    let totalMediaItemCount: Int
    let indexedAt: Date
    var items: [PhotosAutomationMediaItem]
    /// Optional so manifests written before album indexing remain readable.
    var albums: [PhotosAutomationAlbum]?
    var thumbnailFilenames: [String: String]
    /// Optional for backward compatibility with indexes created before the
    /// expanded viewer had its own higher-resolution app-owned previews.
    var viewerPreviewFilenames: [String: String]?
    /// App-owned MP4 playback copies. Optional for older manifests.
    var playbackVideoFilenames: [String: String]?
    /// Durations of app-owned playback copies. Optional for older manifests.
    var playbackVideoDurations: [String: TimeInterval]?
    /// Confirmed Live Photo motion clips stored outside the source library.
    var livePhotoVideoFilenames: [String: String]?
    /// Includes confirmed ordinary photos, so later syncs do not re-export them.
    var livePhotoCheckedItemIDs: [String]?
    var itemErrors: [String: String]
    var pendingPreviewItemIDs: [String]?
    var pendingMetadataItemIDs: [String]?
    var technicalMetadataByItemID: [String: PhotoTechnicalMetadata]?
    var isComplete: Bool
}

nonisolated struct LibraryIndexPlan: Sendable {
    let itemsNeedingPreviews: [PhotosAutomationMediaItem]
    let itemsNeedingPlaybackVideos: [PhotosAutomationMediaItem]
    let itemsNeedingLivePhotoChecks: [PhotosAutomationMediaItem]
    let addedCount: Int
    let modifiedCount: Int
    let missingPreviewCount: Int
    let removedCount: Int
    let rebuiltCount: Int
}

nonisolated struct LibraryPreviewUpdate: Sendable {
    let itemID: String
    let thumbnailData: Data?
    let viewerPreviewData: Data?
    let technicalMetadata: PhotoTechnicalMetadata?
    let errorDescription: String?
}

nonisolated private struct PreparedPreviewUpdate: Sendable {
    let itemID: String
    let filename: String?
    let viewerFilename: String?
    let technicalMetadata: PhotoTechnicalMetadata?
    let errorDescription: String?
}

private final class CachedThumbnailImage: NSObject {
    let image: NSImage
    let maxPixelSize: Int
    let squarePixelSize: Int

    init(image: NSImage, maxPixelSize: Int, squarePixelSize: Int) {
        self.image = image
        self.maxPixelSize = maxPixelSize
        self.squarePixelSize = squarePixelSize
    }
}

nonisolated enum LibraryIndexPhase: Sendable {
    case readingCatalog
    case generatingPreviews
    case enrichingMetadata
    case generatingPlaybackVideos
    case checkingLivePhotos
}

/// App-owned, persistent preview indexes keyed by LibraryID. The store contains
/// metadata and app-owned previews. Direct providers retain read-only access
/// to user-selected packages while their catalog is being displayed.
@MainActor
final class LibraryPreviewStore: ObservableObject {
    static let shared = LibraryPreviewStore()
    let searchMutations = PassthroughSubject<LibrarySearchMutation, Never>()

    @Published private(set) var manifests: [LibraryID: LibraryPreviewManifest] = [:]
    @Published private(set) var activeIndexLibraryID: LibraryID?
    @Published private(set) var indexCompletedCount = 0
    @Published private(set) var indexTotalCount = 0
    @Published private(set) var indexPhase: LibraryIndexPhase?
    @Published private var directTechnicalMetadataByItemID: [LibraryID: [String: PhotoTechnicalMetadata]] = [:]

    private var thumbnailGridRevisions: [LibraryID: Int] = [:]
    private var directProviders: [LibraryID: RegisteredPhotoLibraryProvider] = [:]
    private var directLivePhotoIDs: [LibraryID: Set<String>] = [:]
    private var loadingDirectTechnicalMetadataIDs = Set<String>()
    private let loadedImages = NSCache<NSString, CachedThumbnailImage>()
    private let loadedViewerImages = NSCache<NSString, NSImage>()
    private let loadedCoverImages = NSCache<NSString, NSImage>()
    private var cancelActiveIndex: (() -> Void)?
    private var durationLoadTasks: [LibraryID: Task<Void, Never>] = [:]
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadedImages.countLimit = 400
        loadedImages.totalCostLimit = 256 * 1_024 * 1_024
        loadedViewerImages.countLimit = 12
        loadedViewerImages.totalCostLimit = 256 * 1_024 * 1_024
        loadedCoverImages.countLimit = 120
        loadedCoverImages.totalCostLimit = 128 * 1_024 * 1_024
        loadManifests()
    }

    func manifest(for libraryID: LibraryID) -> LibraryPreviewManifest? {
        manifests[libraryID]
    }

    func hasDirectProvider(for libraryID: LibraryID) -> Bool {
        directProviders[libraryID] != nil
    }

    func isDirectLivePhoto(_ itemID: String, libraryID: LibraryID) -> Bool {
        directLivePhotoIDs[libraryID]?.contains(itemID) == true
    }

    func directProvider(for libraryID: LibraryID) -> RegisteredPhotoLibraryProvider? {
        directProviders[libraryID]
    }

    /// Replace the visible catalog while retaining every app-owned cache file.
    /// A direct catalog may refresh repeatedly without exporting all assets.
    func adoptDirectCatalog(
        _ catalog: DirectLibraryCatalog,
        provider: RegisteredPhotoLibraryProvider,
        libraryID: LibraryID,
        displayName: String
    ) throws {
        let old = manifests[libraryID]
        if catalog.items.isEmpty, old?.items.isEmpty == false {
            throw DirectLibraryError.database(
                "The catalog returned no items; the existing library view was kept."
            )
        }
        let ids = Set(catalog.items.map(\.id))
        guard ids.count == catalog.items.count else {
            throw DirectLibraryError.database("The catalog contains duplicate asset IDs.")
        }
        // Older indexes used PhotoKit's UUID/L0/001 identifiers, while the
        // direct catalog uses the UUID stored in Photos.sqlite. Recover the
        // existing app-owned files before replacing the old manifest.
        func recoveredFiles(
            from existing: [String: String]?,
            in directory: URL,
            extensions: [String]
        ) -> [String: String] {
            var recovered: [String: String] = [:]
            for id in ids {
                let legacyID = "\(id)/L0/001"
                for key in [id, legacyID] {
                    if let filename = existing?[key],
                       fileManager.fileExists(atPath: directory.appendingPathComponent(filename).path) {
                        recovered[id] = filename
                        break
                    }
                    for ext in extensions {
                        let filename = "\(Self.stableFilename(for: key)).\(ext)"
                        if fileManager.fileExists(
                            atPath: directory.appendingPathComponent(filename).path
                        ) {
                            recovered[id] = filename
                            break
                        }
                    }
                    if recovered[id] != nil { break }
                }
            }
            return recovered
        }
        let thumbnails = recoveredFiles(
            from: old?.thumbnailFilenames,
            in: try thumbnailsDirectory(for: libraryID), extensions: ["jpg", "png"]
        )
        let viewerPreviews = recoveredFiles(
            from: old?.viewerPreviewFilenames,
            in: try viewerPreviewsDirectory(for: libraryID), extensions: ["jpg", "png"]
        )
        let playbackVideos = recoveredFiles(
            from: old?.playbackVideoFilenames,
            in: try playbackVideosDirectory(for: libraryID), extensions: ["mp4"]
        )
        let livePhotoVideos = recoveredFiles(
            from: old?.livePhotoVideoFilenames,
            in: try livePhotoVideosDirectory(for: libraryID), extensions: ["mov", "mp4"]
        )
        var playbackDurations: [String: TimeInterval] = [:]
        for item in catalog.items where Self.isVideo(item) {
            let id = item.id
            playbackDurations[id] = catalog.videoDurations[id]
                ?? old?.playbackVideoDurations?[id]
                ?? old?.playbackVideoDurations?["\(id)/L0/001"]
        }
        var technicalMetadataByItemID: [String: PhotoTechnicalMetadata] = [:]
        if let existingMetadata = old?.technicalMetadataByItemID {
            for id in ids {
                technicalMetadataByItemID[id] = existingMetadata[id]
                    ?? existingMetadata["\(id)/L0/001"]
            }
        }
        let manifest = LibraryPreviewManifest(
            libraryID: libraryID, libraryDisplayName: displayName,
            totalMediaItemCount: catalog.items.count, indexedAt: .now,
            items: catalog.items, albums: catalog.albums,
            thumbnailFilenames: thumbnails,
            viewerPreviewFilenames: viewerPreviews,
            playbackVideoFilenames: playbackVideos,
            playbackVideoDurations: playbackDurations,
            livePhotoVideoFilenames: livePhotoVideos,
            livePhotoCheckedItemIDs: old?.livePhotoCheckedItemIDs,
            itemErrors: [:], pendingPreviewItemIDs: [], pendingMetadataItemIDs: [],
            technicalMetadataByItemID: technicalMetadataByItemID,
            isComplete: true
        )
        directProviders[libraryID] = provider
        directLivePhotoIDs[libraryID] = catalog.livePhotoIDs
        directTechnicalMetadataByItemID[libraryID] = directTechnicalMetadataByItemID[libraryID]?
            .filter { ids.contains($0.key) }
        removeLoadedImages(for: libraryID)
        thumbnailGridRevisions[libraryID, default: 0] += 1
        manifests[libraryID] = manifest
        try persist(manifest)
        searchMutations.send(.replaceLibrary(manifest))
    }

    func thumbnailGridRevision(for libraryID: LibraryID) -> Int {
        thumbnailGridRevisions[libraryID, default: 0]
    }

    func claimIndex(for libraryID: LibraryID) -> Bool {
        guard activeIndexLibraryID == nil else { return false }
        activeIndexLibraryID = libraryID
        indexCompletedCount = 0
        indexTotalCount = 0
        indexPhase = .readingCatalog
        return true
    }

    func setIndexCancellation(_ cancel: @escaping () -> Void, for libraryID: LibraryID) {
        guard activeIndexLibraryID == libraryID else { return }
        cancelActiveIndex = cancel
    }

    func requestIndexCancellation() {
        cancelActiveIndex?()
    }

    func updateIndexProgress(
        completed: Int,
        total: Int,
        phase: LibraryIndexPhase,
        for libraryID: LibraryID
    ) {
        guard activeIndexLibraryID == libraryID else { return }
        if indexCompletedCount != completed { indexCompletedCount = completed }
        if indexTotalCount != total { indexTotalCount = total }
        if indexPhase != phase { indexPhase = phase }
    }

    func releaseIndex(for libraryID: LibraryID) {
        if activeIndexLibraryID == libraryID {
            activeIndexLibraryID = nil
            cancelActiveIndex = nil
            indexCompletedCount = 0
            indexTotalCount = 0
            indexPhase = nil
        }
    }

    func beginIndex(
        libraryID: LibraryID,
        displayName: String,
        totalMediaItemCount: Int,
        items: [PhotosAutomationMediaItem],
        albums: [PhotosAutomationAlbum],
        forceRefresh: Bool,
        metadataNeedsEnrichment: Bool
    ) throws -> LibraryIndexPlan {
        loadedCoverImages.removeAllObjects()
        let thumbnailsDirectory = try thumbnailsDirectory(for: libraryID)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let viewerPreviewsDirectory = try viewerPreviewsDirectory(for: libraryID)
        try fileManager.createDirectory(
            at: viewerPreviewsDirectory,
            withIntermediateDirectories: true
        )
        let playbackDirectory = try playbackVideosDirectory(for: libraryID)
        try fileManager.createDirectory(at: playbackDirectory, withIntermediateDirectories: true)
        let livePhotoDirectory = try livePhotoVideosDirectory(for: libraryID)
        try fileManager.createDirectory(at: livePhotoDirectory, withIntermediateDirectories: true)

        let existingManifest = manifests[libraryID]
        let oldItemsByID = existingManifest?.items.reduce(into: [String: PhotosAutomationMediaItem]()) {
            $0[$1.id] = $1
        } ?? [:]
        let mergedItems = items.map { item in
            guard metadataNeedsEnrichment, let oldItem = oldItemsByID[item.id] else {
                return item
            }
            return PhotosAutomationMediaItem(
                id: item.id,
                filename: item.filename,
                name: item.name,
                itemDescription: oldItem.itemDescription,
                dateDescription: item.dateDescription,
                captureDate: item.captureDate,
                isFavorite: item.isFavorite,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                fileSize: oldItem.fileSize,
                locationDescription: oldItem.locationDescription,
                keywords: oldItem.keywords
            )
        }.sorted(by: Self.isEarlier)
        let newItemIDs = Set(mergedItems.map(\.id))
        let removedItemIDs = Set(oldItemsByID.keys).subtracting(newItemIDs)
        for itemID in removedItemIDs {
            if let filename = existingManifest?.livePhotoVideoFilenames?[itemID] {
                let url = livePhotoDirectory.appendingPathComponent(filename, isDirectory: false)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            if let filename = existingManifest?.playbackVideoFilenames?[itemID] {
                let url = playbackDirectory.appendingPathComponent(filename, isDirectory: false)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            if let filename = existingManifest?.thumbnailFilenames[itemID] {
                let fileURL = thumbnailsDirectory.appendingPathComponent(filename, isDirectory: false)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
            }
            loadedImages.removeObject(
                forKey: imageCacheKey(libraryID: libraryID, itemID: itemID) as NSString
            )
            if let filename = existingManifest?.viewerPreviewFilenames?[itemID] {
                let fileURL = viewerPreviewsDirectory.appendingPathComponent(
                    filename,
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
            }
            loadedViewerImages.removeObject(
                forKey: imageCacheKey(libraryID: libraryID, itemID: itemID) as NSString
            )
        }

        var retainedThumbnails: [String: String] = [:]
        for item in mergedItems {
            if let filename = existingManifest?.thumbnailFilenames[item.id],
               fileManager.fileExists(
                   atPath: thumbnailsDirectory
                       .appendingPathComponent(filename, isDirectory: false)
                       .path
               ) {
                retainedThumbnails[item.id] = filename
                continue
            }

            // Thumbnail filenames are deterministic. If the app terminated
            // between checkpoints, recover completed files without exporting
            // those assets from Photos again.
            let basename = Self.stableFilename(for: item.id)
            for pathExtension in ["jpg", "png"] {
                let filename = "\(basename).\(pathExtension)"
                if fileManager.fileExists(
                    atPath: thumbnailsDirectory
                        .appendingPathComponent(filename, isDirectory: false)
                        .path
                ) {
                    retainedThumbnails[item.id] = filename
                    break
                }
            }
        }

        var retainedViewerPreviews: [String: String] = [:]
        for item in mergedItems {
            if let filename = existingManifest?.viewerPreviewFilenames?[item.id],
               fileManager.fileExists(
                   atPath: viewerPreviewsDirectory
                       .appendingPathComponent(filename, isDirectory: false)
                       .path
               ) {
                retainedViewerPreviews[item.id] = filename
                continue
            }

            // Recover a viewer file written after the last manifest checkpoint,
            // just as the thumbnail recovery above does for its cache tier.
            let basename = Self.stableFilename(for: item.id)
            for pathExtension in ["jpg", "png"] {
                let filename = "\(basename).\(pathExtension)"
                if fileManager.fileExists(
                    atPath: viewerPreviewsDirectory
                        .appendingPathComponent(filename, isDirectory: false)
                        .path
                ) {
                    retainedViewerPreviews[item.id] = filename
                    break
                }
            }
        }

        let carriedPendingIDs = Set(existingManifest?.pendingPreviewItemIDs ?? [])
        var itemsNeedingPreviews: [PhotosAutomationMediaItem] = []
        var addedCount = 0
        var modifiedCount = 0
        var missingPreviewCount = 0
        var rebuiltCount = 0
        for item in mergedItems {
            let oldItem = oldItemsByID[item.id]
            let hasPreview = retainedThumbnails[item.id] != nil
            let hasViewerPreview = retainedViewerPreviews[item.id] != nil

            // A pending item is complete only when both cache tiers can be
            // recovered. Older indexes commonly have a thumbnail but no
            // dedicated viewer preview, so a normal sync must still backfill
            // that higher-resolution tier without discarding the thumbnail.
            if !forceRefresh,
               carriedPendingIDs.contains(item.id),
               hasPreview,
               hasViewerPreview {
                continue
            }

            let wasAdded = oldItem == nil
            let wasModified = oldItem.map { Self.hasPreviewChanges(from: $0, to: item) } ?? false
            let needsMissingPreview = !hasPreview
                || !hasViewerPreview
                || existingManifest?.itemErrors[item.id] != nil
                || carriedPendingIDs.contains(item.id)
            guard forceRefresh || wasAdded || wasModified || needsMissingPreview else { continue }

            if forceRefresh {
                rebuiltCount += 1
            } else if wasAdded {
                addedCount += 1
            } else if wasModified {
                modifiedCount += 1
            } else {
                missingPreviewCount += 1
            }

            // A modified or explicitly rebuilt preview must not be mistaken
            // for a crash-recovered new thumbnail on the next launch.
            if (forceRefresh || wasModified), let filename = retainedThumbnails.removeValue(forKey: item.id) {
                let fileURL = thumbnailsDirectory.appendingPathComponent(filename, isDirectory: false)
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                loadedImages.removeObject(
                    forKey: imageCacheKey(libraryID: libraryID, itemID: item.id) as NSString
                )
            }
            if (forceRefresh || wasModified),
               let filename = retainedViewerPreviews.removeValue(forKey: item.id) {
                let fileURL = viewerPreviewsDirectory.appendingPathComponent(
                    filename,
                    isDirectory: false
                )
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                loadedViewerImages.removeObject(
                    forKey: imageCacheKey(libraryID: libraryID, itemID: item.id) as NSString
                )
            }
            itemsNeedingPreviews.append(item)
        }

        let pendingIDs = Set(itemsNeedingPreviews.map(\.id))
        let retainedErrors = existingManifest?.itemErrors.filter { itemID, _ in
            newItemIDs.contains(itemID) && !pendingIDs.contains(itemID)
        } ?? [:]
        let pendingMetadataIDs: Set<String>
        if metadataNeedsEnrichment {
            // Photos Automation exposes no change token for captions,
            // keywords, locations, or file size. Refresh every surviving
            // item's full metadata during each explicit or automatic sync so
            // metadata-only edits cannot be hidden by an unchanged basic
            // catalog. Preview exports remain incremental and are planned
            // independently above.
            pendingMetadataIDs = newItemIDs
        } else {
            pendingMetadataIDs = []
        }
        let retainedTechnicalMetadata = existingManifest?.technicalMetadataByItemID?.filter {
            newItemIDs.contains($0.key)
        }
        var retainedPlaybackVideos: [String: String] = [:]
        var retainedPlaybackDurations: [String: TimeInterval] = [:]
        var itemsNeedingPlaybackVideos: [PhotosAutomationMediaItem] = []
        for item in mergedItems where Self.isVideo(item) {
            let oldItem = oldItemsByID[item.id]
            let changed = forceRefresh || (oldItem.map {
                Self.hasPreviewChanges(from: $0, to: item)
            } ?? false)
            let filename = "\(Self.stableFilename(for: item.id)).mp4"
            let url = playbackDirectory.appendingPathComponent(filename, isDirectory: false)
            if changed, fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            if !changed, Self.isUsablePlaybackFile(url) {
                retainedPlaybackVideos[item.id] = filename
                if let duration = existingManifest?.playbackVideoDurations?[item.id] {
                    retainedPlaybackDurations[item.id] = duration
                }
            } else {
                itemsNeedingPlaybackVideos.append(item)
            }
        }

        var retainedLivePhotos: [String: String] = [:]
        var checkedLivePhotoIDs = Set(existingManifest?.livePhotoCheckedItemIDs ?? [])
            .intersection(newItemIDs)
        var itemsNeedingLivePhotoChecks: [PhotosAutomationMediaItem] = []
        for item in mergedItems where !Self.isVideo(item) {
            let oldItem = oldItemsByID[item.id]
            let changed = forceRefresh || (oldItem.map {
                Self.hasPreviewChanges(from: $0, to: item)
            } ?? false)
            let filename = "\(Self.stableFilename(for: item.id)).mp4"
            let url = livePhotoDirectory.appendingPathComponent(filename, isDirectory: false)
            if changed {
                checkedLivePhotoIDs.remove(item.id)
                if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            }
            if !changed,
               existingManifest?.livePhotoVideoFilenames?[item.id] == filename,
               Self.isUsablePlaybackFile(url) {
                retainedLivePhotos[item.id] = filename
                checkedLivePhotoIDs.insert(item.id)
            } else if existingManifest?.livePhotoVideoFilenames?[item.id] != nil {
                checkedLivePhotoIDs.remove(item.id)
            }
            if !checkedLivePhotoIDs.contains(item.id) {
                itemsNeedingLivePhotoChecks.append(item)
            }
        }

        let manifest = LibraryPreviewManifest(
            libraryID: libraryID,
            libraryDisplayName: displayName,
            totalMediaItemCount: totalMediaItemCount,
            indexedAt: .now,
            items: mergedItems,
            albums: albums,
            thumbnailFilenames: retainedThumbnails,
            viewerPreviewFilenames: retainedViewerPreviews,
            playbackVideoFilenames: retainedPlaybackVideos,
            playbackVideoDurations: retainedPlaybackDurations,
            livePhotoVideoFilenames: retainedLivePhotos,
            livePhotoCheckedItemIDs: checkedLivePhotoIDs.sorted(),
            itemErrors: retainedErrors,
            pendingPreviewItemIDs: itemsNeedingPreviews.map(\.id),
            pendingMetadataItemIDs: pendingMetadataIDs.sorted(),
            technicalMetadataByItemID: retainedTechnicalMetadata,
            isComplete: false
        )
        thumbnailGridRevisions[libraryID, default: 0] += 1
        manifests[libraryID] = manifest
        try persist(manifest)
        searchMutations.send(.replaceLibrary(manifest))
        return LibraryIndexPlan(
            itemsNeedingPreviews: itemsNeedingPreviews,
            itemsNeedingPlaybackVideos: itemsNeedingPlaybackVideos,
            itemsNeedingLivePhotoChecks: itemsNeedingLivePhotoChecks,
            addedCount: addedCount,
            modifiedCount: modifiedCount,
            missingPreviewCount: missingPreviewCount,
            removedCount: removedItemIDs.count,
            rebuiltCount: rebuiltCount
        )
    }

    func hasThumbnail(for itemID: String, libraryID: LibraryID) -> Bool {
        guard let filename = manifests[libraryID]?.thumbnailFilenames[itemID],
              let directory = try? thumbnailsDirectory(for: libraryID) else {
            return false
        }
        return fileManager.fileExists(
            atPath: directory.appendingPathComponent(filename, isDirectory: false).path
        )
    }

    func playbackVideoURL(for itemID: String, libraryID: LibraryID) -> URL? {
        guard let manifest = manifests[libraryID],
              let item = manifest.items.first(where: { $0.id == itemID }),
              Self.isVideo(item),
              let filename = manifest.playbackVideoFilenames?[itemID],
              filename == "\(Self.stableFilename(for: itemID)).mp4",
              let directory = try? playbackVideosDirectory(for: libraryID) else {
            return nil
        }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        return Self.isUsablePlaybackFile(url) ? url : nil
    }

    func hasPlaybackVideo(for itemID: String, libraryID: LibraryID) -> Bool {
        playbackVideoURL(for: itemID, libraryID: libraryID) != nil
    }

    func playbackDuration(for itemID: String, libraryID: LibraryID) async -> TimeInterval? {
        await ensurePlaybackDurations(for: libraryID)
        return manifests[libraryID]?.playbackVideoDurations?[itemID]
    }

    func ensurePlaybackDurations(for libraryID: LibraryID) async {
        if let task = durationLoadTasks[libraryID] {
            await task.value
            return
        }
        let task = Task { await self.loadMissingPlaybackDurations(for: libraryID) }
        durationLoadTasks[libraryID] = task
        await task.value
        durationLoadTasks[libraryID] = nil
    }

    private func loadMissingPlaybackDurations(for libraryID: LibraryID) async {
        guard let manifest = manifests[libraryID] else { return }
        let missingIDs = (manifest.playbackVideoFilenames ?? [:]).keys.filter {
            manifest.playbackVideoDurations?[$0] == nil
        }
        guard !missingIDs.isEmpty else { return }
        var durations: [String: TimeInterval] = [:]
        for itemID in missingIDs {
            guard let url = playbackVideoURL(for: itemID, libraryID: libraryID),
                  let time = try? await AVURLAsset(url: url).load(.duration) else { continue }
            let seconds = time.seconds
            if seconds.isFinite, seconds >= 0 { durations[itemID] = seconds }
        }
        guard !durations.isEmpty, var current = manifests[libraryID] else { return }
        if current.playbackVideoDurations == nil { current.playbackVideoDurations = [:] }
        for (itemID, duration) in durations
        where current.playbackVideoFilenames?[itemID] != nil
            && current.playbackVideoDurations?[itemID] == nil {
            current.playbackVideoDurations?[itemID] = duration
        }
        manifests[libraryID] = current
        try? persist(current)
    }

    func hasMissingPlaybackVideos(for libraryID: LibraryID) -> Bool {
        guard let manifest = manifests[libraryID] else { return false }
        return manifest.items.contains {
            Self.isVideo($0) && !hasPlaybackVideo(for: $0.id, libraryID: libraryID)
        }
    }

    func hasPendingLivePhotoChecks(for libraryID: LibraryID) -> Bool {
        guard let manifest = manifests[libraryID] else { return false }
        let checked = Set(manifest.livePhotoCheckedItemIDs ?? [])
        return manifest.items.contains { !Self.isVideo($0) && !checked.contains($0.id) }
    }

    func livePhotoVideoURL(for itemID: String, libraryID: LibraryID) -> URL? {
        guard let filename = manifests[libraryID]?.livePhotoVideoFilenames?[itemID],
              filename == "\(Self.stableFilename(for: itemID)).mp4",
              let directory = try? livePhotoVideosDirectory(for: libraryID) else { return nil }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        return Self.isUsablePlaybackFile(url) ? url : nil
    }

    func markLivePhotoChecked(_ itemID: String, libraryID: LibraryID) {
        guard var manifest = manifests[libraryID],
              manifest.items.contains(where: { $0.id == itemID }) else { return }
        var checked = Set(manifest.livePhotoCheckedItemIDs ?? [])
        checked.insert(itemID)
        manifest.livePhotoCheckedItemIDs = checked.sorted()
        manifests[libraryID] = manifest
    }

    func storeLivePhotoVideo(_ source: URL, for itemID: String, libraryID: LibraryID) throws {
        guard var manifest = manifests[libraryID],
              manifest.items.contains(where: { $0.id == itemID && !Self.isVideo($0) }),
              Self.isUsablePlaybackFile(source) else {
            throw LibraryPreviewStoreError.invalidPlaybackVideo
        }
        let directory = try livePhotoVideosDirectory(for: libraryID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(Self.stableFilename(for: itemID)).mp4"
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        guard Self.isUsablePlaybackFile(temporary) else {
            throw LibraryPreviewStoreError.invalidPlaybackVideo
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        if manifest.livePhotoVideoFilenames == nil { manifest.livePhotoVideoFilenames = [:] }
        manifest.livePhotoVideoFilenames?[itemID] = filename
        var checked = Set(manifest.livePhotoCheckedItemIDs ?? [])
        checked.insert(itemID)
        manifest.livePhotoCheckedItemIDs = checked.sorted()
        manifests[libraryID] = manifest
    }

    func storePlaybackVideo(_ source: URL, for itemID: String, libraryID: LibraryID) async throws {
        guard let manifest = manifests[libraryID],
              let item = manifest.items.first(where: { $0.id == itemID }),
              Self.isVideo(item), Self.isUsablePlaybackFile(source) else {
            throw LibraryPreviewStoreError.invalidPlaybackVideo
        }
        let directory = try playbackVideosDirectory(for: libraryID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(Self.stableFilename(for: itemID)).mp4"
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        guard Self.isUsablePlaybackFile(temporary) else {
            throw LibraryPreviewStoreError.invalidPlaybackVideo
        }
        let playbackTime = try? await AVURLAsset(url: temporary).load(.duration)
        guard var currentManifest = manifests[libraryID],
              currentManifest.items.contains(where: { $0.id == itemID && Self.isVideo($0) }) else {
            throw LibraryPreviewStoreError.invalidPlaybackVideo
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
        if currentManifest.playbackVideoFilenames == nil {
            currentManifest.playbackVideoFilenames = [:]
        }
        currentManifest.playbackVideoFilenames?[itemID] = filename
        if let seconds = playbackTime?.seconds, seconds.isFinite, seconds >= 0 {
            if currentManifest.playbackVideoDurations == nil {
                currentManifest.playbackVideoDurations = [:]
            }
            currentManifest.playbackVideoDurations?[itemID] = seconds
        }
        manifests[libraryID] = currentManifest
    }

    func completedThumbnailCount(for libraryID: LibraryID) -> Int {
        guard let manifest = manifests[libraryID] else { return 0 }
        return manifest.items.reduce(into: 0) { count, item in
            if hasThumbnail(for: item.id, libraryID: libraryID) {
                count += 1
            }
        }
    }

    func technicalMetadata(
        for itemID: String,
        libraryID: LibraryID
    ) -> PhotoTechnicalMetadata? {
        if directProviders[libraryID] != nil {
            return directTechnicalMetadataByItemID[libraryID]?[itemID]
        }
        let metadata = manifests[libraryID]?.technicalMetadataByItemID
        return metadata?[itemID] ?? metadata?["\(itemID)/L0/001"]
    }

    func loadDirectTechnicalMetadata(for itemID: String, libraryID: LibraryID) async {
        guard let provider = directProviders[libraryID],
              let item = manifests[libraryID]?.items.first(where: { $0.id == itemID }),
              directTechnicalMetadataByItemID[libraryID]?[itemID] == nil else { return }
        let key = "\(libraryID.rawValue.uuidString):\(itemID)"
        guard loadingDirectTechnicalMetadataIDs.insert(key).inserted else { return }
        defer { loadingDirectTechnicalMetadataIDs.remove(key) }
        guard let metadata = await provider.technicalMetadata(
            for: itemID, filename: item.filename
        ), directProviders[libraryID] === provider else { return }
        directTechnicalMetadataByItemID[libraryID, default: [:]][itemID] = metadata
    }

    /// Keep camera information from a verified System Library transfer under
    /// the new Photos item ID. The target's own preview supplies its image
    /// dimensions, file size, and format when it is indexed.
    func seedTransferredCameraMetadata(
        _ source: PhotoTechnicalMetadata,
        for itemID: String,
        libraryID: LibraryID
    ) throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        let cameraMetadata = PhotoTechnicalMetadata(
            cameraMake: source.cameraMake,
            cameraModel: source.cameraModel,
            lensModel: source.lensModel,
            iso: source.iso,
            meteringMode: source.meteringMode,
            focalLength: source.focalLength,
            focalLengthIn35mm: source.focalLengthIn35mm,
            exposureBias: source.exposureBias,
            aperture: source.aperture,
            exposureTime: source.exposureTime,
            whiteBalance: source.whiteBalance,
            pixelWidth: nil,
            pixelHeight: nil,
            fileSize: nil,
            fileFormat: nil
        )
        var metadataByID = manifest.technicalMetadataByItemID ?? [:]
        metadataByID[itemID] = metadataByID[itemID]?
            .fillingMissingCameraValues(from: cameraMetadata) ?? cameraMetadata
        manifest.technicalMetadataByItemID = metadataByID
        try persist(manifest)
        manifests[libraryID] = manifest
    }

    func storeThumbnail(_ data: Data, for itemID: String, libraryID: LibraryID) throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        let previousFilename = manifest.thumbnailFilenames[itemID]
        let filename = "\(Self.stableFilename(for: itemID)).jpg"
        let directory = try thumbnailsDirectory(for: libraryID)
        let fileURL = directory
            .appendingPathComponent(filename, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        if let previousFilename, previousFilename != filename {
            let previousURL = directory.appendingPathComponent(previousFilename, isDirectory: false)
            if fileManager.fileExists(atPath: previousURL.path) {
                try fileManager.removeItem(at: previousURL)
            }
        }

        manifest.thumbnailFilenames[itemID] = filename
        manifest.itemErrors[itemID] = nil
        manifest.pendingPreviewItemIDs?.removeAll { $0 == itemID }
        thumbnailGridRevisions[libraryID, default: 0] += 1
        manifests[libraryID] = manifest
        loadedImages.removeObject(
            forKey: imageCacheKey(libraryID: libraryID, itemID: itemID) as NSString
        )
        loadedCoverImages.removeAllObjects()
    }

    func storeError(_ message: String, for itemID: String, libraryID: LibraryID) throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        if manifest.itemErrors[itemID] != message {
            thumbnailGridRevisions[libraryID, default: 0] += 1
        }
        manifest.itemErrors[itemID] = message
        manifests[libraryID] = manifest
    }

    /// Writes all files from one Photos export batch, then publishes the
    /// manifest once. This prevents a large SwiftUI grid from being rebuilt
    /// after every individual thumbnail.
    func storePreviewUpdates(
        _ updates: [LibraryPreviewUpdate],
        libraryID: LibraryID
    ) async throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        let directory = try thumbnailsDirectory(for: libraryID)
        let viewerDirectory = try viewerPreviewsDirectory(for: libraryID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: viewerDirectory, withIntermediateDirectories: true)
        let previousFilenames = manifest.thumbnailFilenames
        let previousViewerFilenames = manifest.viewerPreviewFilenames ?? [:]
        let prepared = await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            return updates.map { update -> PreparedPreviewUpdate in
                guard let data = update.thumbnailData else {
                    return PreparedPreviewUpdate(
                        itemID: update.itemID,
                        filename: nil,
                        viewerFilename: nil,
                        technicalMetadata: update.technicalMetadata,
                        errorDescription: update.errorDescription
                            ?? "Photos did not export a supported preview."
                    )
                }
                let filename = "\(Self.stableFilename(for: update.itemID)).jpg"
                let fileURL = directory.appendingPathComponent(filename, isDirectory: false)
                do {
                    try data.write(to: fileURL, options: .atomic)
                    if let previousFilename = previousFilenames[update.itemID],
                       previousFilename != filename {
                        let previousURL = directory.appendingPathComponent(
                            previousFilename,
                            isDirectory: false
                        )
                        if fileManager.fileExists(atPath: previousURL.path) {
                            try fileManager.removeItem(at: previousURL)
                        }
                    }
                    var viewerFilename: String?
                    if let viewerData = update.viewerPreviewData {
                        let candidate = filename
                        let viewerURL = viewerDirectory.appendingPathComponent(
                            candidate,
                            isDirectory: false
                        )
                        do {
                            try viewerData.write(to: viewerURL, options: .atomic)
                            if let previousFilename = previousViewerFilenames[update.itemID],
                               previousFilename != candidate {
                                let previousURL = viewerDirectory.appendingPathComponent(
                                    previousFilename,
                                    isDirectory: false
                                )
                                if fileManager.fileExists(atPath: previousURL.path) {
                                    try fileManager.removeItem(at: previousURL)
                                }
                            }
                            viewerFilename = candidate
                        } catch {
                            // The 600 px thumbnail remains a valid fallback.
                            // A later sync can recreate the viewer file.
                            viewerFilename = nil
                        }
                    }
                    return PreparedPreviewUpdate(
                        itemID: update.itemID,
                        filename: filename,
                        viewerFilename: viewerFilename,
                        technicalMetadata: update.technicalMetadata,
                        errorDescription: nil
                    )
                } catch {
                    return PreparedPreviewUpdate(
                        itemID: update.itemID,
                        filename: nil,
                        viewerFilename: nil,
                        technicalMetadata: update.technicalMetadata,
                        errorDescription: error.localizedDescription
                    )
                }
            }
        }.value

        let thumbnailGridChanged = prepared.contains { update in
            if let filename = update.filename {
                return previousFilenames[update.itemID] != filename
                    || previousViewerFilenames[update.itemID] != update.viewerFilename
                    || manifest.itemErrors[update.itemID] != nil
            }
            return manifest.itemErrors[update.itemID] != update.errorDescription
        }
        var technicalMetadataByID = manifest.technicalMetadataByItemID ?? [:]
        var viewerPreviewFilenames = manifest.viewerPreviewFilenames ?? [:]
        var completedItemIDs = Set<String>()
        completedItemIDs.reserveCapacity(prepared.count)
        for update in prepared {
            guard let filename = update.filename else {
                manifest.itemErrors[update.itemID] = update.errorDescription
                continue
            }
            manifest.thumbnailFilenames[update.itemID] = filename
            if let viewerFilename = update.viewerFilename {
                viewerPreviewFilenames[update.itemID] = viewerFilename
            } else {
                viewerPreviewFilenames[update.itemID] = nil
            }
            if let technicalMetadata = update.technicalMetadata {
                if let preserved = technicalMetadataByID[update.itemID] {
                    technicalMetadataByID[update.itemID] = technicalMetadata
                        .fillingMissingCameraValues(from: preserved)
                } else {
                    technicalMetadataByID[update.itemID] = technicalMetadata
                }
            }
            manifest.itemErrors[update.itemID] = nil
            completedItemIDs.insert(update.itemID)
            loadedImages.removeObject(
                forKey: imageCacheKey(libraryID: libraryID, itemID: update.itemID) as NSString
            )
            loadedViewerImages.removeObject(
                forKey: imageCacheKey(libraryID: libraryID, itemID: update.itemID) as NSString
            )
        }
        manifest.viewerPreviewFilenames = viewerPreviewFilenames
        manifest.technicalMetadataByItemID = technicalMetadataByID
        manifest.pendingPreviewItemIDs?.removeAll { completedItemIDs.contains($0) }
        loadedCoverImages.removeAllObjects()

        if thumbnailGridChanged {
            thumbnailGridRevisions[libraryID, default: 0] += 1
        }
        manifests[libraryID] = manifest
    }

    /// Merges and publishes one metadata record without rebuilding the whole
    /// metadata batch in memory first.
    func mergeMetadataItem(
        _ enriched: PhotosAutomationMediaItem,
        libraryID: LibraryID
    ) throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        guard let index = manifest.items.firstIndex(where: { $0.id == enriched.id }) else {
            return
        }
        let item = manifest.items[index]
        manifest.items[index] = PhotosAutomationMediaItem(
            id: item.id,
            filename: item.filename,
            name: item.name,
            itemDescription: enriched.itemDescription,
            dateDescription: item.dateDescription,
            captureDate: item.captureDate,
            isFavorite: item.isFavorite,
            pixelWidth: item.pixelWidth,
            pixelHeight: item.pixelHeight,
            fileSize: enriched.fileSize,
            locationDescription: enriched.locationDescription,
            keywords: enriched.keywords
        )
        manifest.pendingMetadataItemIDs?.removeAll { $0 == enriched.id }
        manifests[libraryID] = manifest
        searchMutations.send(
            .upsertItem(
                libraryID: libraryID,
                libraryName: manifest.libraryDisplayName,
                item: manifest.items[index]
            )
        )
    }

    func mergeMetadata(
        _ enrichedItems: [PhotosAutomationMediaItem],
        libraryID: LibraryID
    ) throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        let enrichedByID = Dictionary(uniqueKeysWithValues: enrichedItems.map { ($0.id, $0) })
        let completedIDs = Set(enrichedByID.keys)
        manifest.items = manifest.items.map { item in
            guard let enriched = enrichedByID[item.id] else { return item }
            return PhotosAutomationMediaItem(
                id: item.id,
                filename: item.filename,
                name: item.name,
                itemDescription: enriched.itemDescription,
                dateDescription: item.dateDescription,
                captureDate: item.captureDate,
                isFavorite: item.isFavorite,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                fileSize: enriched.fileSize,
                locationDescription: enriched.locationDescription,
                keywords: enriched.keywords
            )
        }
        manifest.pendingMetadataItemIDs?.removeAll { completedIDs.contains($0) }
        manifests[libraryID] = manifest
        searchMutations.send(.replaceLibrary(manifest))
    }

    func checkpointIndex(libraryID: LibraryID) async throws {
        guard let manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        let destination = try manifestURL(for: libraryID)
        try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: destination, options: .atomic)
        }.value
    }

    func finishIndex(libraryID: LibraryID, completed: Bool) throws {
        guard var manifest = manifests[libraryID] else {
            throw LibraryPreviewStoreError.missingManifest
        }
        manifest.isComplete = completed
            && (manifest.pendingPreviewItemIDs?.isEmpty ?? true)
            && (manifest.pendingMetadataItemIDs?.isEmpty ?? true)
            && manifest.items.count >= manifest.totalMediaItemCount
            && manifest.albums != nil
            && manifest.albums?.allSatisfy({ $0.mediaItemIDs != nil }) == true
        manifests[libraryID] = manifest
        try persist(manifest)
    }

    func thumbnailRevision(for itemID: String, libraryID: LibraryID) -> String? {
        if directProviders[libraryID] != nil {
            return "direct:\(itemID):\(thumbnailGridRevision(for: libraryID))"
        }
        return manifests[libraryID]?.thumbnailFilenames[itemID]
    }

    func viewerPreviewRevision(for itemID: String, libraryID: LibraryID) -> String? {
        guard let manifest = manifests[libraryID] else { return nil }
        if directProviders[libraryID] != nil {
            return "direct-viewer:\(itemID):\(thumbnailGridRevision(for: libraryID))"
        }
        if let filename = manifest.viewerPreviewFilenames?[itemID] {
            return "viewer:\(filename)"
        }
        return manifest.thumbnailFilenames[itemID].map { "thumbnail:\($0)" }
            ?? (directProviders[libraryID] == nil ? nil : "direct:\(itemID)")
    }

    /// Read only a file named by a currently indexed item. Callers must also
    /// check the registry and the user's web sharing selection first.
    func webPreviewData(
        for itemID: String,
        libraryID: LibraryID,
        prefersViewer: Bool,
        directProvider: RegisteredPhotoLibraryProvider?
    ) async -> (data: Data, contentType: String)? {
        guard let manifest = manifests[libraryID],
              manifest.items.contains(where: { $0.id == itemID }) else { return nil }
        let viewerFilename = manifest.viewerPreviewFilenames?[itemID]
        let useViewer = prefersViewer && viewerFilename != nil
        if let filename = useViewer ? viewerFilename : manifest.thumbnailFilenames[itemID],
           filename == URL(fileURLWithPath: filename).lastPathComponent,
           ["jpg", "png"].contains(URL(fileURLWithPath: filename).pathExtension.lowercased()),
           let directory = try? (useViewer
               ? viewerPreviewsDirectory(for: libraryID)
               : thumbnailsDirectory(for: libraryID)),
           let data = try? Data(
               contentsOf: directory.appendingPathComponent(filename, isDirectory: false),
               options: .mappedIfSafe
           ) {
            return (data, filename.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg")
        }
        guard let directProvider,
              let image = await directProvider.image(
                for: itemID,
                size: CGSize(width: prefersViewer ? 2_400 : 480, height: prefersViewer ? 2_400 : 480)
              ),
              manifests[libraryID]?.items.contains(where: { $0.id == itemID }) == true,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(
                using: .jpeg, properties: [.compressionFactor: 0.88]
              ) else { return nil }
        return (data, "image/jpeg")
    }

    func webTechnicalMetadata(
        for itemID: String,
        libraryID: LibraryID,
        directProvider: RegisteredPhotoLibraryProvider?
    ) async -> PhotoTechnicalMetadata? {
        guard let item = manifests[libraryID]?.items.first(where: { $0.id == itemID }) else {
            return nil
        }
        if let metadata = technicalMetadata(for: itemID, libraryID: libraryID)
            ?? manifests[libraryID]?.technicalMetadataByItemID?[itemID] {
            return metadata
        }
        guard let directProvider,
              let metadata = await directProvider.technicalMetadata(
                for: itemID, filename: item.filename
              ),
              manifests[libraryID]?.items.contains(where: { $0.id == itemID }) == true else {
            return nil
        }
        return metadata
    }

    func loadThumbnail(
        for itemID: String, libraryID: LibraryID, pixelSize: Int = 600,
        sourceAspectRatio: Double? = nil
    ) async -> NSImage? {
        let requestedSize = max(1, pixelSize)
        let requiresSquareCoverage = sourceAspectRatio != nil
        let requestSize = sourceAspectRatio.map {
            Int(ceil(Double(requestedSize) * max(1, $0)))
        } ?? requestedSize
        let cacheKey = imageCacheKey(libraryID: libraryID, itemID: itemID)
        let cached = loadedImages.object(forKey: cacheKey as NSString)
        if let cached,
           (requiresSquareCoverage ? cached.squarePixelSize : cached.maxPixelSize) >= requestedSize {
            return cached.image
        }
        var fallbackImage = cached?.image
        if let filename = manifests[libraryID]?.thumbnailFilenames[itemID],
           let directory = try? thumbnailsDirectory(for: libraryID) {
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            let decodeTask = Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled else { return nil }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: requestSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    options
                ) ?? CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                )
            }
            let decodedImage = await withTaskCancellationHandler {
                await decodeTask.value
            } onCancel: {
                decodeTask.cancel()
            }
            guard !Task.isCancelled else { return nil }
            if let cgImage = decodedImage {
                let image = NSImage(cgImage: cgImage, size: .zero)
                let availableSize = requiresSquareCoverage
                    ? min(cgImage.width, cgImage.height)
                    : max(cgImage.width, cgImage.height)
                if let current = loadedImages.object(forKey: cacheKey as NSString),
                   (requiresSquareCoverage ? current.squarePixelSize : current.maxPixelSize)
                    >= requestedSize {
                    return current.image
                }
                if availableSize >= requestedSize || directProviders[libraryID] == nil {
                    loadedImages.setObject(
                        CachedThumbnailImage(
                            image: image,
                            maxPixelSize: max(cgImage.width, cgImage.height),
                            squarePixelSize: min(cgImage.width, cgImage.height)
                        ),
                        forKey: cacheKey as NSString,
                        cost: cgImage.width * cgImage.height * 4
                    )
                    return image
                }
                fallbackImage = image
            }
        }
        if let current = loadedImages.object(forKey: cacheKey as NSString),
           (requiresSquareCoverage ? current.squarePixelSize : current.maxPixelSize)
            >= requestedSize {
            return current.image
        }
        guard !Task.isCancelled else { return nil }
        if let provider = directProviders[libraryID],
           let image = await provider.image(
            for: itemID, size: CGSize(width: requestSize, height: requestSize)
           ) {
            let imagePixels = image.representations.max {
                min($0.pixelsWide, $0.pixelsHigh) < min($1.pixelsWide, $1.pixelsHigh)
            }
            let current = loadedImages.object(forKey: cacheKey as NSString)
            if (current.map {
                requiresSquareCoverage ? $0.squarePixelSize : $0.maxPixelSize
            } ?? 0) <= requestedSize {
                loadedImages.setObject(
                    CachedThumbnailImage(
                        image: image,
                        maxPixelSize: imagePixels.map { max($0.pixelsWide, $0.pixelsHigh) }
                            ?? requestSize,
                        squarePixelSize: imagePixels.map { min($0.pixelsWide, $0.pixelsHigh) }
                            ?? requestedSize
                    ),
                    forKey: cacheKey as NSString
                )
            }
            return image
        }
        return fallbackImage
    }

    /// Loads the dedicated higher-resolution viewer preview when available.
    /// Older indexes intentionally fall back to their 600 px thumbnail until
    /// the next synchronization backfills the viewer tier.
    func loadViewerPreview(for itemID: String, libraryID: LibraryID) async -> NSImage? {
        let cacheKey = imageCacheKey(libraryID: libraryID, itemID: itemID)
        if let image = loadedViewerImages.object(forKey: cacheKey as NSString) {
            return image
        }
        if let filename = manifests[libraryID]?.viewerPreviewFilenames?[itemID],
           let directory = try? viewerPreviewsDirectory(for: libraryID) {
            let url = directory.appendingPathComponent(filename, isDirectory: false)
            let decodeTask = Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateImageAtIndex(
                    source,
                    0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                )
            }
            if let cgImage = await decodeTask.value {
                let image = NSImage(cgImage: cgImage, size: .zero)
                loadedViewerImages.setObject(
                    image, forKey: cacheKey as NSString,
                    cost: cgImage.width * cgImage.height * 4
                )
                return image
            }
        }
        if let provider = directProviders[libraryID],
           let image = await provider.image(
            for: itemID, size: CGSize(width: 2_400, height: 2_400)
           ) {
            loadedViewerImages.setObject(image, forKey: cacheKey as NSString)
            return image
        }
        return await loadThumbnail(for: itemID, libraryID: libraryID)
    }

    /// Downsample an existing app-owned viewer preview to the pixel size of a
    /// square timeline cover. Account for aspect fill so portrait and wide
    /// images retain enough pixels across the short edge.
    func loadCoverPreview(
        for itemID: String,
        libraryID: LibraryID,
        pixelSize: Int
    ) async -> NSImage? {
        let side = min(4_096, max(64, ((max(1, pixelSize) + 63) / 64) * 64))
        let cacheKey = "\(imageCacheKey(libraryID: libraryID, itemID: itemID)):cover:\(side)"
        if let image = loadedCoverImages.object(forKey: cacheKey as NSString) {
            return image
        }
        guard let filename = manifests[libraryID]?.viewerPreviewFilenames?[itemID],
              let directory = try? viewerPreviewsDirectory(for: libraryID) else {
            return await loadThumbnail(for: itemID, libraryID: libraryID)
        }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let decodeTask = Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any] else { return nil }
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1
            let aspect = max(width, height) / max(1, min(width, height))
            let maximumPixelSize = min(4_096, Int(ceil(Double(side) * aspect)))
            return CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
            )
        }
        guard let cgImage = await decodeTask.value else {
            return await loadThumbnail(for: itemID, libraryID: libraryID)
        }
        let image = NSImage(cgImage: cgImage, size: .zero)
        loadedCoverImages.setObject(
            image,
            forKey: cacheKey as NSString,
            cost: cgImage.width * cgImage.height * 4
        )
        return image
    }

    func clear(libraryID: LibraryID) throws {
        directProviders[libraryID] = nil
        directLivePhotoIDs[libraryID] = nil
        let directory = try libraryDirectory(for: libraryID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        removeLoadedImages(for: libraryID)
        thumbnailGridRevisions[libraryID, default: 0] += 1
        manifests[libraryID] = nil
        searchMutations.send(.removeLibrary(libraryID))
    }

    private func loadManifests() {
        guard let root = try? rootDirectory(createIfNeeded: false),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for directory in directories {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  var manifest = try? decoder.decode(LibraryPreviewManifest.self, from: data) else {
                continue
            }
            manifest.libraryDisplayName = LibraryPackageMetadata.withoutPackageExtension(
                manifest.libraryDisplayName
            )
            if manifest.items.count < manifest.totalMediaItemCount
                || !(manifest.pendingPreviewItemIDs?.isEmpty ?? true)
                || !(manifest.pendingMetadataItemIDs?.isEmpty ?? true)
                // An older manifest can still display its previews, but it
                // needs one safe re-index before the sidebar can show all
                // albums for that registered library.
                || manifest.albums == nil
                || manifest.albums?.contains(where: { $0.mediaItemIDs == nil }) == true {
                manifest.isComplete = false
            }
            // Older manifests may preserve Photos' implementation-defined
            // order. Normalize once when loading instead of sorting again on
            // every SwiftUI update.
            manifest.items.sort(by: Self.isEarlier)
            manifests[manifest.libraryID] = manifest
        }
    }

    nonisolated private static func isEarlier(
        _ lhs: PhotosAutomationMediaItem,
        _ rhs: PhotosAutomationMediaItem
    ) -> Bool {
        switch (lhs.captureDate, rhs.captureDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let leftName = lhs.filename.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            let rightName = rhs.filename.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            if leftName != rightName { return leftName < rightName }
            return lhs.id < rhs.id
        }
    }

    private func persist(_ manifest: LibraryPreviewManifest) throws {
        let data = try encoder.encode(manifest)
        try fileManager.createDirectory(
            at: libraryDirectory(for: manifest.libraryID),
            withIntermediateDirectories: true
        )
        try data.write(to: manifestURL(for: manifest.libraryID), options: .atomic)
    }

    private func rootDirectory(createIfNeeded: Bool = true) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = applicationSupport
            .appendingPathComponent("Photo Libraries", isDirectory: true)
            .appendingPathComponent("Preview Index", isDirectory: true)
        if createIfNeeded {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    private func libraryDirectory(for libraryID: LibraryID) throws -> URL {
        try rootDirectory()
            .appendingPathComponent(libraryID.rawValue.uuidString, isDirectory: true)
    }

    private func thumbnailsDirectory(for libraryID: LibraryID) throws -> URL {
        try libraryDirectory(for: libraryID)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private func viewerPreviewsDirectory(for libraryID: LibraryID) throws -> URL {
        try libraryDirectory(for: libraryID)
            .appendingPathComponent("Viewer Previews", isDirectory: true)
    }

    private func playbackVideosDirectory(for libraryID: LibraryID) throws -> URL {
        try libraryDirectory(for: libraryID)
            .appendingPathComponent("Playback Videos", isDirectory: true)
    }

    private func livePhotoVideosDirectory(for libraryID: LibraryID) throws -> URL {
        try libraryDirectory(for: libraryID)
            .appendingPathComponent("Live Photo Videos", isDirectory: true)
    }

    nonisolated private static func isVideo(_ item: PhotosAutomationMediaItem) -> Bool {
        UTType(filenameExtension: URL(fileURLWithPath: item.filename).pathExtension)?
            .conforms(to: .movie) == true
    }

    nonisolated private static func isUsablePlaybackFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }

    private func manifestURL(for libraryID: LibraryID) throws -> URL {
        try libraryDirectory(for: libraryID)
            .appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func imageCacheKey(libraryID: LibraryID, itemID: String) -> String {
        "\(libraryID.rawValue.uuidString):\(itemID)"
    }

    private func removeLoadedImages(for libraryID: LibraryID) {
        // NSCache does not expose key enumeration. Clearing this bounded,
        // recoverable display cache avoids retaining images from a removed
        // library; visible thumbnails are decoded again on demand.
        loadedImages.removeAllObjects()
        loadedViewerImages.removeAllObjects()
        loadedCoverImages.removeAllObjects()
    }

    nonisolated private static func stableFilename(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func hasPreviewChanges(
        from oldItem: PhotosAutomationMediaItem,
        to newItem: PhotosAutomationMediaItem
    ) -> Bool {
        if oldItem.filename != newItem.filename
            || oldItem.dateDescription != newItem.dateDescription
            || oldItem.pixelWidth != newItem.pixelWidth
            || oldItem.pixelHeight != newItem.pixelHeight {
            return true
        }
        if let oldSize = oldItem.fileSize,
           let newSize = newItem.fileSize,
           oldSize != newSize {
            return true
        }
        return false
    }

}

nonisolated enum LibraryPreviewStoreError: LocalizedError {
    case missingManifest
    case invalidPlaybackVideo

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            "The preview index is unavailable. Start indexing the library again."
        case .invalidPlaybackVideo:
            "The exported playback video is unavailable."
        }
    }
}
