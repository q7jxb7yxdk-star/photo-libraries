import Foundation

enum MediaCategory: String, CaseIterable, Hashable, Sendable {
    case videos
    case selfies
    case livePhotos
    case portrait
    case panoramas
    case timeLapse
    case sloMo
    case cinematic
    case bursts

    var title: String {
        switch self {
        case .videos: "Videos"
        case .selfies: "Selfies"
        case .livePhotos: "Live Photos"
        case .portrait: "Portrait"
        case .panoramas: "Panoramas"
        case .timeLapse: "Time-lapse"
        case .sloMo: "Slo-mo"
        case .cinematic: "Cinematic"
        case .bursts: "Bursts"
        }
    }

    var symbol: String {
        switch self {
        case .videos: "video"
        case .selfies: "person.crop.square"
        case .livePhotos: "livephoto"
        case .portrait: "f.cursive.circle"
        case .panoramas: "pano"
        case .timeLapse: "timelapse"
        case .sloMo: "slowmo"
        case .cinematic: "video.square"
        case .bursts: "square.stack.3d.up"
        }
    }

    var includesRegisteredLibraries: Bool {
        self == .videos || self == .livePhotos
    }
}

/// An app-owned identity for a Photos library. `PHAsset.localIdentifier` values
/// are intentionally never used outside the library that issued them.
nonisolated struct LibraryID: RawRepresentable, Hashable, Codable, Identifiable, Sendable {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    var id: UUID { rawValue }
}

enum LibraryKind: String, Codable, Sendable {
    /// A user-selected `.photoslibrary` package. Direct browsing reads a
    /// temporary catalog snapshot and leaves the original package unchanged.
    case userSelectedPhotosLibrary

    /// A user-selected reference to the current System Photo Library. Its
    /// catalog is accessed through PhotoKit rather than Photos Automation.
    case systemPhotoLibrary

    var isSystemPhotoLibrary: Bool {
        self == .systemPhotoLibrary
    }
}

enum LibraryAvailability: Equatable, Sendable {
    case online
    case offline
    case needsReauthorization
    case invalidSelection

    var displayName: String {
        switch self {
        case .online: "Available"
        case .offline: "Offline"
        case .needsReauthorization: "Needs reauthorization"
        case .invalidSelection: "Not a Photos library"
        }
    }
}

struct LibraryPackageMetadata: Codable, Equatable, Sendable {
    let displayName: String
    let lastKnownPath: String
    let volumeName: String?
    let creationDate: Date?
    let modificationDate: Date?

    /// This snapshot is presentation metadata only. It is not used to authorize access
    /// or to infer consistency of the package's internal Photos database.
    init(
        displayName: String,
        lastKnownPath: String,
        volumeName: String?,
        creationDate: Date?,
        modificationDate: Date?
    ) {
        self.displayName = Self.withoutPackageExtension(displayName)
        self.lastKnownPath = lastKnownPath
        self.volumeName = volumeName
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    static func withoutPackageExtension(_ name: String) -> String {
        let suffix = ".photoslibrary"
        guard name.count > suffix.count,
              name.lowercased().hasSuffix(suffix) else { return name }
        return String(name.dropLast(suffix.count))
    }
}

struct LibraryDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: LibraryID
    let kind: LibraryKind
    let bookmarkData: Data
    /// Separately granted by selecting this exact package for transfer writes.
    let writeBookmarkData: Data?
    let addedAt: Date
    var metadata: LibraryPackageMetadata

    init(
        id: LibraryID = LibraryID(),
        kind: LibraryKind = .userSelectedPhotosLibrary,
        bookmarkData: Data,
        writeBookmarkData: Data? = nil,
        addedAt: Date = .now,
        metadata: LibraryPackageMetadata
    ) {
        self.id = id
        self.kind = kind
        self.bookmarkData = bookmarkData
        self.writeBookmarkData = writeBookmarkData
        self.addedAt = addedAt
        self.metadata = metadata
    }
}

struct RegisteredLibrary: Identifiable, Equatable, Sendable {
    let descriptor: LibraryDescriptor
    let availability: LibraryAvailability

    var id: LibraryID { descriptor.id }
}
