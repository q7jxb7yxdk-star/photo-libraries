import AppKit
import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import ObjectiveC.runtime
import Photos
import UniformTypeIdentifiers

/// Access to the System Photo Library through PhotoKit. Transfer imports use
/// the private title setter when the source has a title.
/// This type deliberately exposes stable value models instead of retaining
/// `PHAsset` or `PHCollection` objects in the UI/catalog layer.
final class SystemPhotoLibraryProvider {
    private let imageManager: PHCachingImageManager
    private let resourceManager: PHAssetResourceManager
    private let resourceExporter: PhotoResourceExporter

    init(
        imageManager: PHCachingImageManager = PHCachingImageManager(),
        resourceManager: PHAssetResourceManager = .default()
    ) {
        self.imageManager = imageManager
        self.resourceManager = resourceManager
        self.resourceExporter = PhotoResourceExporter(resourceManager: resourceManager)
    }

    func authorizationStatus() -> PhotoLibraryAuthorization {
        PhotoLibraryAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoLibraryAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoLibraryAuthorization(status)
    }

    func assetCount() throws -> Int {
        try requireReadAuthorization()
        return PHAsset.fetchAssets(with: nil).count
    }

    func fetchAssets(limit: Int? = nil) throws -> [PhotoAssetSummary] {
        try requireReadAuthorization()
        if let limit, limit <= 0 { return [] }

        let options = PHFetchOptions()
        if let limit {
            options.fetchLimit = limit
        }
        // Keep every library browser consistent: oldest assets appear first
        // and the newest assets remain at the bottom of the grid/list.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(with: options)
        let selfieAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil
        )
        var selfieIDs = Set<String>()
        selfieAlbums.enumerateObjects { album, _, _ in
            PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
                selfieIDs.insert(asset.localIdentifier)
            }
        }
        var assets: [PhotoAssetSummary] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset.pocSummary(isSelfie: selfieIDs.contains(asset.localIdentifier)))
        }
        return assets
    }

    /// Resolves resource filenames away from the main actor. Calling
    /// `PHAssetResource.assetResources(for:)` while enumerating the entire
    /// library on the main queue forces PhotoKit to fault original-metadata
    /// properties one asset at a time and floods the debug log.
    nonisolated static func fetchOriginalFilenames(
        for assetIdentifiers: [String]
    ) throws -> [String: String] {
        guard !assetIdentifiers.isEmpty else { return [:] }
        let authorization = PhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        guard authorization.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(authorization)
        }

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIdentifiers,
            options: nil
        )
        var filenames: [String: String] = [:]
        filenames.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard let filename = PHAssetResource.assetResources(for: asset)
                .first?
                .filename,
                  !filename.isEmpty else {
                return
            }
            filenames[asset.localIdentifier] = filename
        }
        return filenames
    }

    func fetchUserCollectionHierarchy() throws -> [PhotoCollectionNode] {
        try requireReadAuthorization()
        let topLevel = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        return collectionNodes(from: topLevel)
    }

    func fetchAssetIdentifiers(inAlbum albumIdentifier: String) throws -> Set<String> {
        try requireReadAuthorization()
        guard let album = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumIdentifier],
            options: nil
        ).firstObject else {
            return []
        }

        let result = PHAsset.fetchAssets(in: album, options: nil)
        var identifiers = Set<String>()
        identifiers.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            identifiers.insert(asset.localIdentifier)
        }
        return identifiers
    }

    /// Recreate a user album at its exact folder path, then prove that every
    /// newly imported System asset belongs to it. Ambiguous names fail closed.
    func addAssets(_ identifiers: [String], to sourceAlbum: PhotoTransferAlbum) async throws {
        guard !identifiers.isEmpty else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoTransferError.importEvidenceMismatch(
                "Full System Photo Library access is required to restore album memberships."
            )
        }
        guard !sourceAlbum.name.isEmpty,
              sourceAlbum.folderNames.allSatisfy({ !$0.isEmpty }) else {
            throw PhotoTransferError.ambiguousSourceAlbums(sourceAlbum.name)
        }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard assets.count == Set(identifiers).count else {
            throw PhotoTransferError.importEvidenceMismatch("An imported System asset is missing before album assignment.")
        }
        var parent: PHCollectionList?
        for folderName in sourceAlbum.folderNames {
            parent = try await folder(named: folderName, in: parent)
        }
        let album = try await userAlbum(named: sourceAlbum.name, in: parent)
        var requestAvailable = false
        try await PHPhotoLibrary.shared().performChanges {
            if let request = PHAssetCollectionChangeRequest(for: album) {
                requestAvailable = true
                request.addAssets(assets as NSArray)
            }
        }
        let verifiedAlbumIDs = try fetchAssetIdentifiers(inAlbum: album.localIdentifier)
        guard requestAvailable, Set(identifiers).isSubset(of: verifiedAlbumIDs) else {
            throw PhotoTransferError.importEvidenceMismatch("The System album membership could not be verified.")
        }
    }

    private func matchingCollections(
        named name: String, in parent: PHCollectionList?
    ) -> [PHCollection] {
        let result = parent.map { PHCollection.fetchCollections(in: $0, options: nil) }
            ?? PHCollection.fetchTopLevelUserCollections(with: nil)
        var matches: [PHCollection] = []
        result.enumerateObjects { collection, _, _ in
            if collection.localizedTitle == name { matches.append(collection) }
        }
        return matches
    }

    private func folder(named name: String, in parent: PHCollectionList?) async throws -> PHCollectionList {
        let matches = matchingCollections(named: name, in: parent).compactMap { $0 as? PHCollectionList }
        guard matches.count <= 1 else {
            throw PhotoTransferError.importEvidenceMismatch("More than one System folder is named \(name) at the requested path.")
        }
        if let existing = matches.first { return existing }
        var createdID: String?
        try await PHPhotoLibrary.shared().performChanges {
            createdID = PHCollectionListChangeRequest.creationRequestForCollectionList(
                withTitle: name
            ).placeholderForCreatedCollectionList.localIdentifier
        }
        guard let createdID,
              let created = PHCollectionList.fetchCollectionLists(
                withLocalIdentifiers: [createdID], options: nil
              ).firstObject else {
            throw PhotoTransferError.importEvidenceMismatch("The new System folder \(name) was not found.")
        }
        if let parent {
            var requestAvailable = false
            try await PHPhotoLibrary.shared().performChanges {
                if let request = PHCollectionListChangeRequest(for: parent) {
                    requestAvailable = true
                    request.addChildCollections([created] as NSArray)
                }
            }
            guard requestAvailable else {
                throw PhotoTransferError.importEvidenceMismatch("The new System folder could not be added to its parent.")
            }
        }
        guard matchingCollections(named: name, in: parent)
            .contains(where: { $0.localIdentifier == createdID }) else {
            throw PhotoTransferError.importEvidenceMismatch("The new System folder path could not be verified.")
        }
        return created
    }

    private func userAlbum(named name: String, in parent: PHCollectionList?) async throws -> PHAssetCollection {
        let matches = matchingCollections(named: name, in: parent).compactMap {
            collection -> PHAssetCollection? in
            guard let album = collection as? PHAssetCollection,
                  album.assetCollectionType == .album,
                  album.assetCollectionSubtype == .albumRegular else { return nil }
            return album
        }
        guard matches.count <= 1 else {
            throw PhotoTransferError.importEvidenceMismatch("More than one System album is named \(name) at the requested path.")
        }
        if let existing = matches.first { return existing }
        var createdID: String?
        try await PHPhotoLibrary.shared().performChanges {
            createdID = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                withTitle: name
            ).placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let createdID,
              let created = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [createdID], options: nil
              ).firstObject else {
            throw PhotoTransferError.importEvidenceMismatch("The new System album \(name) was not found.")
        }
        if let parent {
            var requestAvailable = false
            try await PHPhotoLibrary.shared().performChanges {
                if let request = PHCollectionListChangeRequest(for: parent) {
                    requestAvailable = true
                    request.addChildCollections([created] as NSArray)
                }
            }
            guard requestAvailable else {
                throw PhotoTransferError.importEvidenceMismatch("The new System album could not be added to its folder.")
            }
        }
        guard matchingCollections(named: name, in: parent)
            .contains(where: { $0.localIdentifier == createdID }) else {
            throw PhotoTransferError.importEvidenceMismatch("The new System album path could not be verified.")
        }
        return created
    }

    /// Find user album memberships for selected assets without scanning every
    /// asset in every album.
    nonisolated static func transferAlbums(
        for assetIdentifiers: [String]
    ) throws -> [String: [PhotoTransferAlbum]] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw PhotoTransferError.sourceAlbumAccessLimited
        }
        let selectedIDs = Set(assetIdentifiers)
        guard !selectedIDs.isEmpty else { return [:] }
        var memberships = Dictionary(uniqueKeysWithValues: selectedIDs.map { ($0, [PhotoTransferAlbum]()) })
        var userAlbumPaths: [String: [PhotoTransferAlbum]] = [:]

        func visit<T: PHCollection>(_ result: PHFetchResult<T>, folders: [String]) throws {
            for index in 0..<result.count {
                try Task.checkCancellation()
                let collection = result.object(at: index)
                if let folder = collection as? PHCollectionList {
                    let children = PHCollection.fetchCollections(in: folder, options: nil)
                    try visit(children, folders: folders + [folder.localizedTitle ?? "Untitled Folder"])
                } else if let album = collection as? PHAssetCollection {
                    userAlbumPaths[album.localIdentifier, default: []].append(
                        PhotoTransferAlbum(
                            sourceID: album.localIdentifier,
                            name: album.localizedTitle ?? "Untitled Album",
                            folderNames: folders
                        )
                    )
                }
            }
        }

        try visit(PHCollectionList.fetchTopLevelUserCollections(with: nil), folders: [])
        let selectedAssets = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(selectedIDs), options: nil
        )
        var foundIDs: Set<String> = []
        for index in 0..<selectedAssets.count {
            try Task.checkCancellation()
            let asset = selectedAssets.object(at: index)
            let assetID = asset.localIdentifier
            guard selectedIDs.contains(assetID), foundIDs.insert(assetID).inserted else { continue }
            let containingAlbums = PHAssetCollection.fetchAssetCollectionsContaining(
                asset, with: .album, options: nil
            )
            for albumIndex in 0..<containingAlbums.count {
                try Task.checkCancellation()
                let albumID = containingAlbums.object(at: albumIndex).localIdentifier
                memberships[assetID, default: []].append(contentsOf: userAlbumPaths[albumID] ?? [])
            }
        }
        guard foundIDs == selectedIDs else {
            throw PhotoTransferError.importEvidenceMismatch(
                "A selected System Library photo is no longer available for album verification."
            )
        }
        return memberships
    }

    @discardableResult
    func requestThumbnail(
        for assetIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill,
        networkAccessAllowed: Bool = true,
        resultHandler: @escaping (NSImage?, [AnyHashable: Any]?) -> Void
    ) throws -> PHImageRequestID {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier) else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = networkAccessAllowed

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options,
            resultHandler: resultHandler
        )
    }

    func cancelThumbnailRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    /// Requests a locally available video item without exporting the asset.
    @discardableResult
    func requestPlayerItem(
        for assetIdentifier: String,
        resultHandler: @escaping (AVPlayerItem?, [AnyHashable: Any]?) -> Void
    ) throws -> PHImageRequestID {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier),
              asset.mediaType == .video else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }
        let options = PHVideoRequestOptions()
        options.deliveryMode = .automatic
        options.isNetworkAccessAllowed = false
        return imageManager.requestPlayerItem(
            forVideo: asset,
            options: options,
            resultHandler: resultHandler
        )
    }

    /// Stages a local video or verified Live Photo motion clip for browser playback.
    /// The caller supplies a private temporary directory and removes it afterward.
    func webPlayableMP4File(
        for assetIdentifier: String,
        live: Bool,
        to destinationURL: URL
    ) async throws -> Bool {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier), !asset.isHidden,
              live
                ? (asset.mediaType == .image && asset.mediaSubtypes.contains(.photoLive))
                : asset.mediaType == .video else { return false }
        let resource = PHAssetResource.assetResources(for: asset).first { resource in
            live
                ? (resource.type == .pairedVideo || resource.type == .fullSizePairedVideo)
                : (resource.type == .video || resource.type == .fullSizeVideo)
        }
        guard let resource else { return false }
        let rawExtension = URL(fileURLWithPath: resource.filename ?? "").pathExtension.lowercased()
        let sourceExtension = ["mov", "mp4", "m4v"].contains(rawExtension) ? rawExtension : "mov"
        let sourceURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("source.\(sourceExtension)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            resourceManager.writeData(for: resource, toFile: sourceURL, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try await VideoPlaybackProxyLoader.createWebMP4(from: sourceURL, to: destinationURL)
        return authorizationStatus().permitsReading
            && fetchAsset(identifier: assetIdentifier).map { current in
                !current.isHidden && (live
                    ? current.mediaType == .image && current.mediaSubtypes.contains(.photoLive)
                    : current.mediaType == .video)
            } == true
    }

    /// Requests a display-only, locally available image for the expanded
    /// viewer. This deliberately uses a separate high-quality PhotoKit path
    /// from scrolling thumbnails and never initiates an iCloud download.
    @discardableResult
    func requestViewerImage(
        for assetIdentifier: String,
        targetSize: CGSize,
        resultHandler: @escaping (NSImage?, [AnyHashable: Any]?) -> Void
    ) throws -> PHImageRequestID {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier) else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false

        return imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options,
            resultHandler: resultHandler
        )
    }

    func cancelViewerImageRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    /// Requests the local Live Photo rendition for display in the viewer.
    /// An iCloud-only motion component is left unavailable rather than downloaded.
    @discardableResult
    func requestLivePhoto(
        for assetIdentifier: String,
        targetSize: CGSize,
        resultHandler: @escaping (PHLivePhoto?, [AnyHashable: Any]?) -> Void
    ) throws -> PHImageRequestID {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier),
              asset.mediaType == .image,
              asset.mediaSubtypes.contains(.photoLive) else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }

        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        return imageManager.requestLivePhoto(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options,
            resultHandler: resultHandler
        )
    }

    func cancelLivePhotoRequest(_ requestID: PHImageRequestID) {
        imageManager.cancelImageRequest(requestID)
    }

    /// Display-only web image. Re-resolve the asset and its current hidden state
    /// for each request; never download an iCloud-only original for a visitor.
    func webPreviewJPEG(for assetIdentifier: String, maximumPixelLength: CGFloat) async throws -> Data? {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier),
              isWebVisibleMedia(asset) else { return nil }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = false
        let target = CGSize(width: maximumPixelLength, height: maximumPixelLength)
        if let data = await requestWebJPEG(for: asset, target: target, options: options) {
            return data
        }

        // Photos can retain a locally displayable image even when the requested
        // high-quality rendition is unavailable without an iCloud download.
        let fallbackOptions = PHImageRequestOptions()
        fallbackOptions.deliveryMode = .fastFormat
        fallbackOptions.resizeMode = .fast
        fallbackOptions.isNetworkAccessAllowed = false
        return await requestWebJPEG(
            for: asset,
            target: target,
            options: fallbackOptions,
            acceptsDegradedImage: true
        )
    }

    private func requestWebJPEG(
        for asset: PHAsset,
        target: CGSize,
        options: PHImageRequestOptions,
        acceptsDegradedImage: Bool = false
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            var didResume = false
            imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, info in
                Task { @MainActor in
                    guard !didResume,
                          acceptsDegradedImage || (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    didResume = true
                    continuation.resume(returning: image.flatMap(Self.webJPEGData))
                }
            }
        }
    }

    private static func webJPEGData(from image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let data = NSBitmapImageRep(cgImage: cgImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            return data
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    func isWebVisibleImage(_ assetIdentifier: String) -> Bool {
        guard authorizationStatus().permitsReading,
              let asset = fetchAsset(identifier: assetIdentifier) else { return false }
        return asset.mediaType == .image && !asset.isHidden
    }

    func isWebVisibleWebMedia(_ assetIdentifier: String) -> Bool {
        guard authorizationStatus().permitsReading,
              let asset = fetchAsset(identifier: assetIdentifier) else { return false }
        return isWebVisibleMedia(asset)
    }

    private func isWebVisibleMedia(_ asset: PHAsset) -> Bool {
        guard !asset.isHidden else { return false }
        return asset.mediaType == .image || asset.mediaType == .video
    }

    func technicalMetadata(
        for assetIdentifier: String,
        networkAccessAllowed: Bool
    ) async throws -> PhotoTechnicalMetadata? {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier) else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }

        if asset.mediaType == .video {
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = networkAccessAllowed
            let videoURL: URL? = await withCheckedContinuation { continuation in
                imageManager.requestAVAsset(forVideo: asset, options: options) { videoAsset, _, _ in
                    continuation.resume(returning: (videoAsset as? AVURLAsset)?.url)
                }
            }
            if let fileURL = videoURL {
                return await PhotoTechnicalMetadataExtractor.videoMetadata(from: fileURL)
            }
            return nil
        }

        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = networkAccessAllowed
        let displayedMetadata: PhotoTechnicalMetadata? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let fileURL = input?.fullSizeImageURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: PhotoTechnicalMetadataExtractor.metadata(from: fileURL)
                )
            }
        }
        guard asset.hasAdjustments,
              let originalPhoto = PHAssetResource.assetResources(for: asset)
                .first(where: { $0.type == .photo }) else {
            return displayedMetadata
        }

        // An edited image may omit camera EXIF fields. Read the original through
        // PhotoKit and use it only to fill fields absent from the displayed image.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(URL(fileURLWithPath: originalPhoto.pocFilename).pathExtension)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let resourceOptions = PHAssetResourceRequestOptions()
        resourceOptions.isNetworkAccessAllowed = networkAccessAllowed
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resourceManager.writeData(
                    for: originalPhoto,
                    toFile: temporaryURL,
                    options: resourceOptions
                ) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        } catch {
            return displayedMetadata
        }
        guard let originalMetadata = PhotoTechnicalMetadataExtractor.metadata(from: temporaryURL) else {
            return displayedMetadata
        }
        return displayedMetadata?.fillingMissingCameraValues(from: originalMetadata)
            ?? originalMetadata
    }

    func resourceInventory(for assetIdentifier: String) throws -> [PhotoAssetResourceRecord] {
        try Self.resourceInventoryOffMain(for: assetIdentifier)
    }

    nonisolated static func resourceInventoryOffMain(
        for assetIdentifier: String
    ) throws -> [PhotoAssetResourceRecord] {
        let authorization = PhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        guard authorization.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(authorization)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        ).firstObject else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }

        return PHAssetResource.assetResources(for: asset).enumerated().map { index, resource in
            PhotoAssetResourceRecord(
                id: "\(assetIdentifier)#\(index)",
                index: index,
                type: resource.type.pocName,
                originalFilename: resource.pocFilename,
                uniformTypeIdentifier: resource.uniformTypeIdentifier
            )
        }
    }

    nonisolated static func hasAdjustmentsOffMain(for assetIdentifier: String) throws -> Bool {
        let authorization = PhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        guard authorization.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(authorization)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        ).firstObject else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }
        return asset.hasAdjustments
    }

    nonisolated static func transferLocationOffMain(
        for assetIdentifier: String
    ) throws -> PhotoTransferLocation? {
        let authorization = PhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        guard authorization.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(authorization)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }
        guard let location = asset.location else { return nil }
        return PhotoTransferLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil
        )
    }

    /// Read capture EXIF from the original PhotoKit resource, which is often
    /// absent from the rendered appearance of an edited asset.
    nonisolated static func originalEXIFPropertyListOffMain(
        for assetIdentifier: String,
        networkAccessAllowed: Bool
    ) async throws -> Data? {
        let authorization = PhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        guard authorization.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(authorization)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier], options: nil
        ).firstObject else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }
        guard let original = PHAssetResource.assetResources(for: asset)
            .first(where: { $0.type == .photo }) else {
            return nil
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-exif-\(UUID().uuidString)")
            .appendingPathExtension(URL(fileURLWithPath: original.pocFilename).pathExtension)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = networkAccessAllowed
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: original, toFile: fileURL, options: options
            ) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] else {
            return nil
        }
        return try PropertyListSerialization.data(
            fromPropertyList: exif, format: .binary, options: 0
        )
    }

    /// Stage the image Photos currently displays. This flattens edits into one
    /// importable image and deliberately does not copy the adjustment recipe.
    nonisolated static func exportCurrentAppearanceOffMain(
        for assetIdentifier: String,
        displayFilename: String,
        to stagingRoot: URL,
        networkAccessAllowed: Bool
    ) throws -> URL {
        let authorization = PhotoLibraryAuthorization(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
        guard authorization.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(authorization)
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetIdentifier],
            options: nil
        ).firstObject else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }
        guard asset.hasAdjustments else {
            throw SystemPhotoLibraryError.currentAppearanceUnavailable(displayFilename, nil)
        }

        let options = PHImageRequestOptions()
        options.version = .current
        options.isSynchronous = true
        options.isNetworkAccessAllowed = networkAccessAllowed
        options.deliveryMode = .highQualityFormat
        var imageData: Data?
        var imageUTI: String?
        var imageError: Error?
        PHImageManager.default().requestImageDataAndOrientation(
            for: asset,
            options: options
        ) { data, uti, _, info in
            imageData = data
            imageUTI = uti
            imageError = info?[PHImageErrorKey] as? Error
        }
        guard let imageData, !imageData.isEmpty,
              let imageUTI,
              let imageType = UTType(imageUTI),
              imageType.conforms(to: .image),
              let preferredExtension = imageType.preferredFilenameExtension else {
            throw SystemPhotoLibraryError.currentAppearanceUnavailable(
                displayFilename,
                imageError
            )
        }

        let jobDirectory = stagingRoot.appendingPathComponent(
            "current-appearance-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: jobDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw SystemPhotoLibraryError.cannotCreateStagingDirectory(jobDirectory, error)
        }
        let stem = URL(fileURLWithPath: displayFilename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let originalExtension = URL(fileURLWithPath: displayFilename).pathExtension
        let fileExtension = UTType(filenameExtension: originalExtension) == imageType
            ? originalExtension : preferredExtension
        let filename = "\(stem.isEmpty ? "Photo" : stem).\(fileExtension)"
        let fileURL = jobDirectory.appendingPathComponent(filename)
        do {
            try imageData.write(to: fileURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: jobDirectory)
            throw SystemPhotoLibraryError.resourceWriteFailed(fileURL, error)
        }
        return fileURL
    }

    /// Exports every PhotoKit resource into a new job directory beneath an
    /// app-owned staging root. Cancellation is cooperative via `Task.cancel()`.
    func exportResources(
        for assetIdentifier: String,
        to stagingRoot: URL,
        networkAccessAllowed: Bool = true,
        selectedResourceIndices: Set<Int>? = nil,
        progress: @escaping (PhotoResourceExportProgress) -> Void = { _ in }
    ) async throws -> PhotoResourceExportManifest {
        try requireReadAuthorization()
        guard let asset = fetchAsset(identifier: assetIdentifier) else {
            throw SystemPhotoLibraryError.assetNotFound(assetIdentifier)
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else {
            throw SystemPhotoLibraryError.noResources(assetIdentifier)
        }

        return try await resourceExporter.export(
            resources: resources,
            assetIdentifier: assetIdentifier,
            stagingRoot: stagingRoot,
            networkAccessAllowed: networkAccessAllowed,
            selectedResourceIndices: selectedResourceIndices,
            progress: progress
        )
    }

    func transferFidelity(
        for asset: PhotoAssetSummary,
        resources: [PhotoAssetResourceRecord]
    ) -> PhotoAssetTransferFidelity {
        var reasons: [String] = []
        if asset.representsBurst {
            reasons.append("Burst grouping cannot be recreated with the public import APIs.")
        }
        if resources.count != 1 {
            reasons.append("This asset has \(resources.count) resources, so its compound structure cannot be verified after import.")
        }
        let types = Set(resources.map(\.type))
        if types.contains("pairedVideo") || types.contains("fullSizePairedVideo") {
            reasons.append("Live Photo pairing may not be preserved.")
        }
        if types.contains("alternatePhoto") {
            reasons.append("RAW+JPEG pairing may not be preserved.")
        }
        if types.contains("adjustmentData")
            || types.contains("adjustmentBasePhoto")
            || types.contains("adjustmentBaseVideo")
            || types.contains("adjustmentBasePairedVideo") {
            reasons.append("The non-destructive edit history cannot be recreated.")
        }
        if let onlyType = resources.first?.type,
           resources.count == 1,
           onlyType != "photo",
           onlyType != "video" {
            reasons.append("The resource role \(onlyType) is not an ordinary photo or video original.")
        }

        if reasons.isEmpty, resources.count == 1 {
            return .ordinarySingleResource
        }
        if reasons.isEmpty {
            reasons.append("The source asset structure cannot be proven equivalent after import.")
        }
        return .safeCopyOnly(reasons: reasons)
    }

    /// Creates one PhotoKit asset per staged image or movie. This intentionally
    /// avoids guessing Live Photo, RAW-pair, burst, or adjustment relationships
    /// when the non-system Photos scripting API did not provide resource roles.
    func importFilesAsIndependentAssets(
        _ fileURLs: [URL],
        creationDate: Date?,
        location: PhotoTransferLocation?,
        isFavorite: Bool,
        textMetadata: PhotoCatalogTextMetadata
    ) async throws -> PhotoKitImportResult {
        try requireReadAuthorization()
        guard !fileURLs.isEmpty else { throw SystemPhotoLibraryError.noImportableFiles }

        let classified = try fileURLs.compactMap { fileURL -> (URL, PHAssetResourceType)? in
            let contentType = try fileURL.resourceValues(forKeys: [.contentTypeKey]).contentType
                ?? UTType(filenameExtension: fileURL.pathExtension)
            if contentType?.conforms(to: .image) == true {
                return (fileURL, .photo)
            }
            if contentType?.conforms(to: .movie) == true {
                return (fileURL, .video)
            }
            return nil
        }
        guard !classified.isEmpty else { throw SystemPhotoLibraryError.noImportableFiles }
        let titleSelector = NSSelectorFromString("setTitle:")
        guard textMetadata.title.isEmpty
            || class_getInstanceMethod(PHAssetCreationRequest.self, titleSelector) != nil else {
            throw PhotoTransferError.importEvidenceMismatch(
                "This macOS PhotoKit version cannot set the System photo title. No import was started."
            )
        }

        var createdIdentifiers: [String] = []
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for (fileURL, resourceType) in classified {
                    let request = PHAssetCreationRequest.forAsset()
                    request.creationDate = creationDate
                    request.location = location.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
                    request.isFavorite = isFavorite
                    if !textMetadata.title.isEmpty {
                        _ = request.perform(titleSelector, with: textMetadata.title as NSString)
                    }
                    request.caption = textMetadata.caption
                    for keyword in Set(textMetadata.keywords).sorted() {
                        request.addKeyword(keyword)
                    }
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = fileURL.lastPathComponent
                    request.addResource(with: resourceType, fileURL: fileURL, options: options)
                    if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                        createdIdentifiers.append(identifier)
                    }
                }
            }
        } catch {
            throw SystemPhotoLibraryError.importFailed(error)
        }

        let verifiedIdentifiers = Self.existingAssetIdentifiers(createdIdentifiers)
        let result = PhotoKitImportResult(
            requestedFiles: fileURLs,
            createdAssetIdentifiers: createdIdentifiers,
            verifiedAssetIdentifiers: verifiedIdentifiers
        )
        guard result.isVerifiedCreation,
              result.createdAssetIdentifiers.count == classified.count else {
            throw SystemPhotoLibraryError.importVerificationFailed
        }
        return result
    }

    /// Imports the two original resources as one Live Photo asset.
    func importLivePhotoPair(
        imageURL: URL,
        pairedVideoURL: URL,
        creationDate: Date?,
        location: PhotoTransferLocation?,
        isFavorite: Bool,
        textMetadata: PhotoCatalogTextMetadata
    ) async throws -> PhotoKitImportResult {
        try requireReadAuthorization()
        let titleSelector = NSSelectorFromString("setTitle:")
        guard textMetadata.title.isEmpty
            || class_getInstanceMethod(PHAssetCreationRequest.self, titleSelector) != nil else {
            throw PhotoTransferError.importEvidenceMismatch(
                "This macOS PhotoKit version cannot set the System photo title. No import was started."
            )
        }
        var createdIdentifiers: [String] = []
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = creationDate
                request.location = location.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
                request.isFavorite = isFavorite
                if !textMetadata.title.isEmpty {
                    _ = request.perform(titleSelector, with: textMetadata.title as NSString)
                }
                request.caption = textMetadata.caption
                for keyword in Set(textMetadata.keywords).sorted() {
                    request.addKeyword(keyword)
                }

                let imageOptions = PHAssetResourceCreationOptions()
                imageOptions.originalFilename = imageURL.lastPathComponent
                request.addResource(with: .photo, fileURL: imageURL, options: imageOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.originalFilename = pairedVideoURL.lastPathComponent
                request.addResource(with: .pairedVideo, fileURL: pairedVideoURL, options: videoOptions)

                if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                    createdIdentifiers.append(identifier)
                }
            }
        } catch {
            throw SystemPhotoLibraryError.importFailed(error)
        }

        guard createdIdentifiers.count == 1,
              let identifier = createdIdentifiers.first else {
            throw SystemPhotoLibraryError.livePhotoPairNotVerified
        }
        // The asset and its resource roles may become visible after the change completes.
        var verified = false
        for attempt in 0..<10 {
            try Task.checkCancellation()
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
            if fetched.count == 1, let asset = fetched.firstObject,
               asset.mediaType == .image,
               asset.mediaSubtypes.contains(.photoLive) {
                let resourceTypes = Set(PHAssetResource.assetResources(for: asset).map(\.type))
                if resourceTypes.contains(.photo), resourceTypes.contains(.pairedVideo) {
                    verified = true
                    break
                }
            }
            if attempt < 9 {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard verified else {
            throw SystemPhotoLibraryError.livePhotoPairNotVerified
        }
        return PhotoKitImportResult(
            requestedFiles: [imageURL, pairedVideoURL],
            createdAssetIdentifiers: createdIdentifiers,
            verifiedAssetIdentifiers: [identifier]
        )
    }

    func deleteAsset(identifier: String) async throws {
        try await deleteAssets(identifiers: [identifier])
    }

    func deleteAssets(
        identifiers: [String],
        expectedDates: [String: (creationDate: Date?, modificationDate: Date?)] = [:]
    ) async throws {
        try requireReadAuthorization()
        guard !identifiers.isEmpty else { return }
        let uniqueIdentifiers = Array(Set(identifiers))
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIdentifiers, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard assets.count == uniqueIdentifiers.count else {
            let found = Set(assets.map(\.localIdentifier))
            let missing = uniqueIdentifiers.first { !found.contains($0) } ?? "unknown"
            throw SystemPhotoLibraryError.assetNotFound(missing)
        }
        for asset in assets {
            if let expected = expectedDates[asset.localIdentifier],
               asset.creationDate != expected.creationDate
                || asset.modificationDate != expected.modificationDate {
                throw SystemPhotoLibraryError.sourceChangedSinceSelection(asset.localIdentifier)
            }
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            throw SystemPhotoLibraryError.deletionFailed(error)
        }
        let remaining = PHAsset.fetchAssets(withLocalIdentifiers: uniqueIdentifiers, options: nil)
        if let identifier = remaining.firstObject?.localIdentifier {
            throw SystemPhotoLibraryError.deletionVerificationFailed(identifier)
        }
    }

    func existingSystemAssetIdentifiers(_ identifiers: [String]) throws -> Set<String> {
        try requireReadAuthorization()
        guard !identifiers.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var existing = Set<String>()
        assets.enumerateObjects { asset, _, _ in
            existing.insert(asset.localIdentifier)
        }
        return existing
    }

    /// Only removes albums that became empty after verified source deletion.
    /// Nonempty albums and their parent folders remain untouched.
    func deleteEmptyUserAlbums(_ sourceAlbums: [PhotoTransferAlbum]) async throws {
        try requireReadAuthorization()
        for album in Set(sourceAlbums) {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [album.sourceID], options: nil
            ).firstObject,
                  collection.assetCollectionType == .album,
                  collection.assetCollectionSubtype == .albumRegular,
                  PHAsset.fetchAssets(in: collection, options: nil).count == 0 else { continue }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest.deleteAssetCollections([collection] as NSArray)
            }
            guard PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [album.sourceID], options: nil
            ).count == 0 else {
                throw PhotoTransferError.importEvidenceMismatch(
                    "The empty System source album could not be verified as deleted."
                )
            }
        }
    }

    func verifyTransferProperties(
        for identifiers: [String],
        creationDate: Date,
        location: PhotoTransferLocation?,
        isFavorite: Bool
    ) throws {
        try requireReadAuthorization()
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count == identifiers.count else {
            throw SystemPhotoLibraryError.importVerificationFailed
        }
        var matches = true
        assets.enumerateObjects { asset, _, _ in
            let dateMatches = asset.creationDate.map { abs($0.timeIntervalSince(creationDate)) < 1 } == true
            let observedLocation = asset.location.map {
                PhotoTransferLocation(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude,
                    altitude: nil
                )
            }
            let locationMatches = location.map { observedLocation?.matches($0) == true }
                ?? (observedLocation == nil)
            if !dateMatches || !locationMatches || asset.isFavorite != isFavorite {
                matches = false
            }
        }
        guard matches else { throw SystemPhotoLibraryError.importVerificationFailed }
    }

    nonisolated private static func existingAssetIdentifiers(_ identifiers: [String]) -> [String] {
        guard !identifiers.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var existing: [String] = []
        existing.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            existing.append(asset.localIdentifier)
        }
        return existing
    }

    private func requireReadAuthorization() throws {
        let status = authorizationStatus()
        guard status.permitsReading else {
            throw SystemPhotoLibraryError.accessNotAuthorized(status)
        }
    }

    private func fetchAsset(identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private func collectionNodes<T: PHCollection>(
        from result: PHFetchResult<T>
    ) -> [PhotoCollectionNode] {
        var nodes: [PhotoCollectionNode] = []
        result.enumerateObjects { [weak self] collection, _, _ in
            guard let self, let node = self.collectionNode(from: collection) else { return }
            nodes.append(node)
        }
        return nodes
    }

    private func collectionNode(from collection: PHCollection) -> PhotoCollectionNode? {
        if let folder = collection as? PHCollectionList {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            return PhotoCollectionNode(
                id: folder.localIdentifier,
                title: folder.localizedTitle ?? "Untitled Folder",
                kind: .folder,
                assetCount: nil,
                children: collectionNodes(from: children)
            )
        }

        if let album = collection as? PHAssetCollection {
            return PhotoCollectionNode(
                id: album.localIdentifier,
                title: album.localizedTitle ?? "Untitled Album",
                kind: .album,
                assetCount: PHAsset.fetchAssets(in: album, options: nil).count,
                children: []
            )
        }

        return nil
    }
}
