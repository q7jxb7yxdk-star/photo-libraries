// Standalone, read-only feasibility probe for a non-System Photos library.
// It is deliberately outside the app target. Run it only against a library
// you have permission to read. This source contains no export or write request.
//
// Usage after compiling this file manually:
//   DirectLibraryProbe /path/to/Alternate.photoslibrary
//
// The undocumented PhotoKit selectors may disappear or behave differently on
// another macOS release. A temporary database/WAL copy includes recent assets
// without allowing SQLite to create or update files inside the library package.

import AppKit
import Foundation
import ObjectiveC.runtime
import Photos
import SQLite3

private enum ProbeError: LocalizedError {
    case usage
    case missingLibrary
    case missingSelector(String)
    case privateInitializationFailed
    case database(String)
    case fetchFailed(String)
    case noAssets

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: DirectLibraryProbe /path/to/Alternate.photoslibrary"
        case .missingLibrary:
            "The supplied path is not an existing .photoslibrary package."
        case .missingSelector(let name):
            "The current Photos framework does not expose \(name)."
        case .privateInitializationFailed:
            "PhotoKit could not open the selected library with the private initializer."
        case .database(let message):
            "The read-only catalog query failed: \(message)"
        case .fetchFailed(let detail):
            "PhotoKit could not resolve the catalog UUIDs: \(detail)"
        case .noAssets:
            "No readable assets were found in the sampled catalog rows."
        }
    }
}

private typealias ObjCInitializeCall = @convention(c) (
    UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer, Int
) -> UnsafeMutableRawPointer?

private func openPrivateLibrary(at url: URL) throws -> PHPhotoLibrary {
    let libraryClass: AnyClass = PHPhotoLibrary.self

    let enableSelector = NSSelectorFromString("enableMultiLibraryMode")
    guard class_getClassMethod(libraryClass, enableSelector) != nil else {
        throw ProbeError.missingSelector("enableMultiLibraryMode")
    }
    _ = PHPhotoLibrary.perform(enableSelector)
    fputs("Enabled PhotoKit multi-library mode\n", stderr)

    let initializeSelector = NSSelectorFromString("initWithPhotoLibraryURL:type:")
    guard let initializeMethod = class_getInstanceMethod(libraryClass, initializeSelector) else {
        throw ProbeError.missingSelector("initWithPhotoLibraryURL:type:")
    }
    guard let allocated = class_createInstance(libraryClass, 0) as? PHPhotoLibrary else {
        throw ProbeError.privateInitializationFailed
    }
    let allocatedPointer = Unmanaged.passUnretained(allocated).toOpaque()
    let initialize = unsafeBitCast(
        method_getImplementation(initializeMethod), to: ObjCInitializeCall.self
    )
    let nsURL = url as NSURL
    let urlPointer = Unmanaged.passUnretained(nsURL).toOpaque()
    fputs("Calling PhotoKit's private library initializer\n", stderr)
    guard let initialized = initialize(
        allocatedPointer, initializeSelector, urlPointer, 0
    ) else {
        throw ProbeError.privateInitializationFailed
    }
    guard initialized == allocatedPointer else {
        throw ProbeError.privateInitializationFailed
    }
    return allocated
}

private func sampleAssetUUIDs(from libraryURL: URL, limit: Int) throws -> [String] {
    let fileManager = FileManager.default
    let databaseURL = libraryURL.appendingPathComponent("database/Photos.sqlite")
    guard fileManager.fileExists(atPath: databaseURL.path) else {
        throw ProbeError.database("database/Photos.sqlite is unavailable")
    }

    let snapshotDirectory = fileManager.temporaryDirectory.appendingPathComponent(
        "DirectLibraryProbe-\(UUID().uuidString)", isDirectory: true
    )
    do {
        try fileManager.createDirectory(
            at: snapshotDirectory, withIntermediateDirectories: false
        )
    } catch {
        throw ProbeError.database("Could not create a temporary snapshot: \(error)")
    }
    defer { try? fileManager.removeItem(at: snapshotDirectory) }
    let snapshotURL = snapshotDirectory.appendingPathComponent("Photos.sqlite")
    let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
    let snapshotWAL = URL(fileURLWithPath: snapshotURL.path + "-wal")
    do {
        try fileManager.copyItem(at: databaseURL, to: snapshotURL)
        if fileManager.fileExists(atPath: walURL.path) {
            try fileManager.copyItem(at: walURL, to: snapshotWAL)
        }
    } catch {
        throw ProbeError.database("Could not copy the database/WAL snapshot: \(error)")
    }

    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        snapshotURL.path, &database, SQLITE_OPEN_READONLY, nil
    )
    guard openResult == SQLITE_OK, let database else {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite open error \(openResult)"
        if let database { sqlite3_close(database) }
        throw ProbeError.database(message)
    }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
        throw ProbeError.database(String(cString: sqlite3_errmsg(database)))
    }

    var statement: OpaquePointer?
    let sql = "SELECT ZUUID FROM ZASSET WHERE ZUUID IS NOT NULL LIMIT ?"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ProbeError.database(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_int(statement, 1, Int32(limit)) == SQLITE_OK else {
        throw ProbeError.database(String(cString: sqlite3_errmsg(database)))
    }

    var identifiers: [String] = []
    while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return identifiers }
        guard step == SQLITE_ROW else {
            throw ProbeError.database(String(cString: sqlite3_errmsg(database)))
        }
        if let value = sqlite3_column_text(statement, 0) {
            identifiers.append(String(cString: value))
        }
    }
}

