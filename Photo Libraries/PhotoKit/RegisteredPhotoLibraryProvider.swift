import AppKit
import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import ObjectiveC.runtime
import Photos
import SQLite3
import UniformTypeIdentifiers

/// Used only in the child process. Enabling multi-library mode in the app
/// process would invalidate its public System-library PhotoKit calls.
#if DIRECT_LIBRARY_HELPER
@MainActor
final class PrivateRegisteredPhotoLibrary {
    private typealias Initialize = @convention(c) (
        UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer, Int
    ) -> UnsafeMutableRawPointer?

    let url: URL
    private let library: PHPhotoLibrary
    private let permitsWrites: Bool
    private let imageManager: PHImageManager
    private let assets = NSCache<NSString, PHAsset>()

    init(bookmarkData: Data, permitsWrites: Bool = false) throws {
        assets.countLimit = 1_000
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        // The implicit bookmark starts the helper's access during resolution.
        guard !stale, resolved.pathExtension.lowercased() == "photoslibrary" else {
            resolved.stopAccessingSecurityScopedResource()
            throw DirectLibraryError.accessDenied
        }
        do {
            let cls: AnyClass = PHPhotoLibrary.self
            let enable = NSSelectorFromString("enableMultiLibraryMode")
            let selector = NSSelectorFromString("initWithPhotoLibraryURL:type:")
            guard class_getClassMethod(cls, enable) != nil,
                  let method = class_getInstanceMethod(cls, selector),
                  let allocated = class_createInstance(cls, 0) as? PHPhotoLibrary else {
                throw DirectLibraryError.unsupportedPhotoKit
            }
            _ = PHPhotoLibrary.perform(enable)
            let object = Unmanaged.passUnretained(allocated).toOpaque()
            let nsURL = resolved as NSURL
            let address = Unmanaged.passUnretained(nsURL).toOpaque()
            let call = unsafeBitCast(method_getImplementation(method), to: Initialize.self)
            guard call(object, selector, address, 0) == object else {
                throw DirectLibraryError.unsupportedPhotoKit
            }
            url = resolved
            library = allocated
            self.permitsWrites = permitsWrites
            imageManager = PHImageManager()
        } catch {
            resolved.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    deinit { url.stopAccessingSecurityScopedResource() }

    func catalog() throws -> DirectLibraryCatalog {
        try DirectLibraryCatalog.read(from: url)
    }

    func isLivePhoto(_ id: String) -> Bool {
        asset(for: id)?.mediaSubtypes.contains(.photoLive) == true
    }

    func imageData(for id: String, size: CGSize) -> Data? {
        guard let asset = asset(for: id) else { return nil }
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        var output: NSImage?
        imageManager.requestImage(
            for: asset, targetSize: size, contentMode: .aspectFit,
            options: options
        ) { image, _ in
            output = image
        }
        guard let tiff = output?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    }

    func videoURL(for id: String, live: Bool) async throws -> URL? {
        guard let asset = asset(for: id) else {
            throw DirectLibraryError.media("PhotoKit could not resolve this asset in the selected library.")
        }
        guard live ? asset.mediaSubtypes.contains(.photoLive) : asset.mediaType == .video else {
            throw DirectLibraryError.media("PhotoKit did not identify this asset as a \(live ? "Live Photo" : "video").")
        }
        let resource = PHAssetResource.assetResources(for: asset).first {
            live
                ? ($0.type == .pairedVideo || $0.type == .fullSizePairedVideo)
                : ($0.type == .video || $0.type == .fullSizeVideo)
        }
        guard let resource else {
            throw DirectLibraryError.media("PhotoKit found no \(live ? "paired video" : "video") resource for this asset.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PhotoLibrariesWorkerMedia", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: resource.filename ?? "").pathExtension
        let target = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(
                    for: resource, toFile: target, options: options
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target
    }

    /// Export only resource layouts that can be recreated without guessing
    /// adjustment, RAW, burst, or other relationships. The selected library
    /// remains read-only and Photos.app does not need to open it.
    func exportOriginalResources(for id: String, to stagingDirectory: URL) async throws -> DirectLibraryExport {
        guard let requestedUUID = UUID(uuidString: id)?.uuidString,
              let asset = asset(for: requestedUUID),
              let assetUUID = asset.localIdentifier.split(separator: "/").first
                .flatMap({ UUID(uuidString: String($0))?.uuidString }),
              assetUUID == requestedUUID else {
            throw DirectLibraryError.media("The selected source photo could not be verified in this library.")
        }
        let destination = stagingDirectory.standardizedFileURL
        guard !destination.pathComponents.starts(with: url.standardizedFileURL.pathComponents) else {
            throw DirectLibraryError.media("Original resources cannot be staged inside a Photos library package.")
        }
        return try await exportOutsideLibrary(asset, id: requestedUUID, to: destination)
    }

    private func exportOutsideLibrary(
        _ asset: PHAsset, id: String, to destination: URL
    ) async throws -> DirectLibraryExport {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw DirectLibraryError.media("The app-owned staging directory is unavailable.")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        let validLayout = (resources.count == 1
            && (resources[0].type == .photo || resources[0].type == .video)
            && !isLivePhoto)
            || (resources.count == 2 && isLivePhoto
                && resources.filter({ $0.type == .photo }).count == 1
                && resources.filter({ $0.type == .pairedVideo }).count == 1)
        guard validLayout else {
            throw DirectLibraryError.media(
                "This photo has edited, RAW, burst, or other resource relationships that cannot yet be copied safely without Photos. The source was retained."
            )
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        var paths: [String] = []
        var usedNames = Set<String>()
        do {
            for resource in resources {
                try Task.checkCancellation()
                let filename = resource.filename ?? ""
                guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
                      !URL(fileURLWithPath: filename).pathExtension.isEmpty,
                      usedNames.insert(filename.lowercased()).inserted else {
                    throw DirectLibraryError.media("The original resource filenames are missing or ambiguous.")
                }
                let output = destination.appendingPathComponent(filename)
                paths.append(output.path)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(
                        for: resource, toFile: output, options: options
                    ) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                let values = try output.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw DirectLibraryError.media("A staged original resource is empty.")
                }
            }
            let coordinate = asset.location?.coordinate
            return DirectLibraryExport(
                sourceID: id, resourcePaths: paths, isLivePhoto: isLivePhoto,
                captureDate: asset.creationDate, isFavorite: asset.isFavorite,
                latitude: coordinate?.latitude, longitude: coordinate?.longitude
            )
        } catch {
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
            throw error
        }
    }

    private func asset(for id: String) -> PHAsset? {
        if let found = assets.object(forKey: id as NSString) { return found }
        let selector = NSSelectorFromString("fetchPHObjectsForUUIDs:entityName:")
        guard library.responds(to: selector),
              let returned = library.perform(
                selector, with: [id] as NSArray, with: "Asset" as NSString
              )?.takeUnretainedValue() else { return nil }
        let found: PHAsset?
        if let array = returned as? NSArray {
            found = array.firstObject as? PHAsset
        } else if let fetch = returned as? PHFetchResult<PHAsset> {
            found = fetch.firstObject
        } else {
            found = nil
        }
        if let found { assets.setObject(found, forKey: id as NSString) }
        return found
    }

    private func photoObject<T: PHObject>(uuid: String, entity: String) -> T? {
        let selector = NSSelectorFromString("fetchPHObjectsForUUIDs:entityName:")
        guard library.responds(to: selector),
              let returned = library.perform(
                selector, with: [uuid] as NSArray, with: entity as NSString
              )?.takeUnretainedValue() else { return nil }
        if let array = returned as? NSArray { return array.firstObject as? T }
        return (returned as? PHFetchResult<T>)?.firstObject
    }

    func importAsset(_ details: DirectLibraryImportRequest) async throws -> String {
        guard permitsWrites else { throw DirectLibraryError.accessDenied }
        let paths = details.resourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        guard (paths.count == 1 && !details.isLivePhoto)
                || (paths.count == 2 && details.isLivePhoto),
              paths.allSatisfy({ !$0.pathComponents.starts(with: url.standardizedFileURL.pathComponents)
                    && FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw DirectLibraryError.media("Staged resources are missing or inside a Photos library.")
        }
        let classified = paths.map { (url: $0, type: UTType(filenameExtension: $0.pathExtension)) }
        let resources: [(URL, PHAssetResourceType)]
        if details.isLivePhoto {
            let images = classified.filter { $0.type?.conforms(to: .image) == true }
            let movies = classified.filter { $0.type?.conforms(to: .movie) == true }
            guard images.count == 1, movies.count == 1 else {
                throw DirectLibraryError.media("The Live Photo resources are ambiguous.")
            }
            resources = [(images[0].url, .photo), (movies[0].url, .pairedVideo)]
        } else if classified[0].type?.conforms(to: .image) == true {
            resources = [(paths[0], .photo)]
        } else if classified[0].type?.conforms(to: .movie) == true {
            resources = [(paths[0], .video)]
        } else {
            throw DirectLibraryError.media("The staged file is not an image or movie.")
        }
        for (file, role) in resources where role == .photo {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  CGImageSourceGetCount(source) > 0,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else {
                throw DirectLibraryError.media(
                    "Staged image preflight failed before destination import: \(file.lastPathComponent) could not be decoded by Image I/O."
                )
            }
        }
        let titleSelector = NSSelectorFromString("setTitle:")
        guard class_getInstanceMethod(PHAssetCreationRequest.self, titleSelector) != nil else {
            throw DirectLibraryError.media(
                "This macOS PhotoKit version cannot set a destination photo title. No import was started."
            )
        }
        var createdID: String?
        do {
            try await library.performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = details.captureDate
                request.isFavorite = details.isFavorite
                request.location = details.location.map {
                    CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                }
                _ = request.perform(titleSelector, with: details.textMetadata.title as NSString)
                request.caption = details.textMetadata.caption
                for keyword in Set(details.textMetadata.keywords).sorted() {
                    request.addKeyword(keyword)
                }
                for (file, role) in resources {
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.lastPathComponent
                    request.addResource(with: role, fileURL: file, options: options)
                }
                createdID = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            let nsError = error as NSError
            throw DirectLibraryError.media(
                "Destination PhotoKit asset creation failed [\(nsError.domain) code \(nsError.code)]: \(error.localizedDescription)"
            )
        }
        guard let createdID,
              let uuid = createdID.split(separator: "/").first.map(String.init),
              let created = asset(for: uuid),
              created.localIdentifier == createdID,
              created.creationDate.map({ abs($0.timeIntervalSince(details.captureDate)) < 1 }) == true,
              created.isFavorite == details.isFavorite,
              created.mediaSubtypes.contains(.photoLive) == details.isLivePhoto else {
            throw DirectLibraryError.media("Destination asset verification failed: the photo or its properties could not be verified.")
        }
        if let location = details.location {
            guard let coordinate = created.location?.coordinate,
                  abs(coordinate.latitude - location.latitude) < 0.00001,
                  abs(coordinate.longitude - location.longitude) < 0.00001 else {
                throw DirectLibraryError.media("Destination GPS verification failed: the coordinates could not be verified.")
            }
        }
        for album in details.albums {
            do {
                try await addAsset(created, to: album)
            } catch {
                throw DirectLibraryError.media(
                    "Destination album assignment failed for \(album.name): \(error.localizedDescription)"
                )
            }
        }
        return createdID
    }

    private func addAsset(_ asset: PHAsset, to sourceAlbum: PhotoTransferAlbum) async throws {
        guard !sourceAlbum.name.isEmpty,
              sourceAlbum.folderNames.allSatisfy({ !$0.isEmpty }) else {
            throw DirectLibraryError.media("The source album path is invalid.")
        }
        let path = sourceAlbum.folderNames + [sourceAlbum.name]
        let existing = try catalog().albums.filter { album in
            album.folderNames.map { $0 + [album.name] } == path
        }
        guard existing.count <= 1 else {
            throw DirectLibraryError.media("The destination has ambiguous album paths.")
        }
        let albumID: String
        if let match = existing.first {
            albumID = match.id
        } else {
            let parent = try await ensureFolderPath(sourceAlbum.folderNames)
            var createdID: String?
            try await library.performChanges {
                let request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: sourceAlbum.name)
                createdID = request.placeholderForCreatedAssetCollection.localIdentifier
            }
            guard let createdID, let created = photoObject(
                uuid: String(createdID.split(separator: "/")[0]), entity: "Album"
            ) as PHAssetCollection? else {
                throw DirectLibraryError.media("The destination album was not created.")
            }
            if let parent {
                try await library.performChanges {
                    PHCollectionListChangeRequest(for: parent)?
                        .addChildCollections([created] as NSArray)
                }
            }
            albumID = createdID
        }
        guard let album = photoObject(
            uuid: String(albumID.split(separator: "/")[0]), entity: "Album"
        ) as PHAssetCollection? else {
            throw DirectLibraryError.media("The destination album is unavailable.")
        }
        try await library.performChanges {
            PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
        }
        let verified = try catalog().albums.filter {
            $0.id == String(albumID.split(separator: "/")[0])
                && $0.folderNames == sourceAlbum.folderNames
                && $0.name == sourceAlbum.name
                && $0.mediaItemIDs?.contains(String(asset.localIdentifier.split(separator: "/")[0])) == true
        }
        guard verified.count == 1 else {
            throw DirectLibraryError.media("The destination album membership could not be verified.")
        }
    }

    private func ensureFolderPath(_ names: [String]) async throws -> PHCollectionList? {
        var parent: PHCollectionList?
        var path: [String] = []
        for name in names {
            path.append(name)
            let matches = try catalog().folders.filter { $0.path == path }
            guard matches.count <= 1 else {
                throw DirectLibraryError.media("The destination folder path is ambiguous.")
            }
            if let existing = matches.first {
                guard let folder: PHCollectionList = photoObject(uuid: existing.id, entity: "Folder") else {
                    throw DirectLibraryError.media("The destination folder could not be resolved.")
                }
                parent = folder
                continue
            }
            var createdID: String?
            try await library.performChanges {
                let request = PHCollectionListChangeRequest.creationRequestForCollectionList(withTitle: name)
                createdID = request.placeholderForCreatedCollectionList.localIdentifier
            }
            guard let createdID,
                  let folder: PHCollectionList = photoObject(
                    uuid: String(createdID.split(separator: "/")[0]), entity: "Folder"
                  ) else {
                throw DirectLibraryError.media("The destination folder was not created.")
            }
            if let parent {
                try await library.performChanges {
                    PHCollectionListChangeRequest(for: parent)?
                        .addChildCollections([folder] as NSArray)
                }
            }
            guard try catalog().folders.contains(where: { $0.path == path && $0.id == String(createdID.split(separator: "/")[0]) }) else {
                throw DirectLibraryError.media("The destination folder path could not be verified.")
            }
            parent = folder
        }
        return parent
    }

    func deleteAssets(_ details: DirectLibraryDeletionRequest) async throws -> Int {
        guard permitsWrites,
              !details.sourceUUIDs.isEmpty,
              Set(details.sourceUUIDs).count == details.sourceUUIDs.count else {
            throw DirectLibraryError.accessDenied
        }
        let before = try catalog()
        let sourceIDs = Set(details.sourceUUIDs)
        guard sourceIDs.isSubset(of: Set(before.items.map(\.id))) else {
            throw DirectLibraryError.media("A source photo is no longer present; deletion stopped.")
        }
        let sourceAssets = try details.sourceUUIDs.map { id -> PHAsset in
            guard let asset = asset(for: id),
                  asset.localIdentifier.hasPrefix(id + "/") else {
                throw DirectLibraryError.media("The source photo identity changed; deletion stopped.")
            }
            return asset
        }
        try await library.performChanges {
            PHAssetChangeRequest.deleteAssets(sourceAssets as NSArray)
        }
        assets.removeAllObjects()
        let after = try catalog()
        guard sourceIDs.isDisjoint(with: Set(after.items.map(\.id))) else {
            throw DirectLibraryError.media("The source deletion could not be verified.")
        }
        for album in Set(details.albums) {
            guard let current = after.albums.first(where: { $0.id == album.sourceID }),
                  current.mediaItemIDs?.isEmpty == true else { continue }
            guard let source: PHAssetCollection = photoObject(uuid: album.sourceID, entity: "Album") else {
                continue
            }
            try await library.performChanges {
                PHAssetCollectionChangeRequest.deleteAssetCollections([source] as NSArray)
            }
            guard try !catalog().albums.contains(where: { $0.id == album.sourceID }) else {
                throw DirectLibraryError.media("An empty source album could not be verified as deleted.")
            }
        }
        return sourceIDs.count
    }
}
#endif

enum DirectLibraryError: LocalizedError {
    case accessDenied
    case unsupportedPhotoKit
    case database(String)
    case media(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied: "The selected Photos library needs access again."
        case .unsupportedPhotoKit: "This macOS version cannot open the selected library directly."
        case .database(let detail): "Could not read the library catalog: \(detail)"
        case .media(let detail): detail
        }
    }
}

nonisolated struct PhotoCatalogTextMetadata: Codable, Sendable {
    let title: String
    let caption: String
    let keywords: [String]

    func matches(_ other: Self) -> Bool {
        title == other.title && caption == other.caption
            && keywords.count == other.keywords.count
            && Set(keywords) == Set(other.keywords)
    }
}

/// Kept independent of the app-only PhotoKit model because this source file
/// is also compiled into the direct-library helper target.
nonisolated struct SystemAlbumAssetIdentity: Sendable {
    let id: String
    let creationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
}

nonisolated struct DirectLibrarySelectedSystemMetadata: Sendable {
    let albumsByAssetID: [String: [PhotoTransferAlbum]]
    let textByAssetID: [String: PhotoCatalogTextMetadata]
}

nonisolated struct DirectLibraryCatalog: Codable, Sendable {
    let items: [PhotosAutomationMediaItem]
    let albums: [PhotosAutomationAlbum]
    let folders: [DirectLibraryFolder]
    let livePhotoIDs: Set<String>
    let videoDurations: [String: TimeInterval]
    let rawTitlesByID: [String: String]

    func textMetadata(for id: String) -> PhotoCatalogTextMetadata? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return PhotoCatalogTextMetadata(
            title: rawTitlesByID[id] ?? "",
            caption: item.itemDescription,
            keywords: item.keywords
        )
    }

    /// The registered System package is only a read-only source of album
    /// membership. Match every selected PhotoKit item before using its rows.
    static func readSelectedTransferMetadata(
        from libraryURL: URL,
        matching assets: [SystemAlbumAssetIdentity]
    ) throws -> DirectLibrarySelectedSystemMetadata {
        try Task.checkCancellation()
        let catalog = try read(from: libraryURL, requireAlbumSchema: true)
        try Task.checkCancellation()
        var catalogItems: [String: PhotosAutomationMediaItem] = [:]
        for item in catalog.items {
            let key = item.id.uppercased()
            guard catalogItems.updateValue(item, forKey: key) == nil else {
                throw DirectLibraryError.database("The System catalog has duplicate asset UUIDs.")
            }
        }
        var selectedUUIDs = Set<String>()
        var identifiersByUUID: [String: String] = [:]
        var textByAssetID: [String: PhotoCatalogTextMetadata] = [:]
        for asset in assets {
            try Task.checkCancellation()
            guard let firstComponent = asset.id.split(separator: "/").first,
                  let uuid = UUID(uuidString: String(firstComponent))?.uuidString,
                  selectedUUIDs.insert(uuid).inserted,
                  let item = catalogItems[uuid],
                  item.pixelWidth == asset.pixelWidth,
                  item.pixelHeight == asset.pixelHeight else {
                throw DirectLibraryError.database(
                    "The registered System catalog does not match a selected PhotoKit photo."
                )
            }
            let datesMatch: Bool
            if let expected = asset.creationDate, let actual = item.captureDate {
                datesMatch = abs(expected.timeIntervalSince(actual)) < 1
            } else {
                datesMatch = asset.creationDate == nil && item.captureDate == nil
            }
            guard datesMatch else {
                throw DirectLibraryError.database(
                    "The registered System catalog has a different capture date for a selected photo."
                )
            }
            identifiersByUUID[uuid] = asset.id
            textByAssetID[asset.id] = PhotoCatalogTextMetadata(
                title: catalog.rawTitlesByID[item.id] ?? "",
                caption: item.itemDescription,
                keywords: item.keywords
            )
        }
        var memberships = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, [PhotoTransferAlbum]())
        })
        for album in catalog.albums {
            try Task.checkCancellation()
            guard let memberIDs = album.mediaItemIDs else {
                throw DirectLibraryError.database("The System catalog did not index album memberships.")
            }
            let selectedMembers = memberIDs.compactMap { identifiersByUUID[$0.uppercased()] }
            guard !selectedMembers.isEmpty else { continue }
            guard !album.id.isEmpty, !album.name.isEmpty,
                  let folders = album.folderNames,
                  folders.allSatisfy({ !$0.isEmpty }) else {
                throw DirectLibraryError.database(
                    "A selected System album has an unverifiable name or folder path."
                )
            }
            let transferAlbum = PhotoTransferAlbum(
                sourceID: album.id, name: album.name, folderNames: folders
            )
            for assetID in selectedMembers {
                memberships[assetID, default: []].append(transferAlbum)
            }
        }
        return DirectLibrarySelectedSystemMetadata(
            albumsByAssetID: memberships, textByAssetID: textByAssetID
        )
    }

    /// Read one System-library item's Photos catalog fields without opening Photos.
    /// The package is read only; SQLite operates on a temporary snapshot so an
    /// active Photos WAL is included without writing inside the library.
    static func readTextMetadata(
        from libraryURL: URL,
        assetIdentifier: String,
        expectedDate: Date?,
        expectedWidth: Int,
        expectedHeight: Int
    ) throws -> PhotoCatalogTextMetadata {
        guard let firstComponent = assetIdentifier.split(separator: "/").first,
              let uuid = UUID(uuidString: String(firstComponent))?.uuidString else {
            throw DirectLibraryError.database("The PhotoKit asset identifier has no catalog UUID.")
        }
        let files = FileManager.default
        let original = libraryURL.appendingPathComponent("database/Photos.sqlite")
        let snapshotDirectory = files.temporaryDirectory.appendingPathComponent(
            "PhotoLibrariesText-\(UUID().uuidString)", isDirectory: true
        )
        try files.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: snapshotDirectory) }
        let copy = snapshotDirectory.appendingPathComponent("Photos.sqlite")
        do {
            try files.copyItem(at: original, to: copy)
            let wal = URL(fileURLWithPath: original.path + "-wal")
            if files.fileExists(atPath: wal.path) {
                try files.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal"))
            }
        } catch { throw DirectLibraryError.database(error.localizedDescription) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw DirectLibraryError.database("SQLite could not open its temporary snapshot")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        var statement: OpaquePointer?
        let assetSQL = """
            SELECT COALESCE(d.ZTITLE, ''), COALESCE(x.ZLONGDESCRIPTION, ''),
                   a.ZDATECREATED, a.ZWIDTH, a.ZHEIGHT, d.Z_PK
            FROM ZASSET a
            LEFT JOIN ZADDITIONALASSETATTRIBUTES d ON d.Z_PK = a.ZADDITIONALATTRIBUTES
            LEFT JOIN ZASSETDESCRIPTION x ON x.Z_PK = d.ZASSETDESCRIPTION
            WHERE a.ZUUID = ? COLLATE NOCASE AND COALESCE(a.ZTRASHEDSTATE, 0) = 0
            """
        guard sqlite3_prepare_v2(db, assetSQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = uuid.withCString { pointer in
            sqlite3_bind_text(statement, 1, pointer, -1, transient)
        }
        guard bindResult == SQLITE_OK else {
            throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DirectLibraryError.database("The selected PhotoKit asset was not found in the registered System Library catalog.")
        }
        let catalogDate = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
        let dateMatches: Bool
        if let expectedDate, let catalogDate {
            dateMatches = abs(expectedDate.timeIntervalSince(catalogDate)) < 1
        } else {
            dateMatches = expectedDate == nil && catalogDate == nil
        }
        guard Int(sqlite3_column_int(statement, 3)) == expectedWidth,
              Int(sqlite3_column_int(statement, 4)) == expectedHeight,
              dateMatches else {
            throw DirectLibraryError.database("The registered System Library does not match the selected PhotoKit asset.")
        }
        let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let caption = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let attributesID = sqlite3_column_type(statement, 5) == SQLITE_NULL
            ? nil : sqlite3_column_int64(statement, 5)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DirectLibraryError.database("More than one catalog item matched the selected PhotoKit asset.")
        }

        var entities: [String: Int32] = [:]
        var entityStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY", -1, &entityStatement, nil) == SQLITE_OK,
              let entityStatement else {
            throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(entityStatement) }
        while true {
            let result = sqlite3_step(entityStatement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
            if let name = sqlite3_column_text(entityStatement, 0) {
                entities[String(cString: name)] = sqlite3_column_int(entityStatement, 1)
            }
        }
        var keywords: [String] = []
        if let attributesID,
           let attributesEntity = entities["AdditionalAssetAttributes"],
           let keywordEntity = entities["Keyword"] {
            let keywordSQL = """
                SELECT k.ZTITLE
                FROM Z_\(attributesEntity)KEYWORDS j
                JOIN ZKEYWORD k ON k.Z_PK = j.Z_\(keywordEntity)KEYWORDS
                WHERE j.Z_\(attributesEntity)ASSETATTRIBUTES = ? AND k.ZTITLE IS NOT NULL
                ORDER BY k.ZTITLE
                """
            var keywordStatement: OpaquePointer?
            guard sqlite3_prepare_v2(db, keywordSQL, -1, &keywordStatement, nil) == SQLITE_OK,
                  let keywordStatement else {
                throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(keywordStatement) }
            sqlite3_bind_int64(keywordStatement, 1, attributesID)
            while true {
                let result = sqlite3_step(keywordStatement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
                }
                if let value = sqlite3_column_text(keywordStatement, 0) {
                    keywords.append(String(cString: value))
                }
            }
        }
        return PhotoCatalogTextMetadata(title: title, caption: caption, keywords: keywords)
    }

    static func read(
        from libraryURL: URL,
        requireAlbumSchema: Bool = false
    ) throws -> Self {
        try Task.checkCancellation()
        let files = FileManager.default
        let original = libraryURL.appendingPathComponent("database/Photos.sqlite")
        let snapshotDirectory = files.temporaryDirectory.appendingPathComponent(
            "PhotoLibrariesCatalog-\(UUID().uuidString)", isDirectory: true
        )
        try files.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: snapshotDirectory) }
        let copy = snapshotDirectory.appendingPathComponent("Photos.sqlite")
        do {
            try files.copyItem(at: original, to: copy)
            try Task.checkCancellation()
            let wal = URL(fileURLWithPath: original.path + "-wal")
            if files.fileExists(atPath: wal.path) {
                try files.copyItem(
                    at: wal, to: URL(fileURLWithPath: copy.path + "-wal")
                )
            }
            try Task.checkCancellation()
        } catch { throw DirectLibraryError.database(error.localizedDescription) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close(db) }
            throw DirectLibraryError.database("SQLite could not open its temporary snapshot")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
        }

        func rows(_ sql: String, _ consume: (OpaquePointer) -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            while true {
                try Task.checkCancellation()
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else {
                    throw DirectLibraryError.database(String(cString: sqlite3_errmsg(db)))
                }
                consume(statement)
            }
        }
        func string(_ statement: OpaquePointer, _ column: Int32) -> String {
            sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
        }

        var items: [PhotosAutomationMediaItem] = []
        var rawTitlesByID: [String: String] = [:]
        var liveIDs = Set<String>()
        var videoDurations: [String: TimeInterval] = [:]
        var assetColumns = Set<String>()
        try rows("PRAGMA table_info(ZASSET)") { row in
            assetColumns.insert(string(row, 1))
        }
        let durationColumn = assetColumns.contains("ZDURATION") ? "a.ZDURATION" : "NULL"
        try rows("""
            SELECT a.ZUUID, COALESCE(d.ZORIGINALFILENAME, a.ZFILENAME, ''),
                   COALESCE(d.ZTITLE, ''), a.ZDATECREATED, a.ZFAVORITE,
                   a.ZWIDTH, a.ZHEIGHT, d.ZORIGINALFILESIZE,
                   a.ZLATITUDE, a.ZLONGITUDE, a.ZKINDSUBTYPE,
                   COALESCE(x.ZLONGDESCRIPTION, ''), \(durationColumn)
            FROM ZASSET a
            LEFT JOIN ZADDITIONALASSETATTRIBUTES d ON d.Z_PK = a.ZADDITIONALATTRIBUTES
            LEFT JOIN ZASSETDESCRIPTION x ON x.Z_PK = d.ZASSETDESCRIPTION
            WHERE a.ZUUID IS NOT NULL AND COALESCE(a.ZTRASHEDSTATE, 0) = 0
            ORDER BY a.ZDATECREATED, a.Z_PK
            """) { row in
            let id = string(row, 0)
            let filename = string(row, 1)
            let title = string(row, 2)
            if !title.isEmpty { rawTitlesByID[id] = title }
            let capture = sqlite3_column_type(row, 3) == SQLITE_NULL ? nil
                : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 3))
            let size = sqlite3_column_type(row, 7) == SQLITE_NULL ? nil
                : Int(sqlite3_column_int64(row, 7))
            let latitude = sqlite3_column_double(row, 8)
            let longitude = sqlite3_column_double(row, 9)
            let location = sqlite3_column_type(row, 8) == SQLITE_NULL
                || sqlite3_column_type(row, 9) == SQLITE_NULL ? ""
                : "\(latitude), \(longitude)"
            if sqlite3_column_int(row, 10) & 2 != 0 { liveIDs.insert(id) }
            if sqlite3_column_type(row, 12) != SQLITE_NULL {
                let duration = sqlite3_column_double(row, 12)
                if duration.isFinite, duration > 0 { videoDurations[id] = duration }
            }
            items.append(PhotosAutomationMediaItem(
                id: id, filename: filename, name: title.isEmpty ? filename : title,
                itemDescription: string(row, 11),
                dateDescription: capture?.formatted(date: .abbreviated, time: .shortened) ?? "",
                captureDate: capture, isFavorite: sqlite3_column_int(row, 4) != 0,
                pixelWidth: Int(sqlite3_column_int(row, 5)),
                pixelHeight: Int(sqlite3_column_int(row, 6)),
                fileSize: size.flatMap { $0 > 0 ? $0 : nil },
                locationDescription: location, keywords: []
            ))
        }

        var entities: [String: Int32] = [:]
        try rows("SELECT Z_NAME, Z_ENT FROM Z_PRIMARYKEY") { row in
            entities[string(row, 0)] = sqlite3_column_int(row, 1)
        }
        var albums: [PhotosAutomationAlbum] = []
        var directFolders: [DirectLibraryFolder] = []
        if requireAlbumSchema,
           (entities["Album"] == nil || entities["Asset"] == nil) {
            throw DirectLibraryError.database(
                "The System catalog album membership schema is unavailable."
            )
        }
        if requireAlbumSchema,
           (entities["AdditionalAssetAttributes"] == nil || entities["Keyword"] == nil) {
            throw DirectLibraryError.database(
                "The System catalog keyword schema is unavailable."
            )
        }
        if let albumEntity = entities["Album"], let assetEntity = entities["Asset"] {
            var folderRecords: [Int64: (uuid: String, name: String, parentID: Int64?)] = [:]
            var rootFolderIDs = Set<Int64>()
            // Photos catalog ZKIND 3999 is the root; 4000 is a user folder.
            try rows("SELECT Z_PK, ZTITLE, ZPARENTFOLDER, ZKIND, ZUUID FROM ZGENERICALBUM WHERE ZKIND IN (3999, 4000) AND COALESCE(ZTRASHEDSTATE, 0) = 0") { row in
                let id = sqlite3_column_int64(row, 0)
                if sqlite3_column_int(row, 3) == 3999 {
                    rootFolderIDs.insert(id)
                } else {
                    let parentID = sqlite3_column_type(row, 2) == SQLITE_NULL
                        ? nil : sqlite3_column_int64(row, 2)
                    folderRecords[id] = (string(row, 4), string(row, 1), parentID)
                }
            }
            func folderPath(for parentID: Int64?) -> [String]? {
                guard var currentID = parentID else { return [] }
                var visited = Set<Int64>()
                var reversed: [String] = []
                guard rootFolderIDs.count == 1, let rootID = rootFolderIDs.first else { return nil }
                if currentID == rootID { return [] }
                while let folder = folderRecords[currentID], visited.insert(currentID).inserted {
                    guard !folder.name.isEmpty else { return nil }
                    reversed.append(folder.name)
                    guard let nextID = folder.parentID else { return nil }
                    if nextID == rootID { return Array(reversed.reversed()) }
                    currentID = nextID
                }
                return nil
            }
            for (id, folder) in folderRecords {
                if let path = folderPath(for: id),
                   !folder.uuid.isEmpty {
                    directFolders.append(DirectLibraryFolder(id: folder.uuid, path: path))
                }
            }
            var members: [Int64: [String]] = [:]
            let join = "Z_\(albumEntity)ASSETS"
            try rows("""
                SELECT j.Z_\(albumEntity)ALBUMS, a.ZUUID
                FROM \(join) j JOIN ZASSET a ON a.Z_PK = j.Z_\(assetEntity)ASSETS
                WHERE a.ZUUID IS NOT NULL AND COALESCE(a.ZTRASHEDSTATE, 0) = 0
                """) { row in
                members[sqlite3_column_int64(row, 0), default: []].append(string(row, 1))
            }
            try rows("""
                SELECT album.Z_PK, album.ZUUID, album.ZTITLE, parent.ZTITLE, album.ZPARENTFOLDER
                FROM ZGENERICALBUM album
                LEFT JOIN ZGENERICALBUM parent
                  ON parent.Z_PK = album.ZPARENTFOLDER
                WHERE album.Z_ENT = \(albumEntity) AND album.ZTITLE IS NOT NULL
                  AND COALESCE(album.ZTRASHEDSTATE, 0) = 0
                  AND album.ZKIND NOT IN (3571, 3572, 3573)
                """) { row in
                let ids = members[sqlite3_column_int64(row, 0)] ?? []
                let parentID = sqlite3_column_type(row, 4) == SQLITE_NULL
                    ? nil : sqlite3_column_int64(row, 4)
                albums.append(PhotosAutomationAlbum(
                    id: string(row, 1), name: string(row, 2),
                    parentName: sqlite3_column_type(row, 3) == SQLITE_NULL
                        ? nil : string(row, 3),
                    mediaItemCount: ids.count, mediaItemIDs: ids,
                    folderNames: folderPath(for: parentID)
                ))
            }
        }
        if let attributesEntity = entities["AdditionalAssetAttributes"],
           let keywordEntity = entities["Keyword"] {
            var keywords: [String: [String]] = [:]
            // Keyword membership is optional on older catalog schemas. The
            // main photo list remains usable if this relation is absent.
            try? rows("""
                SELECT a.ZUUID, k.ZTITLE
                FROM ZASSET a
                JOIN ZADDITIONALASSETATTRIBUTES d
                  ON d.Z_PK = a.ZADDITIONALATTRIBUTES
                JOIN Z_\(attributesEntity)KEYWORDS j
                  ON j.Z_\(attributesEntity)ASSETATTRIBUTES = d.Z_PK
                JOIN ZKEYWORD k ON k.Z_PK = j.Z_\(keywordEntity)KEYWORDS
                WHERE a.ZUUID IS NOT NULL AND k.ZTITLE IS NOT NULL
                """) { row in
                keywords[string(row, 0), default: []].append(string(row, 1))
            }
            items = items.map { item in
                PhotosAutomationMediaItem(
                    id: item.id, filename: item.filename, name: item.name,
                    itemDescription: item.itemDescription,
                    dateDescription: item.dateDescription,
                    captureDate: item.captureDate, isFavorite: item.isFavorite,
                    pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
                    fileSize: item.fileSize,
                    locationDescription: item.locationDescription,
                    keywords: keywords[item.id] ?? []
                )
            }
        }
        return Self(
            items: items, albums: albums, folders: directFolders,
            livePhotoIDs: liveIDs, videoDurations: videoDurations,
            rawTitlesByID: rawTitlesByID
        )
    }
}

nonisolated struct DirectLibraryFolder: Codable, Sendable {
    let id: String
    let path: [String]
}
