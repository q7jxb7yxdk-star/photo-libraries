import AppKit
import Combine
import Foundation
import Photos

/// PhotoKit invokes change observers on an arbitrary queue. Keep that callback
/// separate from the main-actor view model, then hop back before changing UI
/// state or scheduling a catalog reload.
private final class SystemPhotoLibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    nonisolated(unsafe) weak var viewModel: SystemPhotoLibraryViewModel?

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let viewModel = viewModel
        Task { @MainActor [weak viewModel] in
            viewModel?.schedulePhotoLibraryChangeReload()
        }
    }
}

@MainActor
final class SystemPhotoThumbnailSlot: ObservableObject {
    @Published private(set) var image: NSImage?

    init(image: NSImage? = nil) {
        self.image = image
    }

    fileprivate func update(_ image: NSImage?) {
        self.image = image
    }
}

@MainActor
final class SystemPhotoLibraryViewModel: ObservableObject {
    private static let filenameBatchSize = 100
    private static let viewerCacheLimit = 4
    private static let thumbnailCacheLimit = 256
    private static let maximumViewerPixelLength: CGFloat = 4_096
    private static let changeReloadDebounceNanoseconds: UInt64 = 300_000_000

    private let provider = SystemPhotoLibraryProvider()
    private let photoLibraryChangeObserver: SystemPhotoLibraryChangeObserver
    private var thumbnailRequestIDs: [String: PHImageRequestID] = [:]
    private var thumbnailRequestTokens: [String: UUID] = [:]
    private var thumbnailRequestSizes: [String: CGSize] = [:]
    private var thumbnailConsumers: [String: Set<UUID>] = [:]
    private var thumbnailImageSizes: [String: CGSize] = [:]
    private var thumbnailSlots: [String: SystemPhotoThumbnailSlot] = [:]
    private var thumbnailCacheOrder: [String] = []
    private var viewerRequestIDs: [String: PHImageRequestID] = [:]
    private var viewerRequestTokens: [String: UUID] = [:]
    private var viewerRequestSizes: [String: CGSize] = [:]
    private var viewerImageSizes: [String: CGSize] = [:]
    private var viewerCacheOrder: [String] = []
    private var exportTask: Task<Void, Never>?
    private var filenameEnrichmentTask: Task<Void, Never>?
    private var technicalMetadataTask: Task<Void, Never>?
    private var resourceInventoryTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var technicalMetadataGeneration = UUID()
    private var resourceInventoryGeneration = UUID()
    private var photoLibraryChangeReloadTask: Task<Void, Never>?
    private var photoLibraryChangeGeneration = UUID()

    /// Search consumes completed filename batches without waiting for the
    /// entire System Library enrichment to finish.
    let searchAssetUpdates = PassthroughSubject<[PhotoAssetSummary], Never>()

    @Published private(set) var authorization: PhotoLibraryAuthorization
    @Published private(set) var assetCount = 0
    @Published private(set) var assets: [PhotoAssetSummary] = []
    @Published private(set) var catalogRevision = 0
    private(set) var gridContentRevision = 0
    @Published private(set) var collections: [PhotoCollectionNode] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    /// Changes whenever thumbnail requests must be issued again after their
    /// cache is invalidated. Views include it in their task identity so
    /// existing lazy cells re-request their images without being recreated.
    @Published private(set) var thumbnailRequestGeneration = 0
    @Published private(set) var viewerImages: [String: NSImage] = [:]
    @Published private(set) var selectedResources: [PhotoAssetResourceRecord] = []
    @Published private(set) var selectedTechnicalMetadata: PhotoTechnicalMetadata?
    @Published private(set) var selectedTextMetadata: PhotoCatalogTextMetadata?
    @Published private(set) var selectedTextMetadataError: String?
    @Published private(set) var textMetadataRevision = 0
    @Published private(set) var isLoadingTechnicalMetadata = false
    @Published private(set) var isLoading = false
    @Published private(set) var isEnrichingFilenames = false
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: PhotoResourceExportProgress?
    @Published private(set) var lastExportManifest: PhotoResourceExportManifest?
    @Published private(set) var lastExportDirectory: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedAlbumID: String?
    @Published private(set) var selectedAlbumAssetIDs: Set<String>?

    @Published var selectedAssetID: String?
    @Published var allowICloudDownload = false

