import Foundation

/// Tracks visible scroll targets without publishing changes back into SwiftUI.
/// The browser reads the centered target only after scrolling becomes idle, so
/// crossing individual photo cells does not invalidate the parent view.
@MainActor
final class LibraryBrowserScrollTracker {
    private(set) var visibleIDs: [String] = []

    var centeredID: String? {
        guard !visibleIDs.isEmpty else { return nil }
        return visibleIDs[visibleIDs.count / 2]
    }

    func updateVisibleIDs(_ identifiers: [String]) {
        visibleIDs = identifiers
    }

    func reset() {
        visibleIDs = []
    }
}

/// Persists a stable asset identifier rather than a pixel offset, so a saved
/// position survives window resizing and grid/list layout changes.
@MainActor
enum LibraryBrowserPositionStore {
    private static let keyPrefix = "library-browser.last-visible-asset."
    private static let timelineKeyPrefix = "library-browser.timeline."
    private static let allLibrariesKey = keyPrefix + "all-libraries"
    private static let allLibrariesBottomKey = keyPrefix + "all-libraries.at-bottom"
    private static let videosKey = keyPrefix + "videos"
    private static let videosBottomKey = keyPrefix + "videos.at-bottom"

    static func assetID(for libraryID: LibraryID) -> String? {
        UserDefaults.standard.string(forKey: key(for: libraryID))
    }

    static func save(assetID: String, for libraryID: LibraryID) {
        UserDefaults.standard.set(assetID, forKey: key(for: libraryID))
    }

    static func systemIsAtBottom(for libraryID: LibraryID) -> Bool {
        UserDefaults.standard.bool(forKey: bottomKey(for: libraryID))
    }

    static func saveSystem(assetID: String, isAtBottom: Bool, for libraryID: LibraryID) {
        save(assetID: assetID, for: libraryID)
        UserDefaults.standard.set(isAtBottom, forKey: bottomKey(for: libraryID))
    }

    static func remove(for libraryID: LibraryID) {
        UserDefaults.standard.removeObject(forKey: key(for: libraryID))
        UserDefaults.standard.removeObject(forKey: bottomKey(for: libraryID))
    }

    static var allLibrariesAssetID: String? {
        UserDefaults.standard.string(forKey: allLibrariesKey)
    }

    static var allLibrariesIsAtBottom: Bool {
        UserDefaults.standard.bool(forKey: allLibrariesBottomKey)
    }

    static func saveAllLibraries(assetID: String, isAtBottom: Bool) {
        UserDefaults.standard.set(assetID, forKey: allLibrariesKey)
        UserDefaults.standard.set(isAtBottom, forKey: allLibrariesBottomKey)
    }

    static var videosAssetID: String? {
        UserDefaults.standard.string(forKey: videosKey)
    }

    static var videosIsAtBottom: Bool {
        UserDefaults.standard.bool(forKey: videosBottomKey)
    }

    static func saveVideos(assetID: String, isAtBottom: Bool) {
        UserDefaults.standard.set(assetID, forKey: videosKey)
        UserDefaults.standard.set(isAtBottom, forKey: videosBottomKey)
    }

    static func timelineMode(for identifier: String) -> String? {
        UserDefaults.standard.string(forKey: timelineKeyPrefix + identifier)
    }

    static func saveTimelineMode(_ mode: String, for identifier: String) {
        UserDefaults.standard.set(mode, forKey: timelineKeyPrefix + identifier)
    }

    static func albumAssetID(for libraryID: LibraryID, albumID: String) -> String? {
        UserDefaults.standard.string(forKey: albumKey(for: libraryID, albumID: albumID))
    }

    static func saveAlbum(assetID: String, for libraryID: LibraryID, albumID: String) {
        UserDefaults.standard.set(assetID, forKey: albumKey(for: libraryID, albumID: albumID))
    }

    static func removeAlbum(for libraryID: LibraryID, albumID: String) {
        UserDefaults.standard.removeObject(forKey: albumKey(for: libraryID, albumID: albumID))
    }

    private static func key(for libraryID: LibraryID) -> String {
        keyPrefix + libraryID.rawValue.uuidString
    }

    private static func bottomKey(for libraryID: LibraryID) -> String {
        key(for: libraryID) + ".at-bottom"
    }

    private static func albumKey(for libraryID: LibraryID, albumID: String) -> String {
        keyPrefix + libraryID.rawValue.uuidString + ".album." + albumID
    }
}
