import Foundation
import Photos

nonisolated enum PhotoLibraryAuthorization: String, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
    case unknown

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .limited:
            self = .limited
        @unknown default:
            self = .unknown
        }
    }

    var permitsReading: Bool {
        self == .authorized || self == .limited
    }
}

struct PhotoAssetSummary: Identifiable, Hashable, Sendable {
    let id: String
    let originalFilename: String
    let mediaType: String
    let pixelWidth: Int
    let pixelHeight: Int
    let duration: TimeInterval
    let creationDate: Date?
    let modificationDate: Date?
    let isFavorite: Bool
    let isHidden: Bool
    let representsBurst: Bool
    let isLivePhoto: Bool
    let mediaCategories: Set<MediaCategory>
    let coordinate: SearchCoordinate?
}

struct PhotoCollectionNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case folder
        case album
    }

    let id: String
    let title: String
    let kind: Kind
    let assetCount: Int?
    let children: [PhotoCollectionNode]
}

struct PhotoAssetResourceRecord: Identifiable, Hashable, Sendable {
    let id: String
    let index: Int
    let type: String
    let originalFilename: String
    let uniformTypeIdentifier: String
}

nonisolated enum PhotoAssetTransferFidelity: Sendable, Hashable {
    case ordinarySingleResource
    case safeCopyOnly(reasons: [String])

    var permitsAutomaticSystemSourceDeletion: Bool {
        if case .ordinarySingleResource = self { return true }
        return false
    }

    var warning: String? {
        guard case .safeCopyOnly(let reasons) = self else { return nil }
        return reasons.joined(separator: " ")
    }
}

nonisolated struct PhotoKitImportResult: Sendable, Hashable {
    let requestedFiles: [URL]
    let createdAssetIdentifiers: [String]
    let verifiedAssetIdentifiers: [String]

    var isVerifiedCreation: Bool {
        !createdAssetIdentifiers.isEmpty
            && Set(createdAssetIdentifiers) == Set(verifiedAssetIdentifiers)
    }
}

struct PhotoResourceExportProgress: Sendable {
    let completedResourceCount: Int
    let totalResourceCount: Int
    let currentFilename: String?
}

struct PhotoResourceExportManifest: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let resourceIndex: Int
        let resourceType: String
        let originalFilename: String
        let uniformTypeIdentifier: String
        let stagedFilename: String
        let byteCount: Int64
        let sha256: String
    }

    let schemaVersion: Int
    let jobID: UUID
    let sourceAssetLocalIdentifier: String
    let createdAt: Date
    let entries: [Entry]
}

