import Foundation

nonisolated enum UnifiedSearchSource: String, Codable, Sendable {
    case systemPhotoLibrary
    case registeredLibrary
}

nonisolated struct SearchCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    var cacheKey: String {
        String(format: "%.4f,%.4f", latitude, longitude)
    }
}

nonisolated struct SearchPlace: Codable, Hashable, Sendable {
    let name: String
    let city: String
    let country: String
    let formattedAddress: String

    var searchableText: String {
        [name, city, country, formattedAddress]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

nonisolated struct UnifiedSearchDocument: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let libraryID: LibraryID
    let assetID: String
    let libraryName: String
    let source: UnifiedSearchSource
    let filename: String
    let displayName: String
    let caption: String
    let keywords: [String]
    let rawLocation: String
    var place: SearchPlace?
    let captureDate: Date?
    let dateDescription: String
    let isFavorite: Bool
    let pixelWidth: Int
    let pixelHeight: Int
    let mediaType: String
    let coordinate: SearchCoordinate?

    static func identifier(libraryID: LibraryID, assetID: String) -> String {
        "\(libraryID.rawValue.uuidString):\(assetID)"
    }

    var normalizedSearchText: String {
        SearchTextNormalizer.normalize(
            [
                filename,
                displayName,
                caption,
                keywords.joined(separator: " "),
                rawLocation,
                place?.searchableText ?? "",
                dateDescription,
                libraryName,
                mediaType,
                "\(pixelWidth)x\(pixelHeight)"
            ].joined(separator: " ")
        )
    }
}

nonisolated enum SearchTextNormalizer {
    static func normalize(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

nonisolated enum LibrarySearchMutation: Sendable {
    case replaceLibrary(LibraryPreviewManifest)
    case upsertItem(
        libraryID: LibraryID,
        libraryName: String,
        item: PhotosAutomationMediaItem
    )
    case removeLibrary(LibraryID)
}
