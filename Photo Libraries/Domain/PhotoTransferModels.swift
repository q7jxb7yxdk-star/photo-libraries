import Foundation

nonisolated struct PhotoTransferLocation: Sendable, Hashable, Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?

    func matches(_ other: PhotoTransferLocation) -> Bool {
        abs(latitude - other.latitude) < 0.00001
            && abs(longitude - other.longitude) < 0.00001
    }

    static func fromPhotosDescription(_ value: String) -> PhotoTransferLocation? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let latitude = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let longitude = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return PhotoTransferLocation(latitude: latitude, longitude: longitude, altitude: nil)
    }
}

nonisolated struct PhotoTransferAlbum: Sendable, Hashable, Codable {
    let sourceID: String
    let name: String
    let folderNames: [String]
}

nonisolated struct PendingSystemSourceDeletion: Identifiable, Sendable, Hashable {
    nonisolated struct Source: Sendable, Hashable {
        let assetIdentifier: String
        let displayName: String
        let destinationItemIdentifier: String
        let captureDate: Date
        let sourceModificationDate: Date?
        let sourceAlbums: [PhotoTransferAlbum]
    }

    let id: UUID
    let sources: [Source]
    let destinationDisplayName: String
    let retainedSourceCount: Int
    let deletionWarnings: [String]

    var sourceDisplayName: String {
        sources.count == 1 ? sources[0].displayName : "\(sources.count) selected items"
    }

    var retainedSourceExplanation: String {
        retainedSourceCount == 0
            ? ""
            : " \(retainedSourceCount) other selected source(s) will remain."
    }

    init(
        sources: [Source],
        destinationDisplayName: String,
        retainedSourceCount: Int = 0,
        deletionWarnings: [String] = []
    ) {
        precondition(!sources.isEmpty)
        id = UUID()
        self.sources = sources
        self.destinationDisplayName = destinationDisplayName
        self.retainedSourceCount = retainedSourceCount
        self.deletionWarnings = deletionWarnings
    }
}

nonisolated struct PendingRegisteredSourceDeletion: Identifiable, Sendable, Hashable {
    nonisolated struct Source: Sendable, Hashable {
        let sourceUUID: String
        let displayName: String
        let destinationAssetIDs: [String]
        let captureDate: Date?
        let location: PhotoTransferLocation?
        let isFavorite: Bool
        let resourceHashes: [String]
        let sourceAlbums: [PhotoTransferAlbum]
    }

    let id = UUID()
    let sourceLibraryID: LibraryID
    let sourceDisplayName: String
    let sources: [Source]
}

nonisolated enum PhotoTransferError: LocalizedError, Sendable {
    case operationInProgress
    case sourceIndexUnavailable(String)
    case targetIndexUnavailable(String)
    case catalogIdentityTimedOut(String)
    case catalogIdentityAmbiguous(String)
    case noImportableResources
    case importCreationNotVerified
    case importEvidenceMismatch(String)
    case ambiguousSourceAlbums(String)
    case sourceAlbumAccessLimited
    case sourceMetadataUnavailable
    case systemLibraryNotRegistered
    case systemSourceMissing(String)
    case duplicateSystemSources

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another photo transfer is already in progress."
        case .sourceIndexUnavailable(let name):
            return "A non-empty synchronized index for source library \(name) is required before copying."
        case .targetIndexUnavailable(let name):
            return "A non-empty synchronized index for destination library \(name) is required before moving or copying."
        case .catalogIdentityTimedOut(let name):
            return "Photos did not expose a stable catalog matching \(name) before the operation timed out. The source was retained."
        case .catalogIdentityAmbiguous(let name):
            return "The open Photos catalog could not be uniquely identified as \(name). The source was retained."
        case .noImportableResources:
            return "The staged export did not contain a photo or video resource that can be safely imported."
        case .importCreationNotVerified:
            return "The destination did not provide unambiguous evidence that new items were created. The source was retained."
        case .importEvidenceMismatch(let detail):
            return "The destination import could not be verified: \(detail) The source was retained."
        case .ambiguousSourceAlbums(let name):
            return "More than one selected source album has the same folder path and name (\(name)). The destination album cannot be chosen safely. No source was deleted."
        case .sourceAlbumAccessLimited:
            return "Full System Photo Library access is required to preserve every album membership before moving. No source was deleted."
        case .sourceMetadataUnavailable:
            return "The source photo's capture metadata could not be verified before import. The source was retained."
        case .systemLibraryNotRegistered:
            return "The System Photo Library must be registered and available before source deletion. No deletion was requested."
        case .systemSourceMissing(let identifier):
            return "System Photo Library source \(identifier) is no longer available. No deletion was requested."
        case .duplicateSystemSources:
            return "The pending deletion contains duplicate System Photo Library sources. No deletion was requested."
        }
    }
}