nonisolated enum SystemPhotoLibraryError: LocalizedError {
    case accessNotAuthorized(PhotoLibraryAuthorization)
    case assetNotFound(String)
    case noResources(String)
    case cannotCreateStagingDirectory(URL, Error)
    case cannotCreateStagingFile(URL, Error)
    case resourceWriteFailed(URL, Error)
    case resourceRequestFailed(String, Error?)
    case currentAppearanceUnavailable(String, Error?)
    case noImportableFiles
    case unsupportedImportFile(URL)
    case importFailed(Error)
    case importVerificationFailed
    case livePhotoPairNotVerified
    case sourceChangedSinceSelection(String)
    case deletionFailed(Error)
    case deletionVerificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessNotAuthorized(let status):
            return "Photo Library read access is unavailable (\(status.rawValue))."
        case .assetNotFound(let identifier):
            return "No PhotoKit asset was found for \(identifier)."
        case .noResources(let identifier):
            return "PhotoKit returned no resources for asset \(identifier)."
        case .cannotCreateStagingDirectory(let url, let error):
            return "Could not create staging directory at \(url.path): \(error.localizedDescription)"
        case .cannotCreateStagingFile(let url, let error):
            return "Could not create staging file at \(url.path): \(error.localizedDescription)"
        case .resourceWriteFailed(let url, let error):
            return "Could not write staged resource at \(url.path): \(error.localizedDescription)"
        case .resourceRequestFailed(let filename, let error):
            return "PhotoKit could not provide \(filename): \(error?.localizedDescription ?? "unknown error")"
        case .currentAppearanceUnavailable(let filename, let error):
            return "PhotoKit could not render the current appearance of \(filename): \(error?.localizedDescription ?? "no usable image data")"
        case .noImportableFiles:
            return "No staged photo or video files were available to import."
        case .unsupportedImportFile(let url):
            return "PhotoKit cannot classify the staged file as a photo or video: \(url.lastPathComponent)"
        case .importFailed(let error):
            return "PhotoKit could not import the staged files: \(error.localizedDescription)"
        case .importVerificationFailed:
            return "PhotoKit completed the change, but the newly created assets could not all be verified. The source was retained."
        case .livePhotoPairNotVerified:
            return "PhotoKit did not confirm one Live Photo containing both the original image and paired video. The source was retained; check the System Library before retrying."
        case .sourceChangedSinceSelection(let identifier):
            return "Photo \(identifier) changed after it was selected for deletion. No photos were deleted."
        case .deletionFailed(let error):
            return "PhotoKit could not delete the source asset: \(error.localizedDescription)"
        case .deletionVerificationFailed(let identifier):
            return "PhotoKit returned from deletion, but source asset \(identifier) is still present."
        }
    }
}

extension PHAsset {
    func pocSummary(originalFilename: String = "", isSelfie: Bool = false) -> PhotoAssetSummary {
        let coordinate = location.map {
            SearchCoordinate(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude
            )
        }
        var categories = Set<MediaCategory>()
        if mediaType == .video { categories.insert(.videos) }
        if isSelfie { categories.insert(.selfies) }
        if mediaSubtypes.contains(.photoLive) { categories.insert(.livePhotos) }
        if mediaSubtypes.contains(.photoDepthEffect) { categories.insert(.portrait) }
        if mediaSubtypes.contains(.photoPanorama) { categories.insert(.panoramas) }
        if mediaSubtypes.contains(.videoTimelapse) { categories.insert(.timeLapse) }
        if mediaSubtypes.contains(.videoHighFrameRate) { categories.insert(.sloMo) }
        if mediaSubtypes.contains(.videoCinematic) { categories.insert(.cinematic) }
        if representsBurst { categories.insert(.bursts) }
        return PhotoAssetSummary(
            id: localIdentifier,
            originalFilename: originalFilename,
            mediaType: mediaType.pocName,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            creationDate: creationDate,
            modificationDate: modificationDate,
            isFavorite: isFavorite,
            isHidden: isHidden,
            representsBurst: representsBurst,
            isLivePhoto: mediaType == .image && mediaSubtypes.contains(.photoLive),
            mediaCategories: categories,
            coordinate: coordinate
        )
    }
}

extension PhotoAssetSummary {
    func replacingOriginalFilename(_ filename: String) -> PhotoAssetSummary {
        PhotoAssetSummary(
            id: id,
            originalFilename: filename,
            mediaType: mediaType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            duration: duration,
            creationDate: creationDate,
            modificationDate: modificationDate,
            isFavorite: isFavorite,
            isHidden: isHidden,
            representsBurst: representsBurst,
            isLivePhoto: isLivePhoto,
            mediaCategories: mediaCategories,
            coordinate: coordinate
        )
    }
}

private extension PHAssetMediaType {
    var pocName: String {
        switch self {
        case .unknown: "unknown"
        case .image: "image"
        case .video: "video"
        case .audio: "audio"
        @unknown default: "future-\(rawValue)"
        }
    }
}

extension PHAssetResourceType {
    nonisolated var pocName: String {
        switch self {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "future-\(rawValue)"
        }
    }
}

extension PHAssetResource {
    nonisolated var pocFilename: String {
        filename ?? "unnamed-resource"
    }
}
