import Foundation

// Codable wire shapes shared with the app's transfer models. The helper does
// not link the app target or its System Photo Library provider.
nonisolated struct PhotoTransferLocation: Codable, Sendable, Hashable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
}

nonisolated struct PhotoTransferAlbum: Codable, Sendable, Hashable {
    let sourceID: String
    let name: String
    let folderNames: [String]
}

// Wire models mirror the App's catalog values. This tool deliberately does not
// link the App or create its System Photo Library model.
nonisolated struct PhotosAutomationMediaItem: Codable, Sendable {
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

nonisolated struct PhotosAutomationAlbum: Codable, Sendable {
    let id: String
    let name: String
    let parentName: String?
    let folderNames: [String]?
    let mediaItemCount: Int
    let mediaItemIDs: [String]?

    init(id: String, name: String, parentName: String?,
         mediaItemCount: Int, mediaItemIDs: [String]?, folderNames: [String]? = nil) {
        self.id = id
        self.name = name
        self.parentName = parentName
        self.folderNames = folderNames
        self.mediaItemCount = mediaItemCount
        self.mediaItemIDs = mediaItemIDs
    }
}
