import Combine
import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

/// Releases the transfer task when a synchronous catalog read has not returned
/// yet. Cancellation wins over late lookup results.
nonisolated private final class TransferLookupCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

nonisolated enum TransferredLibraryChange: Sendable {
    case system
    case registered(LibraryID)
}

@MainActor
final class PhotoTransferCoordinator: ObservableObject {
    nonisolated static func needsTransferAuthorization(_ descriptor: LibraryDescriptor) -> Bool {
        guard let bookmark = descriptor.writeBookmarkData else { return true }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), !isStale,
              url.standardizedFileURL == URL(
                fileURLWithPath: descriptor.metadata.lastKnownPath
              ).standardizedFileURL,
              url.startAccessingSecurityScopedResource() else {
            return true
        }
        url.stopAccessingSecurityScopedResource()
        return false
    }

    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var resultMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingSystemSourceDeletion: PendingSystemSourceDeletion?
    @Published private(set) var pendingRegisteredSourceDeletion: PendingRegisteredSourceDeletion?
    @Published private(set) var copyCompletedCount = 0
    @Published private(set) var copyTotalCount = 0
    @Published private(set) var skippedSystemSources: [String] = []
    @Published private(set) var copiedWithLimitations: [String] = []
    @Published private(set) var deletionWarnings: [String] = []
    let libraryContentDidChange = PassthroughSubject<TransferredLibraryChange, Never>()

    private let systemProvider = SystemPhotoLibraryProvider()
    private var operationTask: Task<Void, Never>?
    private var pendingDeletionDestination: RegisteredLibrary?
    private var pendingSystemSourceAssets: [PhotoAssetSummary] = []
    private var pendingSystemSourceBookmark: Data?
    private var pendingRegisteredDeletionRegistry: LibraryRegistry?

    func transferSystemAsset(
        _ asset: PhotoAssetSummary,
        resources: [PhotoAssetResourceRecord],
        to destination: RegisteredLibrary,
        registry: LibraryRegistry,
        store: LibraryPreviewStore,
        allowICloudDownload: Bool
    ) {
        transferSystemAssets(
            [asset],
            preloadedResources: [asset.id: resources],
            to: destination,
            registry: registry,
            store: store,
            allowICloudDownload: allowICloudDownload
        )
    }

    func transferSystemAssets(
        _ assets: [PhotoAssetSummary],
        preloadedResources: [String: [PhotoAssetResourceRecord]] = [:],
        to destination: RegisteredLibrary,
        registry: LibraryRegistry,
        store: LibraryPreviewStore,
        allowICloudDownload: Bool
    ) {
        guard !assets.isEmpty else { return }
        guard !isWorking,
              pendingSystemSourceDeletion == nil,
              pendingRegisteredSourceDeletion == nil else {
            errorMessage = PhotoTransferError.operationInProgress.localizedDescription
            return
        }
        guard let writeBookmark = destination.descriptor.writeBookmarkData,
              !Self.needsTransferAuthorization(destination.descriptor) else {
            beginOperation()
            errorMessage = "Copy not started: \(destination.descriptor.metadata.displayName) has no usable transfer access. No destination photo was imported and no System Library source was deleted."
            finishOperation()
            return
        }
        beginOperation()
        copyTotalCount = assets.count
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.finishOperation()
                self.libraryContentDidChange.send(.registered(destination.id))
            }
            var currentFilename = "preparing the destination library"
            var createdItemCount = 0
            var verifiedLivePhotoCount = 0
            var deletionCandidates: [PendingSystemSourceDeletion.Source] = []
            var deletionWarnings: [String] = []
            do {
                let destinationName = destination.descriptor.metadata.displayName
                self.statusMessage = "Reading System Library album and text metadata…"
                guard let systemDescriptor = registry.descriptors.first(where: {
                    $0.kind.isSystemPhotoLibrary
                }) else {
                    throw PhotoTransferError.systemLibraryNotRegistered
                }
                let sourceMetadata = try await Self.systemTransferMetadataFromCatalog(
                    for: assets,
                    bookmarkData: systemDescriptor.bookmarkData
                )
                let sourceAlbums = sourceMetadata.albumsByAssetID
                var sourceIDsByPath: [[String]: String] = [:]
                for album in sourceAlbums.values.flatMap({ $0 }) {
                    let path = album.folderNames + [album.name]
                    if let previousID = sourceIDsByPath[path], previousID != album.sourceID {
                        throw PhotoTransferError.ambiguousSourceAlbums(path.joined(separator: " / "))
                    }
                    sourceIDsByPath[path] = album.sourceID
                }
                try Task.checkCancellation()
                self.statusMessage = "Reading \(destinationName) catalog…"
                let initialCatalog = try await Self.destinationCatalog(from: destination.descriptor)
                try Task.checkCancellation()
                let destinationProvider = RegisteredPhotoLibraryProvider(
                    bookmarkData: writeBookmark, permitsWrites: true
                )
                var knownDestinationIDs = Set(initialCatalog.items.map(\.id))
                let stagingRoot = try Self.stagingRoot()
                let batchDirectory = stagingRoot.appendingPathComponent(
                    "system-transfer-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: batchDirectory,
                    withIntermediateDirectories: false
                )
                defer { Self.removeStagingDirectory(batchDirectory) }

                for (index, asset) in assets.enumerated() {
                    try Task.checkCancellation()
                    currentFilename = asset.originalFilename.isEmpty
                        ? asset.mediaType.capitalized
                        : asset.originalFilename
                    self.statusMessage = "Transferring \(index + 1) of \(assets.count): \(currentFilename)…"
                    guard let sourceCaptureDate = asset.creationDate else {
                        self.skippedSystemSources.append(
                            "\(currentFilename): The System Library has no capture date to preserve."
                        )
                        self.copyCompletedCount = index + 1
                        continue
                    }
                    guard let sourceTextMetadata = sourceMetadata.textByAssetID[asset.id] else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "The System Library text metadata is missing for \(currentFilename)."
                        )
                    }
                    let resources: [PhotoAssetResourceRecord]
                    if let preloaded = preloadedResources[asset.id] {
                        resources = preloaded
                    } else {
                        resources = try await Task.detached(priority: .utility) {
                            try SystemPhotoLibraryProvider.resourceInventoryOffMain(for: asset.id)
                        }.value
                    }
                    let fidelity = self.systemProvider.transferFidelity(
                        for: asset,
                        resources: resources
                    )
                    let sourceLocation = try await Task.detached(priority: .utility) {
                        try SystemPhotoLibraryProvider.transferLocationOffMain(for: asset.id)
                    }.value
                    guard asset.mediaType == "image" || asset.mediaType == "video" else {
                        self.skippedSystemSources.append(
                            "\(currentFilename): Unsupported media type \(asset.mediaType)."
                        )
                        self.copyCompletedCount = index + 1
                        continue
                    }
                    let hasLivePhotoVideo = resources.contains {
                        $0.type == "pairedVideo" || $0.type == "fullSizePairedVideo"
                    }
                    let pairedVideo = resources.first { $0.type == "pairedVideo" }
                    let hasImageAdjustments: Bool
                    if asset.mediaType == "image" {
                        hasImageAdjustments = try await Task.detached(priority: .utility) {
                            try SystemPhotoLibraryProvider.hasAdjustmentsOffMain(for: asset.id)
                        }.value
                    } else {
                        hasImageAdjustments = false
                    }
                    if hasImageAdjustments && hasLivePhotoVideo {
                        self.skippedSystemSources.append(
                            "\(currentFilename): Edited Live Photo appearance cannot yet be paired and verified in the destination."
                        )
                        self.copyCompletedCount = index + 1
                        continue
                    }
                    let outcome: (createdItemCount: Int, importedItemIDs: [String])
                    var selectedResourceCount = 1
                    var sourceTechnicalMetadata: PhotoTechnicalMetadata?
                    if hasImageAdjustments {
                        sourceTechnicalMetadata = try await self.systemProvider.technicalMetadata(
                            for: asset.id,
                            networkAccessAllowed: allowICloudDownload
                        )
                        guard sourceTechnicalMetadata != nil else {
                            throw PhotoTransferError.sourceMetadataUnavailable
                        }
                        let originalEXIFPropertyList = try await Task.detached(priority: .utility) {
                            try await SystemPhotoLibraryProvider.originalEXIFPropertyListOffMain(
                                for: asset.id,
                                networkAccessAllowed: allowICloudDownload
                            )
                        }.value
                        guard let renderedOutcome = try await self.transferOneSystemAssetDirect(
                            asset, selectedResources: nil,
                            destination: destinationProvider,
                            albums: sourceAlbums[asset.id] ?? [],
                            textMetadata: sourceTextMetadata,
                            to: batchDirectory,
                            allowICloudDownload: allowICloudDownload,
                            sourceTechnicalMetadata: sourceTechnicalMetadata,
                            sourceLocation: sourceLocation,
                            originalEXIFPropertyList: originalEXIFPropertyList
                        ) else {
                            throw PhotoTransferError.noImportableResources
                        }
                        outcome = renderedOutcome
                    } else {
                        let originalType = asset.mediaType == "image" ? "photo" : "video"
                        guard let original = resources.first(where: { $0.type == originalType }) else {
                            self.skippedSystemSources.append(
                                "\(currentFilename): No original \(originalType) resource is available."
                            )
                            self.copyCompletedCount = index + 1
                            continue
                        }
                        if hasLivePhotoVideo && pairedVideo == nil {
                            self.skippedSystemSources.append(
                                "\(currentFilename): The original Live Photo paired video is unavailable."
                            )
                            self.copyCompletedCount = index + 1
                            continue
                        }
                        let selectedResources = [original] + (pairedVideo.map { [$0] } ?? [])
                        selectedResourceCount = selectedResources.count
                        guard let originalOutcome = try await self.transferOneSystemAssetDirect(
                            asset, selectedResources: selectedResources,
                            destination: destinationProvider,
                            albums: sourceAlbums[asset.id] ?? [],
                            textMetadata: sourceTextMetadata,
                            to: batchDirectory,
                            allowICloudDownload: allowICloudDownload,
                            sourceTechnicalMetadata: nil,
                            sourceLocation: sourceLocation,
                            originalEXIFPropertyList: nil
                        ) else {
                            self.skippedSystemSources.append(
                                "\(currentFilename): The source resource roles changed before import; no destination item was created for this attempt."
                            )
                            self.copyCompletedCount = index + 1
                            continue
                        }
                        outcome = originalOutcome
                    }
                    let importedID = outcome.importedItemIDs[0]
                    if let sourceTechnicalMetadata {
                        try store.seedTransferredCameraMetadata(
                            sourceTechnicalMetadata,
                            for: importedID,
                            libraryID: destination.id
                        )
                    }
                    guard let importedUUID = PhotosAssetIdentity.uuid(for: importedID),
                          knownDestinationIDs.insert(importedUUID).inserted else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "The destination photo ID was already present before the copy."
                        )
                    }
                    let resourceTypes = Set(resources.map(\.type))
                    let editedAppearanceCanReplaceSource = hasImageAdjustments
                        && !asset.representsBurst
                        && resourceTypes.contains("photo")
                        && resourceTypes.isSubset(of: [
                            "photo", "fullSizePhoto", "adjustmentData", "adjustmentBasePhoto"
                        ])
                    let verifiedLivePairCanReplaceSource = pairedVideo != nil
                        && !asset.representsBurst
                        && resourceTypes == Set(["photo", "pairedVideo"])
                        && resources.count == 2
                    let canOfferDeletion = fidelity.permitsAutomaticSystemSourceDeletion
                        || editedAppearanceCanReplaceSource
                        || verifiedLivePairCanReplaceSource
                    if canOfferDeletion {
                        deletionCandidates.append(.init(
                            assetIdentifier: asset.id,
                            displayName: currentFilename,
                            destinationItemIdentifier: importedID,
                            captureDate: sourceCaptureDate,
                            sourceModificationDate: asset.modificationDate,
                            sourceAlbums: sourceAlbums[asset.id] ?? []
                        ))
                        if editedAppearanceCanReplaceSource {
                            deletionWarnings.append(
                                "\(currentFilename): the original file and reversible edit history will be lost."
                            )
                        }
                        deletionWarnings.append(
                            "\(currentFilename): GPS altitude cannot be verified across libraries; review it before deleting the source."
                        )
                    }
                    createdItemCount += outcome.createdItemCount
                    if hasImageAdjustments {
                        self.copiedWithLimitations.append(
                            "\(currentFilename): Current edited appearance was copied as one image; the original file and reversible edit history were omitted."
                        )
                    } else if pairedVideo != nil {
                        verifiedLivePhotoCount += 1
                        if resources.count > selectedResourceCount {
                            self.copiedWithLimitations.append(
                                "\(currentFilename): The original Live Photo pair was verified; edited or other extra resources were omitted."
                            )
                        }
                    } else if let warning = fidelity.warning {
                        self.copiedWithLimitations.append("\(currentFilename): \(warning)")
                    }
                    self.copyCompletedCount = index + 1
                }

                let copiedSourceCount = assets.count - self.skippedSystemSources.count
                self.resultMessage = "Copied \(createdItemCount) destination item(s) with verified dates, favorites, GPS coordinates, titles, captions, and keywords from \(copiedSourceCount) selected photo(s) in \(destinationName), including \(verifiedLivePhotoCount) verified Live Photo pair(s). GPS altitude requires manual review before any source deletion. Skipped \(self.skippedSystemSources.count) photo(s); \(self.copiedWithLimitations.count) copy/copies omit additional resources or grouping. See transfer details."
                self.deletionWarnings = deletionWarnings
                if !deletionCandidates.isEmpty {
                    self.pendingDeletionDestination = destination
                    let candidateIDs = Set(deletionCandidates.map(\.assetIdentifier))
                    self.pendingSystemSourceAssets = assets.filter { candidateIDs.contains($0.id) }
                    self.pendingSystemSourceBookmark = systemDescriptor.bookmarkData
                    self.pendingSystemSourceDeletion = PendingSystemSourceDeletion(
                        sources: deletionCandidates,
                        destinationDisplayName: destinationName,
                        retainedSourceCount: assets.count - deletionCandidates.count,
                        deletionWarnings: deletionWarnings
                    )
                } else {
                    self.resultMessage? += " All System Library sources were retained."
                }
            } catch is CancellationError {
                self.errorMessage = "Transfer cancelled after \(self.copyCompletedCount) of \(assets.count) selected photo(s). Completed destination copies remain; no System Library source was deleted. Check Photos before retrying."
            } catch {
                let retryAdvice: String
                if currentFilename == "preparing the destination library" {
                    retryAdvice = "No destination import was started."
                } else if error is PhotoTechnicalMetadataEmbedder.Error {
                    retryAdvice = "This photo was not imported. Earlier completed copies remain in the destination."
                } else {
                    retryAdvice = "Check Photos before retrying because the last import may have partially completed."
                }
                self.errorMessage = "Transfer stopped after \(self.copyCompletedCount) of \(assets.count) selected photo(s) at \(currentFilename): \(error.localizedDescription) No System Library source was deleted. \(retryAdvice)"
            }
        }
    }

    private func transferOneSystemAssetDirect(
        _ asset: PhotoAssetSummary,
        selectedResources: [PhotoAssetResourceRecord]?,
        destination: RegisteredPhotoLibraryProvider,
        albums: [PhotoTransferAlbum],
        textMetadata: PhotoCatalogTextMetadata,
        to stagingRoot: URL,
        allowICloudDownload: Bool,
        sourceTechnicalMetadata: PhotoTechnicalMetadata?,
        sourceLocation: PhotoTransferLocation?,
        originalEXIFPropertyList: Data?
    ) async throws -> (createdItemCount: Int, importedItemIDs: [String])? {
        guard let captureDate = asset.creationDate else { return nil }
        let files: [URL]
        let sourceHashes: [String]
        let stagedDirectory: URL
        if let selectedResources {
            let current = try await Task.detached(priority: .utility) {
                try SystemPhotoLibraryProvider.resourceInventoryOffMain(for: asset.id)
            }.value
            guard selectedResources.allSatisfy(current.contains) else { return nil }
            let manifest = try await systemProvider.exportResources(
                for: asset.id, to: stagingRoot,
                networkAccessAllowed: allowICloudDownload,
                selectedResourceIndices: Set(selectedResources.map(\.index))
            )
            let expected = selectedResources.sorted { $0.index < $1.index }
            guard manifest.entries.count == expected.count,
                  manifest.entries.enumerated().allSatisfy({ index, entry in
                      entry.resourceIndex == expected[index].index
                          && entry.resourceType == expected[index].type
                          && entry.originalFilename == expected[index].originalFilename
                          && entry.byteCount > 0
                  }) else { return nil }
            stagedDirectory = stagingRoot.appendingPathComponent(
                manifest.jobID.uuidString, isDirectory: true
            )
            files = manifest.entries.map { stagedDirectory.appendingPathComponent($0.stagedFilename) }
            sourceHashes = manifest.entries.map(\.sha256).sorted()
        } else {
            let filename = asset.originalFilename.isEmpty ? "Photo" : asset.originalFilename
            let rendered = try await Task.detached(priority: .utility) {
                let file = try SystemPhotoLibraryProvider.exportCurrentAppearanceOffMain(
                    for: asset.id, displayFilename: filename, to: stagingRoot,
                    networkAccessAllowed: allowICloudDownload
                )
                return try sourceTechnicalMetadata.map {
                    try PhotoTechnicalMetadataEmbedder.embeddingCaptureMetadata(
                        $0, originalEXIFPropertyList: originalEXIFPropertyList,
                        location: sourceLocation, in: file
                    )
                } ?? file
            }.value
            stagedDirectory = rendered.deletingLastPathComponent()
            files = [rendered]
            sourceHashes = [try Self.sha256(of: rendered)]
        }
        defer { Self.removeStagingDirectory(stagedDirectory) }
        try Task.checkCancellation()
        let importedID = try await destination.importAsset(DirectLibraryImportRequest(
            resourcePaths: files.map(\.path),
            isLivePhoto: selectedResources?.contains(where: { $0.type == "pairedVideo" }) == true,
            captureDate: captureDate,
            isFavorite: asset.isFavorite,
            location: sourceLocation,
            albums: albums,
            textMetadata: textMetadata
        ))
        guard let importedUUID = PhotosAssetIdentity.uuid(for: importedID) else {
            throw PhotoTransferError.importEvidenceMismatch("The destination returned an invalid photo ID.")
        }
        let verifiedCatalog = try await destination.catalog()
        guard let verifiedText = verifiedCatalog.textMetadata(for: importedUUID),
              verifiedText.matches(textMetadata),
              albums.allSatisfy({ sourceAlbum in
                  verifiedCatalog.albums.contains {
                      $0.name == sourceAlbum.name
                          && $0.folderNames == sourceAlbum.folderNames
                          && $0.mediaItemIDs?.contains(importedUUID) == true
                  }
              }) else {
            throw PhotoTransferError.importEvidenceMismatch(
                "The destination photo, title, caption, keywords, or album membership is missing or differs."
            )
        }
        let verifyDirectory = stagingRoot.appendingPathComponent(
            "verify-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: verifyDirectory, withIntermediateDirectories: false)
        defer { Self.removeStagingDirectory(verifyDirectory) }
        let exported = try await destination.exportOriginalResources(
            for: importedUUID, to: verifyDirectory
        )
        let verifiedHashes = try exported.resourcePaths.map {
            try Self.sha256(of: URL(fileURLWithPath: $0))
        }.sorted()
        guard exported.resourcePaths.count == files.count,
              verifiedHashes == sourceHashes else {
            throw PhotoTransferError.importEvidenceMismatch("The destination original resources differ from the staged source.")
        }
        return (1, [importedID])
    }

    func copyRegisteredItemToSystemLibrary(
        _ item: PhotosAutomationMediaItem,
        source: RegisteredLibrary,
        registry: LibraryRegistry,
        store: LibraryPreviewStore
    ) {
        copyRegisteredItemsToSystemLibrary(
            [item],
            source: source,
            registry: registry,
            store: store
        )
    }

    func copyRegisteredItemsToSystemLibrary(
        _ items: [PhotosAutomationMediaItem],
        source: RegisteredLibrary,
        registry: LibraryRegistry,
        store: LibraryPreviewStore
    ) {
        guard !items.isEmpty else { return }
        guard !isWorking,
              pendingSystemSourceDeletion == nil,
              pendingRegisteredSourceDeletion == nil else {
            errorMessage = PhotoTransferError.operationInProgress.localizedDescription
            return
        }
        beginOperation()
        copyTotalCount = items.count
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.finishOperation()
                self.libraryContentDidChange.send(.system)
            }
            var currentFilename = "preparing the source library"
            var createdAssetCount = 0
            var compoundItemCount = 0
            var livePhotoCount = 0
            var deletionCandidates: [PendingRegisteredSourceDeletion.Source] = []

            do {
                let sourceName = source.descriptor.metadata.displayName
                guard let systemDescriptor = registry.descriptors.first(where: {
                    $0.kind.isSystemPhotoLibrary
                }) else {
                    throw PhotoTransferError.systemLibraryNotRegistered
                }
                self.statusMessage = "Reading \(sourceName) directly…"
                let sourceProvider = RegisteredPhotoLibraryProvider(
                    bookmarkData: source.descriptor.bookmarkData
                )
                let catalog = try await sourceProvider.catalog()
                let indexedAlbums = store.manifest(for: source.id)?.albums
                let canonicalIDs = catalog.items.compactMap { PhotosAssetIdentity.uuid(for: $0.id) }
                let currentIDs = Set(canonicalIDs)
                guard canonicalIDs.count == catalog.items.count,
                      currentIDs.count == catalog.items.count else {
                    throw PhotoTransferError.importEvidenceMismatch("The source catalog contains invalid or duplicate photo IDs.")
                }
                var selectedUUIDs = Set<String>()
                let resolvedItems = try items.map { item -> (item: PhotosAutomationMediaItem, uuid: String, albums: [PhotoTransferAlbum]) in
                    guard let uuid = PhotosAssetIdentity.uuid(for: item.id) else {
                        throw PhotosAssetIdentity.MappingError.invalidIdentifier(item.id)
                    }
                    guard selectedUUIDs.insert(uuid).inserted else {
                        throw PhotosAssetIdentity.MappingError.ambiguousUUID(uuid)
                    }
                    guard currentIDs.contains(uuid) else {
                        throw PhotosAssetIdentity.MappingError.missingAutomationIdentifier(item.id)
                    }
                    let memberships = try catalog.albums.compactMap { album -> PhotoTransferAlbum? in
                        guard let memberIDs = album.mediaItemIDs else {
                            throw PhotoTransferError.importEvidenceMismatch(
                                "The non-system source album membership is unavailable."
                            )
                        }
                        let canonicalMemberIDs = memberIDs.compactMap {
                            PhotosAssetIdentity.uuid(for: $0)
                        }
                        guard canonicalMemberIDs.count == memberIDs.count,
                              Set(canonicalMemberIDs).count == memberIDs.count else {
                            throw PhotoTransferError.ambiguousSourceAlbums(album.name)
                        }
                        guard canonicalMemberIDs.contains(uuid) else { return nil }
                        guard let folderNames = album.folderNames else {
                            throw PhotoTransferError.ambiguousSourceAlbums(album.name)
                        }
                        return PhotoTransferAlbum(
                            sourceID: album.id, name: album.name, folderNames: folderNames
                        )
                    }
                    let paths = memberships.map { $0.folderNames + [$0.name] }
                    guard Set(paths).count == paths.count else {
                        throw PhotoTransferError.ambiguousSourceAlbums(item.name)
                    }
                    if let indexedAlbums {
                        let indexedIDs = Set(indexedAlbums.filter {
                            $0.mediaItemIDs?.contains(where: {
                                PhotosAssetIdentity.uuid(for: $0) == uuid
                            }) == true
                        }.map(\.id))
                        guard indexedIDs == Set(memberships.map(\.sourceID)) else {
                            throw PhotoTransferError.importEvidenceMismatch(
                                "The source album memberships changed since indexing. Refresh this library before copying."
                            )
                        }
                    }
                    return (item, uuid, memberships)
                }
                var sourceAlbumIDsByPath: [[String]: String] = [:]
                for album in resolvedItems.flatMap(\.albums) {
                    let path = album.folderNames + [album.name]
                    if let previousID = sourceAlbumIDsByPath[path], previousID != album.sourceID {
                        throw PhotoTransferError.ambiguousSourceAlbums(path.joined(separator: " / "))
                    }
                    sourceAlbumIDsByPath[path] = album.sourceID
                }
                let stagingRoot = try Self.stagingRoot()
                let batchDirectory = stagingRoot.appendingPathComponent(
                    "registered-copy-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: batchDirectory,
                    withIntermediateDirectories: false
                )
                defer { Self.removeStagingDirectory(batchDirectory) }
                for (index, resolvedItem) in resolvedItems.enumerated() {
                    try Task.checkCancellation()
                    let item = resolvedItem.item
                    currentFilename = item.filename.isEmpty ? item.name : item.filename
                    guard let catalogItem = catalog.items.first(where: {
                        PhotosAssetIdentity.uuid(for: $0.id) == resolvedItem.uuid
                    }),
                          let sourceText = catalog.textMetadata(for: catalogItem.id) else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "The source title, caption, or keywords could not be read for \(currentFilename)."
                        )
                    }
                    self.statusMessage = "Copying \(index + 1) of \(items.count): exporting \(currentFilename)…"
                    let result = try await self.copyRegisteredItem(
                        sourceID: resolvedItem.uuid,
                        sourceProvider: sourceProvider,
                        sourceAlbums: resolvedItem.albums,
                        textMetadata: sourceText,
                        to: batchDirectory,
                        index: index + 1,
                        total: items.count
                    )
                    createdAssetCount += result.createdAssetCount
                    if result.isLivePhoto { livePhotoCount += 1 }
                    if result.hasUnpairedMultipleResources { compoundItemCount += 1 }
                    self.statusMessage = "Verifying System Library text metadata for \(currentFilename)…"
                    let destinationText = try await Self.systemTextMetadata(
                        for: result.destinationAssetIDs,
                        bookmarkData: systemDescriptor.bookmarkData
                    )
                    guard result.destinationAssetIDs.allSatisfy({
                        destinationText[$0]?.matches(sourceText) == true
                    }) else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "The System Library title, caption, or keywords differ for \(currentFilename). The non-system source was retained."
                        )
                    }
                    if result.hasUnpairedMultipleResources {
                        self.copiedWithLimitations.append(
                            "\(currentFilename): multiple original resources became separate System items; source deletion is unavailable."
                        )
                    }
                    if item.captureDate == nil {
                        self.copiedWithLimitations.append(
                            "\(currentFilename): the source catalog has no capture date; source deletion is unavailable."
                        )
                    }
                    if !result.hasUnpairedMultipleResources,
                       item.captureDate != nil {
                        deletionCandidates.append(.init(
                            sourceUUID: resolvedItem.uuid,
                            displayName: currentFilename,
                            destinationAssetIDs: result.destinationAssetIDs,
                            captureDate: item.captureDate,
                            location: result.sourceLocation,
                            isFavorite: result.sourceFavorite,
                            resourceHashes: result.resourceHashes,
                            sourceAlbums: resolvedItem.albums
                        ))
                    }
                    self.copyCompletedCount = index + 1
                }

                let livePhotoSummary = livePhotoCount > 0
                    ? " \(livePhotoCount) Live Photo pair(s) were verified as one item each."
                    : ""
                let pairingWarning = compoundItemCount > 0
                    ? " \(compoundItemCount) other source item(s) exported multiple resources, which were imported independently; verify RAW pairing or other grouping."
                    : ""
                self.resultMessage = "Copied \(items.count) selected photo(s) as \(createdAssetCount) new System Library item(s), including verified titles, captions, keywords, and album memberships, without opening Photos. \(deletionCandidates.count) source(s) qualify for optional deletion. Review GPS altitude before deleting sources.\(livePhotoSummary)\(pairingWarning)"
                let currentSource = registry.libraries.first(where: { $0.id == source.id })
                if !deletionCandidates.isEmpty,
                   let currentSource,
                   !Self.needsTransferAuthorization(currentSource.descriptor) {
                    self.pendingRegisteredDeletionRegistry = registry
                    self.pendingRegisteredSourceDeletion = PendingRegisteredSourceDeletion(
                        sourceLibraryID: source.id,
                        sourceDisplayName: sourceName,
                        sources: deletionCandidates
                    )
                } else if !deletionCandidates.isEmpty {
                    self.resultMessage? += " All non-system sources were retained because write access to \(sourceName) was unavailable."
                } else {
                    self.resultMessage? += " All non-system sources were retained because their fidelity could not be verified for deletion."
                }
            } catch is CancellationError {
                self.errorMessage = "Copy cancelled after \(self.copyCompletedCount) of \(items.count) selected photo(s). Completed copies remain; all non-system sources were retained. Check Photos before retrying."
            } catch {
                self.errorMessage = "Copy stopped after \(self.copyCompletedCount) of \(items.count) selected photo(s) at \(currentFilename): \(error.localizedDescription) All non-system sources were retained. Check Photos before retrying because the last import may have partially completed."
            }
        }
    }

    private func copyRegisteredItem(
        sourceID: String,
        sourceProvider: RegisteredPhotoLibraryProvider,
        sourceAlbums: [PhotoTransferAlbum],
        textMetadata: PhotoCatalogTextMetadata,
        to stagingRoot: URL,
        index: Int,
        total: Int
    ) async throws -> (
        createdAssetCount: Int,
        destinationAssetIDs: [String],
        sourceLocation: PhotoTransferLocation?,
        sourceFavorite: Bool,
        resourceHashes: [String],
        isLivePhoto: Bool,
        hasUnpairedMultipleResources: Bool
    ) {
        let exportDirectory = stagingRoot.appendingPathComponent(
            "source-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false)
        defer { Self.removeStagingDirectory(exportDirectory) }
        let exportResult = try await sourceProvider.exportOriginalResources(
            for: sourceID, to: exportDirectory
        )
        try Task.checkCancellation()
        let files = exportResult.resourcePaths.map { URL(fileURLWithPath: $0) }
        guard exportResult.sourceID == sourceID, !files.isEmpty else {
            throw PhotoTransferError.noImportableResources
        }
        guard let captureDate = exportResult.captureDate else {
            throw PhotoTransferError.sourceMetadataUnavailable
        }

        statusMessage = "Copying \(index) of \(total): importing into the System Photo Library…"
        let sourceLocation: PhotoTransferLocation?
        if let latitude = exportResult.latitude, let longitude = exportResult.longitude {
            sourceLocation = PhotoTransferLocation(latitude: latitude, longitude: longitude, altitude: nil)
        } else {
            sourceLocation = nil
        }
        let livePhotoFiles: (image: URL, video: URL)?
        if exportResult.isLivePhoto, files.count == 2 {
            let classified = try files.map { fileURL in
                (
                    url: fileURL,
                    type: try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
                        ?? UTType(filenameExtension: fileURL.pathExtension)
                )
            }
            let images = classified.filter { $0.type?.conforms(to: .image) == true }
            let movies = classified.filter { $0.type?.conforms(to: .movie) == true }
            livePhotoFiles = images.count == 1 && movies.count == 1
                ? (images[0].url, movies[0].url)
                : nil
        } else {
            livePhotoFiles = nil
        }
        guard !exportResult.isLivePhoto || livePhotoFiles != nil else {
            throw PhotoTransferError.importEvidenceMismatch(
                "The original Live Photo resources could not be classified as one image and one paired video."
            )
        }
        let importResult: PhotoKitImportResult
        if let livePhotoFiles {
            importResult = try await systemProvider.importLivePhotoPair(
                imageURL: livePhotoFiles.image,
                pairedVideoURL: livePhotoFiles.video,
                creationDate: captureDate,
                location: sourceLocation,
                isFavorite: exportResult.isFavorite,
                textMetadata: textMetadata
            )
        } else {
            importResult = try await systemProvider.importFilesAsIndependentAssets(
                files,
                creationDate: captureDate,
                location: sourceLocation,
                isFavorite: exportResult.isFavorite,
                textMetadata: textMetadata
            )
        }
        guard importResult.isVerifiedCreation else {
            throw PhotoTransferError.importCreationNotVerified
        }
        try systemProvider.verifyTransferProperties(
            for: importResult.createdAssetIdentifiers,
            creationDate: captureDate,
            location: sourceLocation,
            isFavorite: exportResult.isFavorite
        )
        let sourceHashes = try files.map(Self.sha256).sorted()
        if (files.count == 1 || livePhotoFiles != nil),
           let importedID = importResult.createdAssetIdentifiers.first {
            let importedResources = try await systemProvider.exportResources(
                for: importedID,
                to: stagingRoot
            )
            let importedDirectory = stagingRoot.appendingPathComponent(
                importedResources.jobID.uuidString,
                isDirectory: true
            )
            defer { Self.removeStagingDirectory(importedDirectory) }
            let destinationHashes = importedResources.entries.map(\.sha256).sorted()
            guard sourceHashes == destinationHashes else {
                throw PhotoTransferError.importEvidenceMismatch(
                    "The System Library original resources differ from the source files, including their embedded metadata."
                )
            }
        }
        for album in sourceAlbums {
            statusMessage = "Adding photo \(index) of \(total) to \(album.name)…"
            try await systemProvider.addAssets(
                importResult.createdAssetIdentifiers, to: album
            )
        }
        return (
            createdAssetCount: importResult.createdAssetIdentifiers.count,
            destinationAssetIDs: importResult.createdAssetIdentifiers,
            sourceLocation: sourceLocation,
            sourceFavorite: exportResult.isFavorite,
            resourceHashes: sourceHashes,
            isLivePhoto: livePhotoFiles != nil,
            hasUnpairedMultipleResources: livePhotoFiles == nil && files.count > 1
        )
    }

    func confirmRegisteredSourceDeletion() {
        guard !isWorking,
              let pending = pendingRegisteredSourceDeletion,
              let registry = pendingRegisteredDeletionRegistry else { return }
        pendingRegisteredSourceDeletion = nil
        pendingRegisteredDeletionRegistry = nil
        beginOperation(clearResult: false)
        statusMessage = "Rechecking both libraries before deleting sources…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.finishOperation()
                self.libraryContentDidChange.send(.registered(pending.sourceLibraryID))
            }
            var deletionRequested = false
            do {
                guard let source = registry.libraries.first(where: {
                    $0.id == pending.sourceLibraryID
                }), let writeBookmark = source.descriptor.writeBookmarkData,
                   !Self.needsTransferAuthorization(source.descriptor) else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "The source library's transfer access is unavailable. No source deletion was requested."
                    )
                }
                let sourceProvider = RegisteredPhotoLibraryProvider(
                    bookmarkData: writeBookmark, permitsWrites: true
                )
                let sourceCatalog = try await sourceProvider.catalog()
                let sourceIDs = pending.sources.map(\.sourceUUID)
                guard Set(sourceIDs).count == sourceIDs.count,
                      pending.sources.allSatisfy({ item in
                          sourceCatalog.items.contains {
                              $0.id == item.sourceUUID
                                  && $0.captureDate == item.captureDate
                                  && $0.isFavorite == item.isFavorite
                          } && item.sourceAlbums.allSatisfy { album in
                              sourceCatalog.albums.contains {
                                  $0.id == album.sourceID
                                      && $0.mediaItemIDs?.contains(item.sourceUUID) == true
                              }
                          }
                      }) else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "A source photo or source album changed since copying."
                    )
                }
                let destinationIDs = pending.sources.flatMap(\.destinationAssetIDs)
                guard let systemDescriptor = registry.descriptors.first(where: {
                    $0.kind.isSystemPhotoLibrary
                }) else {
                    throw PhotoTransferError.systemLibraryNotRegistered
                }
                let destinationText = try await Self.systemTextMetadata(
                    for: destinationIDs,
                    bookmarkData: systemDescriptor.bookmarkData
                )
                let destinationAlbums = try await Self.systemAlbumMemberships(for: destinationIDs)
                for item in pending.sources {
                    guard let catalogItem = sourceCatalog.items.first(where: {
                        PhotosAssetIdentity.uuid(for: $0.id) == item.sourceUUID
                    }),
                          let sourceText = sourceCatalog.textMetadata(for: catalogItem.id),
                          item.destinationAssetIDs.allSatisfy({
                              destinationText[$0]?.matches(sourceText) == true
                          }) else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "A source title, caption, or keyword differs from the System copy. No source deletion was requested."
                        )
                    }
                    guard let captureDate = item.captureDate else {
                        throw PhotoTransferError.sourceMetadataUnavailable
                    }
                    try self.systemProvider.verifyTransferProperties(
                        for: item.destinationAssetIDs,
                        creationDate: captureDate,
                        location: item.location,
                        isFavorite: item.isFavorite
                    )
                    let observedPaths = Set(item.destinationAssetIDs.flatMap {
                        destinationAlbums[$0] ?? []
                    }.map { $0.folderNames + [$0.name] })
                    let requiredPaths = Set(item.sourceAlbums.map {
                        $0.folderNames + [$0.name]
                    })
                    guard requiredPaths.isSubset(of: observedPaths) else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "A System Library album membership changed after copying."
                        )
                    }
                    let staging = try Self.stagingRoot().appendingPathComponent(
                        "delete-check-\(UUID().uuidString)", isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: staging, withIntermediateDirectories: false
                    )
                    defer { Self.removeStagingDirectory(staging) }
                    let sourceExport = try await sourceProvider.exportOriginalResources(
                        for: item.sourceUUID, to: staging
                    )
                    let currentLocation: PhotoTransferLocation? = {
                        guard let latitude = sourceExport.latitude,
                              let longitude = sourceExport.longitude else { return nil }
                        return PhotoTransferLocation(
                            latitude: latitude, longitude: longitude, altitude: nil
                        )
                    }()
                    let currentSourceHashes = try sourceExport.resourcePaths.map {
                        try Self.sha256(of: URL(fileURLWithPath: $0))
                    }.sorted()
                    guard currentSourceHashes == item.resourceHashes,
                          currentLocation == item.location,
                          item.destinationAssetIDs.count == 1,
                          let destinationID = item.destinationAssetIDs.first else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "The source resources changed after copying."
                        )
                    }
                    let destinationExport = try await self.systemProvider.exportResources(
                        for: destinationID, to: staging
                    )
                    guard destinationExport.entries.map(\.sha256).sorted() == item.resourceHashes else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "The System Library copy changed after verification."
                        )
                    }
                }
                try Task.checkCancellation()
                deletionRequested = true
                let deleted = try await sourceProvider.deleteAssets(
                    DirectLibraryDeletionRequest(
                        sourceUUIDs: sourceIDs,
                        albums: pending.sources.flatMap(\.sourceAlbums)
                    )
                )
                guard deleted == sourceIDs.count else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "The number of deleted source photos could not be verified."
                    )
                }
                self.resultMessage = "Move complete: deleted \(deleted) verified source photo(s) from \(pending.sourceDisplayName), including source albums that became empty. Photos.app was not opened."
            } catch {
                let state = deletionRequested
                    ? "Deletion may have partly completed; check both libraries before retrying."
                    : "No source deletion was requested."
                self.errorMessage = "Move stopped: \(error.localizedDescription) \(state)"
            }
        }
    }

    func retainRegisteredSource() {
        guard let pending = pendingRegisteredSourceDeletion else { return }
        pendingRegisteredSourceDeletion = nil
        pendingRegisteredDeletionRegistry = nil
        resultMessage = "Copy complete. All \(pending.sources.count) non-system source photo(s) were retained."
    }

    func confirmSystemSourceDeletion() {
        guard !isWorking,
              let pending = pendingSystemSourceDeletion,
              let destination = pendingDeletionDestination,
              let systemBookmark = pendingSystemSourceBookmark else { return }
        let sourceAssets = pendingSystemSourceAssets
        pendingSystemSourceDeletion = nil
        pendingDeletionDestination = nil
        pendingSystemSourceAssets = []
        pendingSystemSourceBookmark = nil
        beginOperation(clearResult: false)
        statusMessage = "Rechecking the destination before deleting System Library sources…"
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.finishOperation()
                self.libraryContentDidChange.send(.system)
            }
            let sourceIDs = pending.sources.map(\.assetIdentifier)
            var deletionRequested = false
            do {
                guard Set(sourceIDs).count == sourceIDs.count else {
                    throw PhotoTransferError.duplicateSystemSources
                }
                guard let writeBookmark = destination.descriptor.writeBookmarkData,
                      !Self.needsTransferAuthorization(destination.descriptor) else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "The destination library's transfer access is unavailable."
                    )
                }
                let destinationProvider = RegisteredPhotoLibraryProvider(
                    bookmarkData: writeBookmark, permitsWrites: true
                )
                let catalog = try await destinationProvider.catalog()
                for source in pending.sources {
                    try Task.checkCancellation()
                    guard let uuid = PhotosAssetIdentity.uuid(for: source.destinationItemIdentifier),
                          let item = catalog.items.first(where: { $0.id == uuid }),
                          let observedDate = item.captureDate,
                          abs(observedDate.timeIntervalSince(source.captureDate)) < 1,
                          source.sourceAlbums.allSatisfy({ album in
                              catalog.albums.contains {
                                  $0.name == album.name
                                      && $0.folderNames == album.folderNames
                                      && $0.mediaItemIDs?.contains(uuid) == true
                              }
                          }) else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "A destination photo, date, or album membership changed for \(source.displayName)."
                        )
                    }
                }
                try Task.checkCancellation()
                let existingSources = try self.systemProvider.existingSystemAssetIdentifiers(sourceIDs)
                guard existingSources.count == Set(sourceIDs).count else {
                    let missing = sourceIDs.first { !existingSources.contains($0) } ?? "unknown"
                    throw PhotoTransferError.systemSourceMissing(missing)
                }
                guard Set(sourceAssets.map(\.id)) == Set(sourceIDs),
                      sourceAssets.count == sourceIDs.count else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "The selected System sources could not be rechecked."
                    )
                }
                let currentSourceMetadata = try await Self.systemTransferMetadataFromCatalog(
                    for: sourceAssets, bookmarkData: systemBookmark
                )
                guard pending.sources.allSatisfy({ source in
                    guard let sourceText = currentSourceMetadata.textByAssetID[source.assetIdentifier],
                          let destinationUUID = PhotosAssetIdentity.uuid(
                            for: source.destinationItemIdentifier
                          ),
                          let destinationText = catalog.textMetadata(for: destinationUUID) else {
                        return false
                    }
                    return Set(currentSourceMetadata.albumsByAssetID[source.assetIdentifier] ?? [])
                        == Set(source.sourceAlbums)
                        && destinationText.matches(sourceText)
                }) else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "A System source album or text field differs from its destination copy."
                    )
                }
                try Task.checkCancellation()
                self.statusMessage = "Identifying System Library source albums…"
                let albumsToDelete = try await Self.resolveSystemAlbumIdentifiers(
                    pending.sources.flatMap(\.sourceAlbums)
                )
                try Task.checkCancellation()
                self.statusMessage = "Deleting \(pending.sources.count) confirmed System Library source(s)…"
                let expectedSourceDates = Dictionary(uniqueKeysWithValues: pending.sources.map {
                    ($0.assetIdentifier, (
                        creationDate: Optional($0.captureDate),
                        modificationDate: $0.sourceModificationDate
                    ))
                })
                deletionRequested = true
                try await self.systemProvider.deleteAssets(
                    identifiers: sourceIDs,
                    expectedDates: expectedSourceDates
                )
                try await self.systemProvider.deleteEmptyUserAlbums(
                    albumsToDelete
                )
                let retained = pending.retainedSourceCount > 0
                    ? " \(pending.retainedSourceCount) other selected source(s) were retained."
                    : ""
                self.resultMessage = "Move complete: deleted \(pending.sources.count) confirmed System Library source(s) after verifying their copies in \(pending.destinationDisplayName).\(retained)"
            } catch {
                if !deletionRequested {
                    self.pendingSystemSourceDeletion = pending
                    self.pendingDeletionDestination = destination
                    self.pendingSystemSourceAssets = sourceAssets
                    self.pendingSystemSourceBookmark = systemBookmark
                }
                let sourceStatus: String
                if let remaining = try? self.systemProvider.existingSystemAssetIdentifiers(sourceIDs) {
                    let presentCount = remaining.count
                    sourceStatus = "\(presentCount) of \(sourceIDs.count) source item(s) are currently present in the System Photo Library; \(sourceIDs.count - presentCount) are absent."
                } else {
                    sourceStatus = "The current source-item count could not be checked."
                }
                let deletionStatus = deletionRequested
                    ? "Source deletion was requested, but its result is not fully confirmed."
                    : "Source deletion was not requested. The destination copies were not changed by this attempt; Delete Source can be retried without copying again while this app remains open."
                self.errorMessage = "Transfer stopped: \(error.localizedDescription) \(deletionStatus) \(sourceStatus) This operation did not delete destination copies. Check both libraries before retrying."
            }
        }
    }

    func retainSystemSource() {
        guard let pending = pendingSystemSourceDeletion else { return }
        pendingSystemSourceDeletion = nil
        pendingDeletionDestination = nil
        pendingSystemSourceAssets = []
        pendingSystemSourceBookmark = nil
        let retainedCount = pending.sources.count + pending.retainedSourceCount
        resultMessage = "Copy complete in \(pending.destinationDisplayName). All \(retainedCount) System Library source(s) were retained."
    }

    func cancel() {
        let wasReadingCatalog = statusMessage?.hasPrefix("Reading ") == true
        operationTask?.cancel()
        if copyTotalCount > 0, isWorking {
            statusMessage = wasReadingCatalog
                ? "Cancelling library lookup…"
                : "Cancelling after the current photo…"
        }
    }

    func clearMessages() {
        resultMessage = nil
        errorMessage = nil
    }

    private func beginOperation(clearResult: Bool = true) {
        isWorking = true
        copyCompletedCount = 0
        copyTotalCount = 0
        skippedSystemSources = []
        copiedWithLimitations = []
        deletionWarnings = []
        statusMessage = "Preparing transfer…"
        errorMessage = nil
        if clearResult { resultMessage = nil }
    }

    nonisolated private static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finishOperation() {
        isWorking = false
        statusMessage = nil
        operationTask = nil
    }

    nonisolated private static func systemAlbumMemberships(
        for assetIdentifiers: [String]
    ) async throws -> [String: [PhotoTransferAlbum]] {
        let work = Task.detached(priority: .userInitiated) {
            try SystemPhotoLibraryProvider.transferAlbums(for: assetIdentifiers)
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let memberships = try await work.value
            try Task.checkCancellation()
            return memberships
        } onCancel: {
            work.cancel()
        }
    }

    nonisolated private static func systemTextMetadata(
        for assetIdentifiers: [String],
        bookmarkData: Data
    ) async throws -> [String: PhotoCatalogTextMetadata] {
        let completion = TransferLookupCompletion<[String: PhotoCatalogTextMetadata]>()
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                guard !assetIdentifiers.isEmpty,
                      Set(assetIdentifiers).count == assetIdentifiers.count else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "The System destination photo IDs are missing or duplicated."
                    )
                }
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard !isStale, url.pathExtension.lowercased() == "photoslibrary",
                      url.startAccessingSecurityScopedResource() else {
                    throw PhotoTransferError.systemLibraryNotRegistered
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let fetched = PHAsset.fetchAssets(
                    withLocalIdentifiers: assetIdentifiers, options: nil
                )
                var assetsByID: [String: PHAsset] = [:]
                fetched.enumerateObjects { asset, _, _ in
                    assetsByID[asset.localIdentifier] = asset
                }
                guard assetsByID.count == assetIdentifiers.count else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "A System destination photo was not found for text verification."
                    )
                }
                var metadataByID: [String: PhotoCatalogTextMetadata] = [:]
                for identifier in assetIdentifiers {
                    try Task.checkCancellation()
                    guard let asset = assetsByID[identifier] else {
                        throw PhotoTransferError.importEvidenceMismatch(
                            "A System destination photo ID changed before text verification."
                        )
                    }
                    metadataByID[identifier] = try DirectLibraryCatalog.readTextMetadata(
                        from: url,
                        assetIdentifier: identifier,
                        expectedDate: asset.creationDate,
                        expectedWidth: asset.pixelWidth,
                        expectedHeight: asset.pixelHeight
                    )
                }
                try Task.checkCancellation()
                completion.finish(.success(metadataByID))
            } catch {
                completion.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let metadata = try await completion.wait()
            try Task.checkCancellation()
            return metadata
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            work.cancel()
        }
    }

    nonisolated private static func systemTransferMetadataFromCatalog(
        for assets: [PhotoAssetSummary],
        bookmarkData: Data
    ) async throws -> DirectLibrarySelectedSystemMetadata {
        let completion = TransferLookupCompletion<DirectLibrarySelectedSystemMetadata>()
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard !isStale, url.pathExtension.lowercased() == "photoslibrary",
                      url.startAccessingSecurityScopedResource() else {
                    throw PhotoTransferError.systemLibraryNotRegistered
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let metadata = try DirectLibraryCatalog.readSelectedTransferMetadata(
                    from: url,
                    matching: assets.map {
                        SystemAlbumAssetIdentity(
                            id: $0.id,
                            creationDate: $0.creationDate,
                            pixelWidth: $0.pixelWidth,
                            pixelHeight: $0.pixelHeight
                        )
                    }
                )
                try Task.checkCancellation()
                completion.finish(.success(metadata))
            } catch {
                completion.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let metadata = try await completion.wait()
            try Task.checkCancellation()
            return metadata
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            work.cancel()
        }
    }

    nonisolated private static func destinationCatalog(
        from descriptor: LibraryDescriptor
    ) async throws -> DirectLibraryCatalog {
        let completion = TransferLookupCompletion<DirectLibraryCatalog>()
        let work = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: descriptor.bookmarkData,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard !isStale,
                      url.pathExtension.lowercased() == "photoslibrary",
                      url.standardizedFileURL == URL(
                        fileURLWithPath: descriptor.metadata.lastKnownPath
                      ).standardizedFileURL,
                      url.startAccessingSecurityScopedResource() else {
                    throw PhotoTransferError.importEvidenceMismatch(
                        "The destination library's registered read access is unavailable."
                    )
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let catalog = try DirectLibraryCatalog.read(from: url)
                try Task.checkCancellation()
                completion.finish(.success(catalog))
            } catch {
                completion.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let catalog = try await completion.wait()
            try Task.checkCancellation()
            return catalog
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            work.cancel()
        }
    }

    nonisolated private static func resolveSystemAlbumIdentifiers(
        _ albums: [PhotoTransferAlbum]
    ) async throws -> [PhotoTransferAlbum] {
        let completion = TransferLookupCompletion<[PhotoTransferAlbum]>()
        let work = Task.detached(priority: .userInitiated) {
            do {
                let resolved = try lookupSystemAlbumIdentifiers(albums)
                try Task.checkCancellation()
                completion.finish(.success(resolved))
            } catch {
                completion.finish(.failure(error))
            }
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let resolved = try await completion.wait()
            try Task.checkCancellation()
            return resolved
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            work.cancel()
        }
    }

    nonisolated private static func lookupSystemAlbumIdentifiers(
        _ albums: [PhotoTransferAlbum]
    ) throws -> [PhotoTransferAlbum] {
        let expected = Set(albums)
        guard !expected.isEmpty else { return [] }
        var expectedByUUID: [String: PhotoTransferAlbum] = [:]
        for album in expected {
            try Task.checkCancellation()
            guard let uuid = UUID(uuidString: album.sourceID)?.uuidString,
                  expectedByUUID.updateValue(album, forKey: uuid) == nil else {
                throw PhotoTransferError.importEvidenceMismatch(
                    "A System source album UUID is missing or ambiguous before deletion."
                )
            }
        }
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil
        )
        var identifiersByUUID: [String: String] = [:]
        for index in 0..<collections.count {
            try Task.checkCancellation()
            let collection = collections.object(at: index)
            guard let firstComponent = collection.localIdentifier.split(separator: "/").first,
                  let uuid = UUID(uuidString: String(firstComponent))?.uuidString,
                  let album = expectedByUUID[uuid] else { continue }
            guard collection.localizedTitle == album.name,
                  identifiersByUUID.updateValue(collection.localIdentifier, forKey: uuid) == nil else {
                throw PhotoTransferError.importEvidenceMismatch(
                    "A System source album name or PhotoKit identifier is ambiguous before deletion."
                )
            }
        }
        guard identifiersByUUID.count == expectedByUUID.count else {
            throw PhotoTransferError.importEvidenceMismatch(
                "A System source album could not be identified before deletion."
            )
        }
        return try expected.map { album in
            guard let uuid = UUID(uuidString: album.sourceID)?.uuidString,
                  let localIdentifier = identifiersByUUID[uuid] else {
                throw PhotoTransferError.importEvidenceMismatch(
                    "A System source album could not be identified before deletion."
                )
            }
            return PhotoTransferAlbum(
                sourceID: localIdentifier,
                name: album.name,
                folderNames: album.folderNames
            )
        }
    }

    nonisolated private static func stagingRoot() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = applicationSupport
            .appendingPathComponent("Photo Libraries", isDirectory: true)
            .appendingPathComponent("Transfer Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated private static func removeStagingDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
