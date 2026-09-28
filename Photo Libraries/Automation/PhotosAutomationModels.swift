import Foundation

/// Direct catalogs store Photos' UUID, while PhotoKit and Photos Automation
/// may return a local identifier with additional path components. Match only
/// the UUID, but keep the exact Automation identifier for AppleScript calls.
nonisolated enum PhotosAssetIdentity {
    enum MappingError: LocalizedError {
        case invalidIdentifier(String)
        case ambiguousUUID(String)
        case missingAutomationIdentifier(String)

        var errorDescription: String? {
            switch self {
            case .invalidIdentifier(let identifier):
                "Photos returned an unrecognized media item ID (\(identifier)). The source was retained."
            case .ambiguousUUID(let uuid):
                "Photos returned more than one media item for UUID \(uuid). The source was retained."
            case .missingAutomationIdentifier(let identifier):
                "The selected photo \(identifier) was not found in the verified Photos catalog. The source was retained."
            }
        }
    }

    static func uuid(for identifier: String) -> String? {
        let parts = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first,
              parts.dropFirst().allSatisfy({ !$0.isEmpty }),
              let value = UUID(uuidString: String(first)) else { return nil }
        return value.uuidString
    }

    static func uuidSet(for identifiers: [String]) -> Set<String>? {
        var result = Set<String>()
        for identifier in identifiers {
            guard let uuid = uuid(for: identifier), result.insert(uuid).inserted else {
                return nil
            }
        }
        return result
    }

    static func automationIDsByUUID(_ identifiers: Set<String>) throws -> [String: String] {
        var result: [String: String] = [:]
        for identifier in identifiers {
            guard let uuid = uuid(for: identifier) else {
                throw MappingError.invalidIdentifier(identifier)
            }
            guard result.updateValue(identifier, forKey: uuid) == nil else {
                throw MappingError.ambiguousUUID(uuid)
            }
        }
        return result
    }
}

/// A deliberately small, read-only view of the metadata exposed by Photos'
/// public AppleScript dictionary.
nonisolated struct PhotosAutomationMediaItem: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let filename: String
    let name: String
    let itemDescription: String
    let dateDescription: String
    let captureDate: Date?
    let isFavorite: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let fileSize: Int?
    let locationDescription: String
    let keywords: [String]
}

nonisolated struct PhotosAutomationAlbum: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let name: String
    let parentName: String?
    /// Full parent folder path when the direct catalog can prove it.
    let folderNames: [String]?
    let mediaItemCount: Int
    /// Optional so indexes created before album filtering remain decodable.
    /// A nil value means membership has not been indexed yet; an empty array
    /// is a known-empty album.
    let mediaItemIDs: [String]?

    init(
        id: String,
        name: String,
        parentName: String?,
        mediaItemCount: Int,
        mediaItemIDs: [String]? = nil,
        folderNames: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.parentName = parentName
        self.folderNames = folderNames
        self.mediaItemCount = mediaItemCount
        self.mediaItemIDs = mediaItemIDs
    }
}

/// One page of album metadata from the currently open Photos library. Album
/// Membership is read separately in bounded pages after this metadata pass.
nonisolated struct PhotosAutomationAlbumCatalogPage: Sendable, Hashable {
    let totalAlbumCount: Int
    let albums: [PhotosAutomationAlbum]
}

nonisolated struct PhotosAutomationAlbumMembershipPage: Sendable, Hashable {
    let totalMediaItemCount: Int
    let mediaItemIDs: [String]
}

struct PhotosAutomationFolder: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let parentName: String?
    let albumCount: Int
    let folderCount: Int
}

struct PhotosAutomationLibrarySnapshot: Sendable, Hashable {
    let totalAlbumCount: Int
    let totalFolderCount: Int
    let totalMediaItemCount: Int
    let albums: [PhotosAutomationAlbum]
    let folders: [PhotosAutomationFolder]
    let mediaItems: [PhotosAutomationMediaItem]
}

struct PhotosAutomationMediaCatalogPage: Sendable, Hashable {
    let totalMediaItemCount: Int
    let mediaItems: [PhotosAutomationMediaItem]
}

struct PhotosAutomationCatalogFingerprint: Sendable, Hashable {
    let totalMediaItemCount: Int
    let mediaItemIdentifiers: [String]
}

/// The fast first phase of non-system-library indexing. Slow properties such
/// as captions, keywords, and locations are intentionally left empty and are
/// filled by a later background enrichment pass.
struct PhotosAutomationBasicCatalog: Sendable, Hashable {
    let totalMediaItemCount: Int
    let mediaItems: [PhotosAutomationMediaItem]
}

struct PhotosAutomationSearchResult: Sendable, Hashable {
    let totalMatchCount: Int
    let mediaItems: [PhotosAutomationMediaItem]
}

struct PhotosAutomationOpenResult: Sendable, Hashable {
    let requestedLibraryURL: URL
    let photosWasAlreadyRunning: Bool

    /// Photos does not expose its current library URL through its public
    /// scripting dictionary. A successful `open` event therefore confirms
    /// event acceptance, not that Photos has completed loading that library.
    let currentLibraryIdentityWasVerified: Bool
}

enum PhotosAutomationExportVersion: Sendable, Hashable {
    case original
    case rendered
}

struct PhotosAutomationExportResult: Sendable, Hashable {
    let mediaItemID: String
    let reportedFilename: String
    let version: PhotosAutomationExportVersion
    let destinationDirectory: URL

    /// Files visible in the newly-created, initially empty export directory
    /// after Photos returned from the export command. Photos does not return
    /// a resource manifest, so this is observation rather than a fidelity
    /// guarantee for Live Photos, RAW pairs, bursts, or adjustment resources.
    let observedFiles: [URL]
}