    var visibleAssets: [PhotoAssetSummary] {
        guard let selectedAlbumAssetIDs else { return assets }
        return assets.filter { selectedAlbumAssetIDs.contains($0.id) }
    }

    var selectedTransferFidelity: PhotoAssetTransferFidelity? {
        guard let selectedAssetID,
              let asset = assets.first(where: { $0.id == selectedAssetID }),
              !selectedResources.isEmpty else { return nil }
        return provider.transferFidelity(for: asset, resources: selectedResources)
    }

    init() {
        authorization = provider.authorizationStatus()
        photoLibraryChangeObserver = SystemPhotoLibraryChangeObserver()
        photoLibraryChangeObserver.viewModel = self
        PHPhotoLibrary.shared().register(photoLibraryChangeObserver)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(photoLibraryChangeObserver)
    }

    func refreshAuthorizationStatus() {
        authorization = provider.authorizationStatus()
    }

    func requestAccessAndLoad() async {
        errorMessage = nil
        authorization = await provider.requestAuthorization()
        guard authorization.permitsReading else { return }
        loadLibrary()
    }

    func loadLibrary(showLoadingIndicator: Bool = true) {
        cancelAllImageRequests()
        filenameEnrichmentTask?.cancel()
        filenameEnrichmentTask = nil
        isEnrichingFilenames = false
        let previouslySelectedAssetID = selectedAssetID
        let previousAssetIDs = assets.map(\.id)
        let previousAlbumAssetIDs = selectedAlbumAssetIDs
        let generation = UUID()
        loadGeneration = generation
        errorMessage = nil
        if showLoadingIndicator { isLoading = true }
        defer {
            if showLoadingIndicator { isLoading = false }
        }

        do {
            authorization = provider.authorizationStatus()
            assetCount = try provider.assetCount()
            assets = try provider.fetchAssets()
            gridContentRevision &+= 1
            collections = try provider.fetchUserCollectionHierarchy()
            selectedAssetID = previouslySelectedAssetID.flatMap { selectedID in
                assets.contains(where: { $0.id == selectedID }) ? selectedID : nil
            }
            refreshSelectedAlbumFilter()
            if showLoadingIndicator
                || previousAssetIDs != assets.map(\.id)
                || previousAlbumAssetIDs != selectedAlbumAssetIDs {
                catalogRevision &+= 1
            }
            loadSelectedAssetResources()
            loadSelectedAssetTechnicalMetadata()
            selectedTextMetadata = nil
            selectedTextMetadataError = nil
            textMetadataRevision &+= 1
            startFilenameEnrichment(for: assets, generation: generation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectAsset(_ identifier: String) {
        selectedAssetID = identifier
        selectedTextMetadata = nil
        selectedTextMetadataError = nil
        loadSelectedAssetResources()
        loadSelectedAssetTechnicalMetadata()
    }

    func clearSelectedAsset() {
        selectedAssetID = nil
        selectedTextMetadata = nil
        selectedTextMetadataError = nil
        loadSelectedAssetResources()
        loadSelectedAssetTechnicalMetadata()
    }

    func selectAlbum(_ identifier: String?) {
        guard selectedAlbumID != identifier
                || (identifier != nil && selectedAlbumAssetIDs == nil) else {
            return
        }
        selectedAlbumID = identifier
        refreshSelectedAlbumFilter()
    }

    private func refreshSelectedAlbumFilter() {
        guard let selectedAlbumID else {
            selectedAlbumAssetIDs = nil
            return
        }
        do {
            let identifiers = try provider.fetchAssetIdentifiers(inAlbum: selectedAlbumID)
            selectedAlbumAssetIDs = identifiers
            if let selectedAssetID, !identifiers.contains(selectedAssetID) {
                self.selectedAssetID = nil
                loadSelectedAssetResources()
                loadSelectedAssetTechnicalMetadata()
            }
        } catch {
            selectedAlbumAssetIDs = []
            errorMessage = error.localizedDescription
        }
    }

    func requestThumbnail(for asset: PhotoAssetSummary, size: CGSize, consumerID: UUID) {
        thumbnailConsumers[asset.id, default: []].insert(consumerID)
        if thumbnails[asset.id] != nil,
           let cachedSize = thumbnailImageSizes[asset.id],
           cachedSize.width >= size.width,
           cachedSize.height >= size.height {
            touchThumbnailCacheEntry(asset.id)
            return
        }
        if thumbnailRequestTokens[asset.id] != nil {
            if let pendingSize = thumbnailRequestSizes[asset.id],
               pendingSize.width >= size.width,
               pendingSize.height >= size.height {
                return
            }
            thumbnailRequestTokens[asset.id] = nil
            thumbnailRequestSizes[asset.id] = nil
            if let requestID = thumbnailRequestIDs.removeValue(forKey: asset.id) {
                provider.cancelThumbnailRequest(requestID)
            }
        }

        let token = UUID()
        thumbnailRequestTokens[asset.id] = token
        thumbnailRequestSizes[asset.id] = size
        do {
            let requestID = try provider.requestThumbnail(
                for: asset.id,
                targetSize: size,
                networkAccessAllowed: false
            ) { [weak self] image, info in
                Task { @MainActor in
                    guard let self,
                          self.thumbnailRequestTokens[asset.id] == token else { return }
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    if let image, !isDegraded || self.thumbnails[asset.id] == nil {
                        self.thumbnails[asset.id] = image
                        self.thumbnailSlots[asset.id]?.update(image)
                        self.touchThumbnailCacheEntry(asset.id)
                        if !isDegraded {
                            self.thumbnailImageSizes[asset.id] = size
                        }
                        self.trimThumbnailCacheIfNeeded()
                    }
                    guard !isDegraded else { return }
                    self.thumbnailRequestTokens[asset.id] = nil
                    self.thumbnailRequestIDs[asset.id] = nil
                    self.thumbnailRequestSizes[asset.id] = nil
                }
            }
            // PhotoKit is allowed to invoke a result handler before returning.
            // Do not resurrect a request that was invalidated synchronously.
            if thumbnailRequestTokens[asset.id] == token {
                thumbnailRequestIDs[asset.id] = requestID
            }
        } catch {
            thumbnailRequestTokens[asset.id] = nil
            thumbnailRequestSizes[asset.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    func releaseThumbnail(for assetIdentifier: String, consumerID: UUID) {
        guard var consumers = thumbnailConsumers[assetIdentifier] else { return }
        consumers.remove(consumerID)
        if !consumers.isEmpty {
            thumbnailConsumers[assetIdentifier] = consumers
            return
        }
        thumbnailConsumers[assetIdentifier] = nil
        thumbnailRequestTokens[assetIdentifier] = nil
        thumbnailRequestSizes[assetIdentifier] = nil
        if let requestID = thumbnailRequestIDs.removeValue(forKey: assetIdentifier) {
            provider.cancelThumbnailRequest(requestID)
        }
    }

    func thumbnailSlot(for assetIdentifier: String) -> SystemPhotoThumbnailSlot {
        if let slot = thumbnailSlots[assetIdentifier] {
            return slot
        }
        let slot = SystemPhotoThumbnailSlot(image: thumbnails[assetIdentifier])
        thumbnailSlots[assetIdentifier] = slot
        return slot
    }

    func requestViewerImage(
        for asset: PhotoAssetSummary,
        size: CGSize = CGSize(width: 4_096, height: 4_096)
    ) {
        if viewerImages[asset.id] != nil,
           let cachedSize = viewerImageSizes[asset.id],
           cachedSize.width >= size.width,
           cachedSize.height >= size.height {
            touchViewerCacheEntry(asset.id)
            return
        }
        if viewerRequestIDs[asset.id] != nil {
            if let pendingSize = viewerRequestSizes[asset.id],
               pendingSize.width >= size.width,
               pendingSize.height >= size.height {
                return
            }
            cancelViewerImageRequest(for: asset.id)
        }

        let token = UUID()
        viewerRequestTokens[asset.id] = token
        viewerRequestSizes[asset.id] = size
        do {
            let requestID = try provider.requestViewerImage(
                for: asset.id,
                targetSize: size
            ) { [weak self] image, info in
                Task { @MainActor in
                    guard let self,
                          self.viewerRequestTokens[asset.id] == token else { return }
                    let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                    let hasError = info?[PHImageErrorKey] != nil
                    guard !isDegraded else { return }

                    self.viewerRequestTokens[asset.id] = nil
                    self.viewerRequestIDs[asset.id] = nil
                    self.viewerRequestSizes[asset.id] = nil
                    guard !wasCancelled, !hasError, let image else { return }
                    self.viewerImages[asset.id] = image
                    self.viewerImageSizes[asset.id] = size
                    self.touchViewerCacheEntry(asset.id)
                    self.trimViewerCacheIfNeeded()
                }
            }
            // PhotoKit is allowed to invoke a result handler before returning.
            // Do not resurrect a request that already completed synchronously.
            if viewerRequestTokens[asset.id] == token {
                viewerRequestIDs[asset.id] = requestID
            }
        } catch {
            viewerRequestTokens[asset.id] = nil
            viewerRequestSizes[asset.id] = nil
            errorMessage = error.localizedDescription
        }
    }

    static func viewerTargetSize(for viewportSize: CGSize, displayScale: CGFloat) -> CGSize {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            return CGSize(
                width: maximumViewerPixelLength,
                height: maximumViewerPixelLength
            )
        }
        let scale = max(displayScale, 1)
        let physicalSize = CGSize(
            width: viewportSize.width * scale,
            height: viewportSize.height * scale
        )
        let longestEdge = max(physicalSize.width, physicalSize.height)
        let downscale = min(1, maximumViewerPixelLength / longestEdge)
        return CGSize(
            width: ceil(physicalSize.width * downscale),
            height: ceil(physicalSize.height * downscale)
        )
    }

    func cancelViewerImageRequest(for assetIdentifier: String) {
        viewerRequestTokens[assetIdentifier] = nil
        viewerRequestSizes[assetIdentifier] = nil
        if let requestID = viewerRequestIDs.removeValue(forKey: assetIdentifier) {
            provider.cancelViewerImageRequest(requestID)
        }
    }

    private func cancelAllViewerRequests() {
        let requestIDs = Array(viewerRequestIDs.values)
        viewerRequestIDs.removeAll()
        viewerRequestTokens.removeAll()
        viewerRequestSizes.removeAll()
        requestIDs.forEach(provider.cancelViewerImageRequest)
    }

    private func cancelAllThumbnailRequests() {
        let requestIDs = Array(thumbnailRequestIDs.values)
        thumbnailRequestIDs.removeAll()
        thumbnailRequestTokens.removeAll()
        thumbnailRequestSizes.removeAll()
        requestIDs.forEach(provider.cancelThumbnailRequest)
    }

    private func cancelAllImageRequests() {
        cancelAllThumbnailRequests()
        cancelAllViewerRequests()
    }

    private func invalidateImageCaches() {
        cancelAllImageRequests()
        thumbnails.removeAll()
        thumbnailImageSizes.removeAll()
        thumbnailCacheOrder.removeAll()
        thumbnailSlots.values.forEach { $0.update(nil) }
        thumbnailRequestGeneration &+= 1
        viewerImages.removeAll()
        viewerImageSizes.removeAll()
        viewerCacheOrder.removeAll()
    }

    /// Coalesce a burst of Photos edits into one catalog refresh. The fetch
    /// cancels old image requests; deletion-only changes keep surviving images.
    func refreshAfterTransfer() {
        schedulePhotoLibraryChangeReload()
    }

    fileprivate func schedulePhotoLibraryChangeReload() {
        photoLibraryChangeReloadTask?.cancel()
        let generation = UUID()
        photoLibraryChangeGeneration = generation
        photoLibraryChangeReloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: Self.changeReloadDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  self.photoLibraryChangeGeneration == generation else { return }
            self.reloadForPhotoLibraryChange()
            if self.photoLibraryChangeGeneration == generation {
                self.photoLibraryChangeReloadTask = nil
            }
        }
    }

    private func reloadForPhotoLibraryChange() {
        let previousAssets = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        loadLibrary(showLoadingIndicator: false)
        guard errorMessage == nil else { return }

        let remainingIDs = Set(assets.map(\.id))
        let removedIDs = Set(previousAssets.keys).subtracting(remainingIDs)
        let survivingAssetsUnchanged = assets.allSatisfy { asset in
            guard let previous = previousAssets[asset.id] else { return false }
            return previous.replacingOriginalFilename(asset.originalFilename) == asset
        }
        if removedIDs.isEmpty,
           previousAssets.count == assets.count,
           survivingAssetsUnchanged {
            thumbnailRequestGeneration &+= 1
            return
        }
        let hasOnlyRemovals = !removedIDs.isEmpty
            && remainingIDs.isSubset(of: Set(previousAssets.keys))
        guard hasOnlyRemovals else {
            invalidateImageCaches()
            return
        }

        let changedIDs = Set(assets.compactMap { asset -> String? in
            guard let previous = previousAssets[asset.id],
                  previous.replacingOriginalFilename(asset.originalFilename) != asset else {
                return nil
            }
            return asset.id
        })
        for identifier in removedIDs.union(changedIDs) {
            thumbnails.removeValue(forKey: identifier)
            thumbnailImageSizes.removeValue(forKey: identifier)
            thumbnailSlots[identifier]?.update(nil)
            viewerImages.removeValue(forKey: identifier)
            viewerImageSizes.removeValue(forKey: identifier)
        }
        for identifier in removedIDs {
            thumbnailSlots.removeValue(forKey: identifier)
        }
        let invalidatedIDs = removedIDs.union(changedIDs)
        thumbnailCacheOrder.removeAll { invalidatedIDs.contains($0) }
        viewerCacheOrder.removeAll { invalidatedIDs.contains($0) }
        // loadLibrary cancels in-flight requests. Retained cells need to retry
        // only missing images; cached thumbnails stay visible.
        thumbnailRequestGeneration &+= 1
    }

    private func touchViewerCacheEntry(_ assetIdentifier: String) {
        viewerCacheOrder.removeAll { $0 == assetIdentifier }
        viewerCacheOrder.append(assetIdentifier)
    }

    private func touchThumbnailCacheEntry(_ assetIdentifier: String) {
        thumbnailCacheOrder.removeAll { $0 == assetIdentifier }
        thumbnailCacheOrder.append(assetIdentifier)
    }

    private func trimThumbnailCacheIfNeeded() {
        while thumbnailCacheOrder.count > Self.thumbnailCacheLimit {
            let evictedIdentifier = thumbnailCacheOrder.removeFirst()
            thumbnails[evictedIdentifier] = nil
            thumbnailImageSizes[evictedIdentifier] = nil
            thumbnailSlots[evictedIdentifier]?.update(nil)
        }
    }

    private func trimViewerCacheIfNeeded() {
        while viewerCacheOrder.count > Self.viewerCacheLimit {
            let evictedIdentifier = viewerCacheOrder.removeFirst()
            viewerImages[evictedIdentifier] = nil
            viewerImageSizes[evictedIdentifier] = nil
        }
    }

    func exportSelectedAsset() {
        guard let selectedAssetID, !isExporting else { return }
        errorMessage = nil
        isExporting = true
        exportProgress = nil
        lastExportManifest = nil
        lastExportDirectory = nil

        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let root = try Self.stagingRoot()
                let manifest = try await provider.exportResources(
                    for: selectedAssetID,
                    to: root,
                    networkAccessAllowed: allowICloudDownload
                ) { [weak self] progress in
                    Task { @MainActor in self?.exportProgress = progress }
                }
                lastExportManifest = manifest
                lastExportDirectory = root.appendingPathComponent(manifest.jobID.uuidString, isDirectory: true)
            } catch is CancellationError {
                errorMessage = "Export cancelled. Partial staging data was retained for inspection."
            } catch {
                errorMessage = error.localizedDescription
            }
            isExporting = false
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func loadSelectedAssetResources() {
        resourceInventoryTask?.cancel()
        resourceInventoryTask = nil
        selectedResources = []
        let generation = UUID()
        resourceInventoryGeneration = generation
        guard let selectedAssetID else {
            return
        }

        resourceInventoryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.selectedAssetID == selectedAssetID,
                   self.resourceInventoryGeneration == generation {
                    self.resourceInventoryTask = nil
                }
            }
            do {
                let resources = try await Task.detached(priority: .utility) {
                    try SystemPhotoLibraryProvider.resourceInventoryOffMain(
                        for: selectedAssetID
                    )
                }.value
                guard !Task.isCancelled,
                      self.selectedAssetID == selectedAssetID,
                      self.resourceInventoryGeneration == generation else { return }
                self.selectedResources = resources
            } catch is CancellationError {
                return
            } catch {
                guard self.selectedAssetID == selectedAssetID,
                      self.resourceInventoryGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadSelectedAssetTechnicalMetadata() {
        technicalMetadataTask?.cancel()
        technicalMetadataTask = nil
        selectedTechnicalMetadata = nil
        let generation = UUID()
        technicalMetadataGeneration = generation
        guard let selectedAssetID else {
            isLoadingTechnicalMetadata = false
            return
        }

        isLoadingTechnicalMetadata = true
        technicalMetadataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.selectedAssetID == selectedAssetID,
                   self.technicalMetadataGeneration == generation {
                    self.isLoadingTechnicalMetadata = false
                    self.technicalMetadataTask = nil
                }
            }
            do {
                let metadata = try await self.provider.technicalMetadata(
                    for: selectedAssetID,
                    networkAccessAllowed: self.allowICloudDownload
                )
                guard !Task.isCancelled,
                      self.selectedAssetID == selectedAssetID,
                      self.technicalMetadataGeneration == generation else { return }
                self.selectedTechnicalMetadata = metadata
            } catch is CancellationError {
                return
            } catch {
                guard self.selectedAssetID == selectedAssetID,
                      self.technicalMetadataGeneration == generation else { return }
                self.errorMessage = "Could not read photo metadata: \(error.localizedDescription)"
            }
        }
    }

    func loadSelectedTextMetadata(registry: LibraryRegistry, libraryID: LibraryID) async {
        guard let selectedAssetID,
              let asset = assets.first(where: { $0.id == selectedAssetID }) else {
            selectedTextMetadata = nil
            selectedTextMetadataError = nil
            return
        }
        selectedTextMetadata = nil
        selectedTextMetadataError = nil
        do {
            let metadata = try await registry.withReadAccessOffMain(to: libraryID) { url in
                try DirectLibraryCatalog.readTextMetadata(
                    from: url,
                    assetIdentifier: selectedAssetID,
                    expectedDate: asset.creationDate,
                    expectedWidth: asset.pixelWidth,
                    expectedHeight: asset.pixelHeight
                )
            }
            guard !Task.isCancelled, self.selectedAssetID == selectedAssetID else { return }
            selectedTextMetadata = metadata
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.selectedAssetID == selectedAssetID else { return }
            selectedTextMetadataError = "Could not read Photos title, caption, or keywords: \(error.localizedDescription)"
        }
    }

    private func startFilenameEnrichment(
        for catalog: [PhotoAssetSummary],
        generation: UUID
    ) {
        guard !catalog.isEmpty else {
            isEnrichingFilenames = false
            return
        }

        isEnrichingFilenames = true
        filenameEnrichmentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if loadGeneration == generation {
                    isEnrichingFilenames = false
                    filenameEnrichmentTask = nil
                }
            }
            var enrichedCatalog = catalog
            let indicesByID = Dictionary(
                uniqueKeysWithValues: catalog.enumerated().map { ($0.element.id, $0.offset) }
            )

            for batchStart in stride(
                from: 0,
                to: catalog.count,
                by: Self.filenameBatchSize
            ) {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                let batchEnd = min(batchStart + Self.filenameBatchSize, catalog.count)
                let identifiers = catalog[batchStart..<batchEnd].map(\.id)

                do {
                    let filenames = try await Task.detached(priority: .utility) {
                        try SystemPhotoLibraryProvider.fetchOriginalFilenames(
                            for: identifiers
                        )
                    }.value
                    guard !Task.isCancelled, loadGeneration == generation else { return }

                    var updates: [PhotoAssetSummary] = []
                    updates.reserveCapacity(filenames.count)
                    for (identifier, filename) in filenames {
                        guard let index = indicesByID[identifier] else { continue }
                        let updated = enrichedCatalog[index]
                            .replacingOriginalFilename(filename)
                        enrichedCatalog[index] = updated
                        updates.append(updated)
                    }
                    if !updates.isEmpty {
                        searchAssetUpdates.send(updates)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard loadGeneration == generation else { return }
                    errorMessage = "Could not finish System Library filename indexing: \(error.localizedDescription)"
                    break
                }
            }

            guard !Task.isCancelled, loadGeneration == generation else { return }
            assets = enrichedCatalog
            gridContentRevision &+= 1
        }
    }

    private static func stagingRoot() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = applicationSupport
            .appendingPathComponent("Photo Libraries", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