private func fetchAssets(
    _ identifiers: [String], from library: PHPhotoLibrary
) throws -> [PHAsset] {
    let selector = NSSelectorFromString("fetchPHObjectsForUUIDs:entityName:")
    guard library.responds(to: selector) else {
        throw ProbeError.missingSelector("fetchPHObjectsForUUIDs:entityName:")
    }
    guard let returned = library.perform(
        selector, with: identifiers as NSArray, with: "Asset" as NSString
    )?.takeUnretainedValue() else {
        throw ProbeError.fetchFailed("the private method returned nil")
    }
    fputs("Private fetch returned \(type(of: returned))\n", stderr)
    if let result = returned as? PHFetchResult<PHAsset> {
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }
    if let objects = returned as? NSArray {
        return objects.compactMap { $0 as? PHAsset }
    }
    throw ProbeError.fetchFailed("unexpected result type \(type(of: returned))")
}

private func checkOneThumbnail(for asset: PHAsset) -> String {
    let options = PHImageRequestOptions()
    options.isSynchronous = true
    options.isNetworkAccessAllowed = false
    options.deliveryMode = .highQualityFormat
    var outcome = "unavailable"
    _ = PHImageManager().requestImage(
        for: asset,
        targetSize: CGSize(width: 320, height: 320),
        contentMode: .aspectFit,
        options: options
    ) { image, info in
        if let image {
            outcome = "available (\(Int(image.size.width)) × \(Int(image.size.height)))"
        } else if let error = info?[PHImageErrorKey] as? Error {
            outcome = "error: \(error.localizedDescription)"
        }
    }
    return outcome
}

do {
    guard CommandLine.arguments.count == 2 else { throw ProbeError.usage }
    let libraryURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard libraryURL.pathExtension.lowercased() == "photoslibrary",
          FileManager.default.fileExists(
            atPath: libraryURL.path, isDirectory: &isDirectory
          ), isDirectory.boolValue else {
        throw ProbeError.missingLibrary
    }

    let started = Date()
    print("PhotoKit authorization status: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
    let library = try openPrivateLibrary(at: libraryURL)
    print("Opened selected library in \(Date().timeIntervalSince(started)) seconds")
    let libraryURLSelector = NSSelectorFromString("photoLibraryURL")
    if library.responds(to: libraryURLSelector),
       let openedURL = library.perform(libraryURLSelector)?.takeUnretainedValue() as? URL {
        print("Private PhotoKit library URL matches selection: \(openedURL.standardizedFileURL == libraryURL)")
    }
    let identifiers = try sampleAssetUUIDs(from: libraryURL, limit: 50)
    print("Sampled \(identifiers.count) catalog UUIDs in \(Date().timeIntervalSince(started)) seconds")
    guard !identifiers.isEmpty else { throw ProbeError.noAssets }
    let assets = try fetchAssets(identifiers, from: library)
    guard let first = assets.first else { throw ProbeError.noAssets }
    let liveCount = assets.filter { $0.mediaSubtypes.contains(.photoLive) }.count
    print("Resolved \(assets.count) assets; \(liveCount) have the Live Photo subtype")
    print("First asset thumbnail: \(checkOneThumbnail(for: first))")
    if let live = assets.first(where: { $0.mediaSubtypes.contains(.photoLive) }) {
        let hasPairedVideo = PHAssetResource.assetResources(for: live).contains {
            $0.type == .pairedVideo || $0.type == .fullSizePairedVideo
        }
        print("First Live Photo exposes a paired video resource: \(hasPairedVideo)")
    }
    print("Finished in \(Date().timeIntervalSince(started)) seconds")
} catch {
    fputs("ERROR \(error.localizedDescription)\n", stderr)
    exit(1)
}