nonisolated struct PhotosAutomationImportedItem: Sendable, Hashable {
    let id: String
    let filename: String
}

/// Evidence returned by one synchronous Photos import command. The caller also
/// checks these IDs against the destination IDs captured before the import.
nonisolated struct PhotosAutomationImportResult: Sendable, Hashable {
    let requestedFiles: [URL]
    let importedItems: [PhotosAutomationImportedItem]
    let verifiedItemIdentifiers: [String]

    var createdItemCount: Int {
        importedItems.count
    }

    func verificationIssue(
        knownDestinationIDs: Set<String>,
        expectedItemCount: Int? = nil
    ) -> String? {
        let importedIDs = importedItems.map(\.id)
        let importedIdentifiers = Set(importedIDs)
        let expectedCount = expectedItemCount ?? requestedFiles.count
        if importedIDs.isEmpty {
            return "Photos returned no new item IDs for \(requestedFiles.count) staged file(s)."
        }
        if importedIDs.count != expectedCount {
            return "Photos returned \(importedIDs.count) item ID(s) for \(requestedFiles.count) staged file(s); expected \(expectedCount) destination item(s)."
        }
        if importedIDs.contains(where: { $0.isEmpty }) || importedIdentifiers.count != importedIDs.count {
            return "Photos returned an empty or repeated item ID among \(importedIDs.count) imported item(s)."
        }
        if verifiedItemIdentifiers.count != importedIDs.count
            || Set(verifiedItemIdentifiers) != importedIdentifiers {
            return "Photos returned \(importedIDs.count) imported item ID(s), but only \(verifiedItemIdentifiers.count) ID(s) resolved in the destination catalog."
        }
        let existingCount = importedIdentifiers.intersection(knownDestinationIDs).count
        if existingCount > 0 {
            return "\(existingCount) returned item ID(s) already existed in the destination before this transfer."
        }
        return nil
    }
}

struct PhotosAutomationBatchExportItemResult: Sendable, Hashable {
    let requestedMediaItemID: String
    let exportResult: PhotosAutomationExportResult?
    let errorDescription: String?
}

struct PhotosAutomationBatchExportResult: Sendable, Hashable {
    let destinationDirectory: URL
    let itemResults: [PhotosAutomationBatchExportItemResult]
}

enum PhotosAutomationError: LocalizedError, Sendable, Equatable {
    case invalidPhotoLibrary(URL)
    case libraryUnavailable(URL)
    case invalidLimit(Int)
    case invalidMediaCatalogLimit(Int)
    case invalidOffset(Int)
    case invalidBatchExportCount(Int)
    case invalidImportCount(Int)
    case importFileUnavailable(URL)
    case emptySearchQuery
    case invalidMediaItemIdentifier
    case invalidAlbumIdentifier
    case albumNotFound(String)
    case stagingDirectoryUnavailable(URL, String)
    case mediaItemNotFound(String)
    case automationDenied(String)
    case photosNotAvailable(String)
    case timedOut(String)
    case scriptCompilation(String)
    case scriptExecution(number: Int?, message: String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidPhotoLibrary(let url):
            return "The selected item is not a .photoslibrary package: \(url.path)"
        case .libraryUnavailable(let url):
            return "The photo library is unavailable or is not a directory: \(url.path)"
        case .invalidLimit(let limit):
            return "The item limit must be between 1 and 200 (received \(limit))."
        case .invalidMediaCatalogLimit(let limit):
            return "The media catalog page size must be between 1 and 500 (received \(limit))."
        case .invalidOffset(let offset):
            return "The item offset must not be negative (received \(offset))."
        case .invalidBatchExportCount(let count):
            return "A batch export must contain between 1 and 100 items (received \(count))."
        case .invalidImportCount(let count):
            return "An import must contain between 1 and 100 files (received \(count))."
        case .importFileUnavailable(let url):
            return "The file to import is unavailable or is not a regular file: \(url.path)"
        case .emptySearchQuery:
            return "Enter a non-empty Photos search query."
        case .invalidMediaItemIdentifier:
            return "The Photos media-item identifier is empty."
        case .invalidAlbumIdentifier:
            return "The Photos album identifier is empty."
        case .albumNotFound(let identifier):
            return "Photos could not find album \(identifier) in its currently open library."
        case .stagingDirectoryUnavailable(let url, let reason):
            return "The staging directory is unavailable at \(url.path): \(reason)"
        case .mediaItemNotFound(let identifier):
            return "Photos could not find media item \(identifier) in its currently open library."
        case .automationDenied(let message):
            return "Automation access to Photos was denied. \(message)"
        case .photosNotAvailable(let message):
            return "Photos is unavailable or stopped responding. \(message)"
        case .timedOut(let message):
            return "Photos Automation timed out. \(message)"
        case .scriptCompilation(let message):
            return "The Photos Automation script could not be compiled. \(message)"
        case .scriptExecution(let number, let message):
            if let number {
                return "Photos Automation failed (AppleScript error \(number)). \(message)"
            }
            return "Photos Automation failed. \(message)"
        case .malformedResponse(let detail):
            return "Photos returned an unexpected Automation response. \(detail)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .automationDenied:
            return "Allow this app to control Photos in System Settings > Privacy & Security > Automation, then explicitly retry the operation."
        case .photosNotAvailable:
            return "Open Photos and resolve any library repair, migration, or modal dialog before retrying."
        case .timedOut:
            return "Wait for Photos to finish loading or downloading, then explicitly retry."
        case .libraryUnavailable:
            return "Reconnect the volume or ask the user to reauthorize the library bookmark."
        default:
            return nil
        }
    }
}
