import AppKit
import Carbon
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The NSWorkspace callback can arrive on a concurrent queue. Keep its result
/// separate from the caller's executor so a slow Photos launch cannot stall UI.
nonisolated private final class PhotosOpenCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Void, Error>?

    func finish(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeoutSeconds: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if semaphore.wait(timeout: .now() + .milliseconds(100)) == .success {
                lock.lock()
                let value = result
                lock.unlock()
                guard let value else {
                    throw PhotosAutomationError.photosNotAvailable(
                        "Photos returned no result for the open request."
                    )
                }
                try value.get()
                try Task.checkCancellation()
                return
            }
        }
        throw PhotosAutomationError.timedOut("Photos did not respond to the open request within \(Int(timeoutSeconds)) seconds.")
    }
}

/// A supervised client for Photos' public AppleScript API.
///
/// Nothing runs during initialization. Every method sends an Apple event only
/// when its caller explicitly invokes it. The client never activates Photos,
/// uses UI scripting, changes the System Photo Library setting, deletes content,
/// or edits a Photos library package directly. Import and capture-date updates
/// are exposed only as explicit operations with verification.
nonisolated final class PhotosAutomationClient {
    static let maximumEnumerationLimit = 200
    static let maximumMediaCatalogPageSize = 500
    static let maximumBatchExportCount = 100

    @MainActor var isPhotosRunning: Bool {
        photosProcessIdentifier != nil
    }

    @MainActor var photosProcessIdentifier: pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == Self.photosBundleIdentifier
        }?.processIdentifier
    }

    /// Asks macOS to open a user-selected library package in its registered
    /// application, matching the Finder's normal document-opening behavior.
    ///
    /// The public Photos scripting interface does not expose the URL of its
    /// current library or a load-completion callback. Opening a package while
    /// Photos is already running may leave its current library unchanged;
    /// callers must verify the catalog before reading or writing it.
    func openPhotoLibrary(at libraryURL: URL) async throws -> PhotosAutomationOpenResult {
        try validatePhotoLibraryURL(libraryURL)
        try Task.checkCancellation()
        let wasRunning = await MainActor.run { isPhotosRunning }
        guard let photosURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.photosBundleIdentifier
        ) else {
            throw PhotosAutomationError.photosNotAvailable(
                "macOS could not locate Photos to open \(libraryURL.lastPathComponent)."
            )
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let completion = PhotosOpenCompletion()
        NSWorkspace.shared.open(
            [libraryURL],
            withApplicationAt: photosURL,
            configuration: configuration
        ) { application, error in
            if let error {
                completion.finish(.failure(error))
            } else if application == nil {
                completion.finish(.failure(PhotosAutomationError.photosNotAvailable(
                    "Photos did not open \(libraryURL.lastPathComponent)."
                )))
            } else {
                completion.finish(.success(()))
            }
        }
        try completion.wait(timeoutSeconds: 90)
        return PhotosAutomationOpenResult(
            requestedLibraryURL: libraryURL,
            photosWasAlreadyRunning: wasRunning,
            currentLibraryIdentityWasVerified: false
        )
    }

    /// Reads counts plus a bounded sample from Photos' currently open library.
    func snapshot(offset: Int = 0, limit: Int = 50) throws -> PhotosAutomationLibrarySnapshot {
        try validate(limit: limit)
        guard offset >= 0 else { throw PhotosAutomationError.invalidOffset(offset) }
        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            try
                return theValue as text
            on error
                return ""
            end try
        end textOrEmpty

        on parentNameOrEmpty(theContainer)
            try
                set parentValue to parent of theContainer
                if parentValue is missing value then return ""
                return my textOrEmpty(name of parentValue)
            on error
                return ""
            end try
        end parentNameOrEmpty

        on mediaRow(theItem)
            tell application id "\(Self.photosBundleIdentifier)"
                set locationText to ""
                try
                    set locationValue to location of theItem
                    if locationValue is not missing value then
                        set locationText to (my textOrEmpty(item 1 of locationValue)) & "," & (my textOrEmpty(item 2 of locationValue))
                    end if
                end try
                set keywordValues to {}
                try
                    repeat with keywordValue in keywords of theItem
                        set end of keywordValues to my textOrEmpty(keywordValue)
                    end repeat
                end try
                set fileSizeText to ""
                try
                    set fileSizeText to my textOrEmpty(size of theItem)
                end try
                return {my textOrEmpty(id of theItem), my textOrEmpty(filename of theItem), my textOrEmpty(name of theItem), my textOrEmpty(description of theItem), my textOrEmpty(date of theItem), favorite of theItem, width of theItem, height of theItem, fileSizeText, locationText, keywordValues}
            end tell
        end mediaRow

        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set totalAlbums to count of albums
                set totalFolders to count of folders
                set totalMediaItems to count of media items

                set albumRows to {}
                set albumLimit to \(limit)
                if totalAlbums < albumLimit then set albumLimit to totalAlbums
                repeat with itemIndex from 1 to albumLimit
                    set albumValue to album itemIndex
                    set end of albumRows to {my textOrEmpty(id of albumValue), my textOrEmpty(name of albumValue), my parentNameOrEmpty(albumValue), count of media items of albumValue}
                end repeat

                set folderRows to {}
                set folderLimit to \(limit)
                if totalFolders < folderLimit then set folderLimit to totalFolders
                repeat with itemIndex from 1 to folderLimit
                    set folderValue to folder itemIndex
                    set end of folderRows to {my textOrEmpty(id of folderValue), my textOrEmpty(name of folderValue), my parentNameOrEmpty(folderValue), count of albums of folderValue, count of folders of folderValue}
                end repeat

                set mediaRows to {}
                set mediaStart to \(offset + 1)
                set mediaEnd to \(offset + limit)
                if totalMediaItems < mediaEnd then set mediaEnd to totalMediaItems
                if mediaStart is less than or equal to mediaEnd then
                    repeat with itemIndex from mediaStart to mediaEnd
                        set end of mediaRows to my mediaRow(media item itemIndex)
                    end repeat
                end if

                return {totalAlbums, totalFolders, totalMediaItems, albumRows, folderRows, mediaRows}
            end tell
        end timeout
        """

        return try parseSnapshot(try execute(source))
    }

    /// Reads only the paged media catalog needed by preview indexing. Album
    /// and folder hierarchies intentionally remain in `snapshot`, so they are
    /// not redundantly enumerated for every media page.
    func mediaCatalogPage(
        offset: Int = 0,
        limit: Int = PhotosAutomationClient.maximumMediaCatalogPageSize,
        timeoutSeconds: Int = 300
    ) throws -> PhotosAutomationMediaCatalogPage {
        guard (1...Self.maximumMediaCatalogPageSize).contains(limit) else {
            throw PhotosAutomationError.invalidMediaCatalogLimit(limit)
        }
        guard offset >= 0 else { throw PhotosAutomationError.invalidOffset(offset) }
        let effectiveTimeout = min(max(timeoutSeconds, 1), 300)
        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            try
                return theValue as text
            on error
                return ""
            end try
        end textOrEmpty

        on mediaRow(theItem)
            tell application id "\(Self.photosBundleIdentifier)"
                set locationText to ""
                try
                    set locationValue to location of theItem
                    if locationValue is not missing value then
                        set locationText to (my textOrEmpty(item 1 of locationValue)) & "," & (my textOrEmpty(item 2 of locationValue))
                    end if
                end try
                set keywordValues to {}
                try
                    repeat with keywordValue in keywords of theItem
                        set end of keywordValues to my textOrEmpty(keywordValue)
                    end repeat
                end try
                set fileSizeText to ""
                try
                    set fileSizeText to my textOrEmpty(size of theItem)
                end try
                return {my textOrEmpty(id of theItem), my textOrEmpty(filename of theItem), my textOrEmpty(name of theItem), my textOrEmpty(description of theItem), my textOrEmpty(date of theItem), favorite of theItem, width of theItem, height of theItem, fileSizeText, locationText, keywordValues}
            end tell
        end mediaRow

        with timeout of \(effectiveTimeout) seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set totalMediaItems to count of media items
                set mediaRows to {}
                set mediaStart to \(offset + 1)
                set mediaEnd to \(offset + limit)
                if totalMediaItems < mediaEnd then set mediaEnd to totalMediaItems
                if mediaStart is less than or equal to mediaEnd then
                    repeat with itemIndex from mediaStart to mediaEnd
                        set end of mediaRows to my mediaRow(media item itemIndex)
                    end repeat
                end if
                return {totalMediaItems, mediaRows}
            end tell
        end timeout
        """

        return try parseMediaCatalogPage(try execute(source))
    }

    /// Reads one page of album metadata. This intentionally keeps the same
    /// bounded page size as the media catalog so callers can enumerate every
    /// album without relying on `snapshot`'s small display sample.
    func albumCatalogPage(
        offset: Int = 0,
        limit: Int = PhotosAutomationClient.maximumMediaCatalogPageSize,
        timeoutSeconds: Int = 300
    ) throws -> PhotosAutomationAlbumCatalogPage {
        guard (1...Self.maximumMediaCatalogPageSize).contains(limit) else {
            throw PhotosAutomationError.invalidMediaCatalogLimit(limit)
        }
        guard offset >= 0 else { throw PhotosAutomationError.invalidOffset(offset) }
        let effectiveTimeout = min(max(timeoutSeconds, 1), 300)
        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            try
                return theValue as text
            on error
                return ""
            end try
        end textOrEmpty

        on parentNameOrEmpty(theContainer)
            try
                set parentValue to parent of theContainer
                if parentValue is missing value then return ""
                return my textOrEmpty(name of parentValue)
            on error
                return ""
            end try
        end parentNameOrEmpty

        with timeout of \(effectiveTimeout) seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set totalAlbums to count of albums
                set albumRows to {}
                set albumStart to \(offset + 1)
                set albumEnd to \(offset + limit)
                if totalAlbums < albumEnd then set albumEnd to totalAlbums
                if albumStart is less than or equal to albumEnd then
                    repeat with itemIndex from albumStart to albumEnd
                        set albumValue to album itemIndex
                        set end of albumRows to {my textOrEmpty(id of albumValue), my textOrEmpty(name of albumValue), my parentNameOrEmpty(albumValue), count of media items of albumValue}
                    end repeat
                end if
                return {totalAlbums, albumRows}
            end tell
        end timeout
        """

        return try parseAlbumCatalogPage(try execute(source))
    }

    /// Reads one bounded page of media-item identifiers for a specific album.
    /// Album lookup uses Photos' stable scripting identifier rather than its
    /// non-unique, user-editable name.
    func albumMembershipPage(
        albumID: String,
        offset: Int = 0,
        limit: Int = PhotosAutomationClient.maximumMediaCatalogPageSize,
        timeoutSeconds: Int = 300
    ) throws -> PhotosAutomationAlbumMembershipPage {
        let trimmedAlbumID = albumID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAlbumID.isEmpty else {
            throw PhotosAutomationError.invalidAlbumIdentifier
        }
        guard (1...Self.maximumMediaCatalogPageSize).contains(limit) else {
            throw PhotosAutomationError.invalidMediaCatalogLimit(limit)
        }
        guard offset >= 0 else { throw PhotosAutomationError.invalidOffset(offset) }

        let effectiveTimeout = min(max(timeoutSeconds, 1), 300)
        let albumLiteral = Self.appleScriptStringLiteral(trimmedAlbumID)
        let source = """
        with timeout of \(effectiveTimeout) seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set requestedAlbumID to \(albumLiteral)
                set matchingAlbums to every album whose id is requestedAlbumID
                if (count of matchingAlbums) is not 1 then return {false, 0, {}}

                set albumValue to item 1 of matchingAlbums
                -- Photos can fail to resolve `id of item N` from a materialized
                -- list of media-item object specifiers. Read the identifier
                -- property as one aggregate list, then page that plain value list.
                set allIdentifierValues to id of every media item of albumValue
                set totalMediaItems to count of allIdentifierValues
                set identifierValues to {}
                set itemStart to \(offset + 1)
                set itemEnd to \(offset + limit)
                if totalMediaItems < itemEnd then set itemEnd to totalMediaItems
                if itemStart is less than or equal to itemEnd then
                    repeat with itemIndex from itemStart to itemEnd
                        set end of identifierValues to item itemIndex of allIdentifierValues as text
                    end repeat
                end if
                return {true, totalMediaItems, identifierValues}
            end tell
        end timeout
        """

        return try parseAlbumMembershipPage(
            try execute(source),
            albumID: trimmedAlbumID
        )
    }

    /// Reads the identifiers in one Photos request, then counts and samples
    /// locally. Photos can reject its `count` Apple event for sandboxed apps.
    func catalogFingerprint(
        limit: Int,
        timeoutSeconds: Int = 15
    ) throws -> PhotosAutomationCatalogFingerprint {
        guard (1...Self.maximumMediaCatalogPageSize).contains(limit) else {
            throw PhotosAutomationError.invalidMediaCatalogLimit(limit)
        }
        let effectiveTimeout = min(max(timeoutSeconds, 1), 300)
        let source = """
        with timeout of \(effectiveTimeout) seconds
            tell application id "\(Self.photosBundleIdentifier)"
                return id of every media item
            end tell
        end timeout
        """

        let identifiers = try descriptorList(
            try execute(source),
            context: "catalog fingerprint IDs"
        ).map { try descriptorString($0, context: "catalog fingerprint ID") }
        guard Set(identifiers).count == identifiers.count else {
            throw PhotosAutomationError.malformedResponse("Catalog fingerprint IDs were not unique.")
        }
        return PhotosAutomationCatalogFingerprint(
            totalMediaItemCount: identifiers.count,
            mediaItemIdentifiers: Array(identifiers.prefix(limit))
        )
    }

    /// Requests each inexpensive media-item property as one AppleScript list.
    /// This avoids thousands of per-object Apple event round trips. Some
    /// Photos/macOS combinations may reject aggregate property access, so the
    /// caller must retain the paged `mediaCatalogPage` fallback.
    func basicMediaCatalog() throws -> PhotosAutomationBasicCatalog {
        let source = """
        with timeout of 300 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set totalMediaItems to count of media items
                set identifierValues to id of every media item
                set filenameValues to filename of every media item
                set nameValues to name of every media item
                set dateValues to date of every media item
                set favoriteValues to favorite of every media item
                set widthValues to width of every media item
                set heightValues to height of every media item
                return {totalMediaItems, identifierValues, filenameValues, nameValues, dateValues, favoriteValues, widthValues, heightValues}
            end tell
        end timeout
        """

        return try parseBasicMediaCatalog(try execute(source))
    }

    /// Reads the slower searchable metadata as aggregate property lists. This
    /// avoids one AppleScript handler invocation per media item. Callers must
    /// retain a paged fallback because nested keyword/location lists can be
    /// too large for one Apple event in very large libraries.
    func bulkMetadataCatalog() throws -> PhotosAutomationMediaCatalogPage {
        let source = """
        with timeout of 300 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set totalMediaItems to count of media items
                set identifierValues to id of every media item
                set descriptionValues to description of every media item
                set sizeValues to size of every media item
                set locationValues to location of every media item
                set keywordValues to keywords of every media item
                return {totalMediaItems, identifierValues, descriptionValues, sizeValues, locationValues, keywordValues}
            end tell
        end timeout
        """

        return try parseBulkMetadataCatalog(try execute(source))
    }

    /// Reads metadata only for identifiers known to need enrichment. Direct
    /// ID access is attempted first and the compatible predicate lookup is
    /// retained as a fallback for Photos versions that do not resolve it.
    func metadataForIdentifiers(
        _ identifiers: [String],
        timeoutSeconds: Int = 300
    ) throws -> PhotosAutomationMediaCatalogPage {
        guard !identifiers.isEmpty,
              identifiers.count <= Self.maximumEnumerationLimit,
              identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PhotosAutomationError.invalidLimit(identifiers.count)
        }
        let effectiveTimeout = min(max(timeoutSeconds, 1), 300)
        let operationBlocks = identifiers.map { identifier in
            let identifierLiteral = Self.appleScriptStringLiteral(identifier)
            return """
                    set targetItem to missing value
                    try
                        set targetItem to media item id \(identifierLiteral)
                        if (id of targetItem as text) is not \(identifierLiteral) then set targetItem to missing value
                    end try
                    if targetItem is missing value then
                        set matchingItems to every media item whose id is \(identifierLiteral)
                        if (count of matchingItems) is greater than 0 then set targetItem to item 1 of matchingItems
                    end if
                    if targetItem is not missing value then set end of metadataRows to my metadataRow(targetItem)
            """
        }.joined(separator: "\n")
        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            try
                return theValue as text
            on error
                return ""
            end try
        end textOrEmpty

        on metadataRow(theItem)
            tell application id "\(Self.photosBundleIdentifier)"
                set locationText to ""
                try
                    set locationValue to location of theItem
                    if locationValue is not missing value then
                        set locationText to (my textOrEmpty(item 1 of locationValue)) & "," & (my textOrEmpty(item 2 of locationValue))
                    end if
                end try
                set itemKeywords to {}
                try
                    repeat with keywordValue in keywords of theItem
                        set end of itemKeywords to my textOrEmpty(keywordValue)
                    end repeat
                end try
                set fileSizeText to ""
                try
                    set fileSizeText to my textOrEmpty(size of theItem)
                end try
                return {my textOrEmpty(id of theItem), my textOrEmpty(description of theItem), fileSizeText, locationText, itemKeywords}
            end tell
        end metadataRow

        set metadataRows to {}
        with timeout of \(effectiveTimeout) seconds
            tell application id "\(Self.photosBundleIdentifier)"
        \(operationBlocks)
            end tell
        end timeout
        return metadataRows
        """

        return PhotosAutomationMediaCatalogPage(
            totalMediaItemCount: identifiers.count,
            mediaItems: try descriptorList(
                try execute(source),
                context: "targeted metadata rows"
            ).map(parseMetadataRow)
        )
    }

    /// Uses Photos' own search command against its currently open library.
    func search(_ query: String, limit: Int = 50) throws -> PhotosAutomationSearchResult {
        try validate(limit: limit)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { throw PhotosAutomationError.emptySearchQuery }

        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            try
                return theValue as text
            on error
                return ""
            end try
        end textOrEmpty

        on mediaRow(theItem)
            tell application id "\(Self.photosBundleIdentifier)"
                set locationText to ""
                try
                    set locationValue to location of theItem
                    if locationValue is not missing value then
                        set locationText to (my textOrEmpty(item 1 of locationValue)) & "," & (my textOrEmpty(item 2 of locationValue))
                    end if
                end try
                set keywordValues to {}
                try
                    repeat with keywordValue in keywords of theItem
                        set end of keywordValues to my textOrEmpty(keywordValue)
                    end repeat
                end try
                set fileSizeText to ""
                try
                    set fileSizeText to my textOrEmpty(size of theItem)
                end try
                return {my textOrEmpty(id of theItem), my textOrEmpty(filename of theItem), my textOrEmpty(name of theItem), my textOrEmpty(description of theItem), my textOrEmpty(date of theItem), favorite of theItem, width of theItem, height of theItem, fileSizeText, locationText, keywordValues}
            end tell
        end mediaRow

        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set foundItems to search for \(Self.appleScriptStringLiteral(trimmedQuery))
                set totalFound to count of foundItems
                set foundLimit to \(limit)
                if totalFound < foundLimit then set foundLimit to totalFound
                set mediaRows to {}
                repeat with itemIndex from 1 to foundLimit
                    set end of mediaRows to my mediaRow(item itemIndex of foundItems)
                end repeat
                return {totalFound, mediaRows}
            end tell
        end timeout
        """

        return try parseSearchResult(try execute(source))
    }

    /// Exports one item identified by Photos' library-local media-item ID.
    ///
    /// A unique directory is created below the caller-supplied app-owned
    /// staging directory. The source library is never changed or deleted.
    func exportMediaItem(
        identifier: String,
        version: PhotosAutomationExportVersion,
        to stagingDirectory: URL,
        expectedMinimumFileCount: Int = 1
    ) throws -> PhotosAutomationExportResult {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else {
            throw PhotosAutomationError.invalidMediaItemIdentifier
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: stagingDirectory.path) else {
            throw PhotosAutomationError.stagingDirectoryUnavailable(
                stagingDirectory,
                "The location must already exist and be writable by the app."
            )
        }

        let exportDirectory = stagingDirectory.appendingPathComponent(
            "photos-automation-export-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw PhotosAutomationError.stagingDirectoryUnavailable(
                stagingDirectory,
                error.localizedDescription
            )
        }

        let useOriginals: String
        switch version {
        case .original:
            useOriginals = "true"
        case .rendered:
            useOriginals = "false"
        }
        let source = """
        with timeout of 300 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set targetItem to missing value
                try
                    set targetItem to media item id \(Self.appleScriptStringLiteral(trimmedIdentifier))
                    if (id of targetItem as text) is not \(Self.appleScriptStringLiteral(trimmedIdentifier)) then set targetItem to missing value
                end try
                if targetItem is missing value then
                    set matchingItems to every media item whose id is \(Self.appleScriptStringLiteral(trimmedIdentifier))
                    if (count of matchingItems) is 0 then return {false, "", ""}
                    set targetItem to item 1 of matchingItems
                end if
                set reportedFilename to filename of targetItem as text
                export {targetItem} to POSIX file \(Self.appleScriptStringLiteral(exportDirectory.path)) using originals \(useOriginals)
                return {true, id of targetItem as text, reportedFilename}
            end tell
        end timeout
        """

        let response: NSAppleEventDescriptor
        do {
            response = try execute(source)
        } catch {
            try? fileManager.removeItem(at: exportDirectory)
            throw error
        }

        let list = try descriptorList(response, context: "export result")
        guard list.count == 3 else {
            throw PhotosAutomationError.malformedResponse("Export returned \(list.count) fields instead of 3.")
        }
        guard descriptorBool(list[0]) else {
            try? fileManager.removeItem(at: exportDirectory)
            throw PhotosAutomationError.mediaItemNotFound(trimmedIdentifier)
        }
        let returnedIdentifier = try descriptorString(list[1], context: "export media ID")
        let reportedFilename = try descriptorString(list[2], context: "export filename")

        let observedFiles: [URL]
        do {
            if expectedMinimumFileCount > 1 {
                observedFiles = try waitForStableBatchExportFiles(
                    in: exportDirectory,
                    expectedMinimumCount: expectedMinimumFileCount
                )
            } else {
                observedFiles = try waitForStableExportFiles(
                    in: [0: exportDirectory],
                    successfulIndices: [0]
                )[0] ?? []
            }
        } catch {
            throw PhotosAutomationError.stagingDirectoryUnavailable(
                exportDirectory,
                "Export returned, but the app could not inspect its output: \(error.localizedDescription)"
            )
        }

        return PhotosAutomationExportResult(
            mediaItemID: returnedIdentifier,
            reportedFilename: reportedFilename,
            version: version,
            destinationDirectory: exportDirectory,
            observedFiles: observedFiles
        )
    }

    /// Captures the destination IDs before an import so new IDs can be proven
    /// without asking Photos to handle a `count` Apple event.
    func catalogIdentifiers() throws -> Set<String> {
        let source = """
        with timeout of 300 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                return id of every media item
            end tell
        end timeout
        """
        let identifiers = try descriptorList(
            try execute(source),
            context: "destination media IDs"
        ).map { try descriptorString($0, context: "destination media ID") }
        let uniqueIdentifiers = Set(identifiers)
        guard uniqueIdentifiers.count == identifiers.count else {
            throw PhotosAutomationError.malformedResponse("Destination media IDs were not unique.")
        }
        return uniqueIdentifiers
    }

    /// Check specific IDs in the library currently open in Photos.
    func existingMediaItemIdentifiers(_ identifiers: [String]) throws -> Set<String> {
        guard !identifiers.isEmpty,
              identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PhotosAutomationError.invalidMediaItemIdentifier
        }
        let requestedIDs = Array(Set(identifiers)).map(Self.appleScriptStringLiteral).joined(separator: ", ")
        let source = """
        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set matchingIDs to {}
                repeat with requestedID in {\(requestedIDs)}
                    set requestedText to requestedID as text
                    try
                        set targetItem to media item id requestedText
                        if (id of targetItem as text) is requestedText then set end of matchingIDs to requestedText
                    end try
                end repeat
                return matchingIDs
            end tell
        end timeout
        """
        let matches = try descriptorList(
            try execute(source),
            context: "current Photos library media IDs"
        ).map { try descriptorString($0, context: "current Photos library media ID") }
        return Set(matches)
    }

    /// Imports app-staged files into the currently open Photos library. The
    /// public scripting API does not expose that library's URL, so callers must
    /// verify its catalog identity immediately before invoking this method.
    /// Duplicate checking is deliberately skipped so a verified transfer always
    /// has a newly-created destination item. This can create a duplicate when
    /// equivalent content already exists, but it prevents an existing item from
    /// being mistaken for the copy that authorizes source deletion.
    func importFiles(_ fileURLs: [URL]) throws -> PhotosAutomationImportResult {
        guard !fileURLs.isEmpty, fileURLs.count <= Self.maximumBatchExportCount else {
            throw PhotosAutomationError.invalidImportCount(fileURLs.count)
        }
        for fileURL in fileURLs {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            } catch {
                throw PhotosAutomationError.importFileUnavailable(fileURL)
            }
            guard values.isRegularFile == true else {
                throw PhotosAutomationError.importFileUnavailable(fileURL)
            }
        }

        let fileList = fileURLs
            .map { "POSIX file \(Self.appleScriptStringLiteral($0.path))" }
            .joined(separator: ", ")
        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            try
                return theValue as text
            on error
                return ""
            end try
        end textOrEmpty

        with timeout of 300 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set importedItems to import {\(fileList)} skip check duplicates true
                set importedRows to {}
                set importedIDs to {}
                repeat with importedItem in importedItems
                    set importedID to id of importedItem as text
                    set end of importedIDs to importedID
                    set end of importedRows to {importedID, my textOrEmpty(filename of importedItem)}
                end repeat

                set verifiedIDs to {}
                repeat with importedID in importedIDs
                    set matchingItems to get (every media item whose id is (importedID as text))
                    if (count of matchingItems) is 1 then set end of verifiedIDs to (importedID as text)
                end repeat
                return {importedRows, verifiedIDs}
            end tell
        end timeout
        """

        let response = try descriptorList(try execute(source), context: "import result")
        guard response.count == 2 else {
            throw PhotosAutomationError.malformedResponse(
                "Import returned \(response.count) fields instead of 2."
            )
        }
        let importedItems = try descriptorList(
            response[0],
            context: "imported media rows"
        ).map { descriptor -> PhotosAutomationImportedItem in
            let row = try descriptorList(descriptor, context: "imported media row")
            guard row.count == 2 else {
                throw PhotosAutomationError.malformedResponse(
                    "An imported media row returned \(row.count) fields instead of 2."
                )
            }
            return PhotosAutomationImportedItem(
                id: try descriptorString(row[0], context: "imported media ID"),
                filename: try descriptorString(row[1], context: "imported media filename")
            )
        }
        return PhotosAutomationImportResult(
            requestedFiles: fileURLs,
            importedItems: importedItems,
            verifiedItemIdentifiers: try descriptorList(
                response[1],
                context: "verified imported media IDs"
            ).map { try descriptorString($0, context: "verified imported media ID") }
        )
    }

    /// Sets the date on one newly imported item and reads it back by ID.
    /// Pass the Date as an Apple event descriptor to avoid locale-dependent
    /// AppleScript date strings and time-zone conversions.
    func setCaptureDate(_ captureDate: Date, for identifier: String) throws -> Date {
        let itemID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else {
            throw PhotosAutomationError.invalidMediaItemIdentifier
        }
        let source = """
        on setCaptureDate(itemID, requestedDate)
            with timeout of 120 seconds
                tell application id "\(Self.photosBundleIdentifier)"
                    set targetItem to media item id itemID
                    if (id of targetItem as text) is not itemID then error "The imported item ID changed."
                    set date of targetItem to requestedDate
                    return date of targetItem
                end tell
            end timeout
        end setCaptureDate
        """
        guard let script = NSAppleScript(source: source) else {
            throw PhotosAutomationError.scriptCompilation("NSAppleScript could not create the date-setting script.")
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(
            NSAppleEventDescriptor(string: "setcapturedate"),
            forKeyword: AEKeyword(keyASSubroutineName)
        )
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: itemID), at: 1)
        arguments.insert(NSAppleEventDescriptor(date: captureDate), at: 2)
        event.setParam(arguments, forKeyword: keyDirectObject)
        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo { throw Self.mapScriptError(errorInfo) }
        guard result.dateValue != nil else {
            throw PhotosAutomationError.malformedResponse("Photos returned no date after setting \(itemID).")
        }

        let readSource = """
        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set targetItem to media item id \(Self.appleScriptStringLiteral(itemID))
                return {id of targetItem as text, date of targetItem}
            end tell
        end timeout
        """
        var observedDate: Date?
        for attempt in 0..<5 {
            try Task.checkCancellation()
            let row = try descriptorList(try execute(readSource), context: "capture date verification")
            guard row.count == 2,
                  try descriptorString(row[0], context: "capture date media ID") == itemID else {
                throw PhotosAutomationError.malformedResponse("Photos returned a different item while checking the capture date.")
            }
            observedDate = row[1].dateValue
            if let observedDate,
               abs(observedDate.timeIntervalSince(captureDate)) < 1 {
                return observedDate
            }
            if attempt < 4 { Thread.sleep(forTimeInterval: 0.5) }
        }
        guard let observedDate else {
            throw PhotosAutomationError.malformedResponse("Photos returned no capture date for \(itemID).")
        }
        return observedDate
    }

    /// Reads the Photos capture date directly. Targeted metadata rows omit it.
    func captureDate(for identifier: String) throws -> Date {
        let itemID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else {
            throw PhotosAutomationError.invalidMediaItemIdentifier
        }
        let source = """
        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set targetItem to media item id \(Self.appleScriptStringLiteral(itemID))
                return {id of targetItem as text, date of targetItem}
            end tell
        end timeout
        """
        let row = try descriptorList(try execute(source), context: "capture date verification")
        guard row.count == 2,
              try descriptorString(row[0], context: "capture date media ID") == itemID,
              let date = row[1].dateValue else {
            throw PhotosAutomationError.malformedResponse(
                "Photos returned no matching capture date for \(itemID)."
            )
        }
        return date
    }

    /// Read the Photos library properties immediately before a transfer.
    func transferProperties(for identifier: String) throws -> (favorite: Bool, location: PhotoTransferLocation?) {
        let itemID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else { throw PhotosAutomationError.invalidMediaItemIdentifier }
        let source = """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            return theValue as text
        end textOrEmpty

        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set targetItem to media item id \(Self.appleScriptStringLiteral(itemID))
                set locationValue to location of targetItem
                set locationText to ""
                if locationValue is not missing value then
                    set locationText to (my textOrEmpty(item 1 of locationValue)) & "," & (my textOrEmpty(item 2 of locationValue))
                end if
                return {id of targetItem as text, favorite of targetItem, locationText}
            end tell
        end timeout
        """
        let row = try descriptorList(try execute(source), context: "transfer properties")
        guard row.count == 3,
              try descriptorString(row[0], context: "transfer media ID") == itemID else {
            throw PhotosAutomationError.malformedResponse("Photos returned a different item while reading transfer properties.")
        }
        let locationText = try descriptorString(row[2], context: "transfer location")
        let location = PhotoTransferLocation.fromPhotosDescription(locationText)
        guard locationText.isEmpty || locationText == "," || location != nil else {
            throw PhotosAutomationError.malformedResponse("Photos returned an invalid transfer location.")
        }
        return (descriptorBool(row[1]), location)
    }

    /// Apply only properties available through Photos scripting, then read them back.
    func setTransferProperties(
        favorite: Bool,
        location: PhotoTransferLocation?,
        for identifier: String
    ) throws {
        let itemID = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !itemID.isEmpty else { throw PhotosAutomationError.invalidMediaItemIdentifier }
        let locationStatement: String
        if let location {
            guard location.latitude.isFinite, location.longitude.isFinite,
                  (-90...90).contains(location.latitude),
                  (-180...180).contains(location.longitude) else {
                throw PhotosAutomationError.malformedResponse("The source location is invalid.")
            }
            locationStatement = "set location of targetItem to {\(location.latitude), \(location.longitude)}"
        } else {
            locationStatement = "set location of targetItem to {missing value, missing value}"
        }
        let source = """
        with timeout of 120 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set targetItem to media item id \(Self.appleScriptStringLiteral(itemID))
                if (id of targetItem as text) is not \(Self.appleScriptStringLiteral(itemID)) then error "The imported item ID changed."
                set favorite of targetItem to \(favorite ? "true" : "false")
                \(locationStatement)
            end tell
        end timeout
        """
        _ = try execute(source)
        let observed = try transferProperties(for: itemID)
        let locationMatches = location.map { observed.location?.matches($0) == true }
            ?? (observed.location == nil)
        guard observed.favorite == favorite, locationMatches else {
            throw PhotosAutomationError.malformedResponse("The destination did not retain the source favorite or location.")
        }
    }

    /// Create or reuse the matching user album, then verify every imported ID.
    /// This uses Photos scripting only; it never touches a library package.
    func addImportedItems(_ itemIDs: [String], to album: PhotoTransferAlbum) throws {
        guard !itemIDs.isEmpty else { return }
        let folderLiterals = album.folderNames.map(Self.appleScriptStringLiteral).joined(separator: ", ")
        let itemLiterals = itemIDs.map(Self.appleScriptStringLiteral).joined(separator: ", ")
        let source = """
        with timeout of 300 seconds
            tell application id "\(Self.photosBundleIdentifier)"
                set parentFolder to missing value
                set requestedFolderNames to {\(folderLiterals)}
                repeat with folderNameValue in requestedFolderNames
                    set folderName to folderNameValue as text
                    set matchingFolders to {}
                    if parentFolder is missing value then
                        set candidateContainers to get (every container whose name is folderName)
                        repeat with candidate in candidateContainers
                            if class of candidate is folder then set end of matchingFolders to candidate
                        end repeat
                    else
                        set matchingFolders to get (every folder of parentFolder whose name is folderName)
                    end if
                    if (count of matchingFolders) > 1 then error "Ambiguous destination folder: " & folderName
                    if (count of matchingFolders) is 0 then
                        if parentFolder is missing value then
                            set parentFolder to make new folder named folderName
                        else
                            set parentFolder to make new folder named folderName at parentFolder
                        end if
                    else
                        set parentFolder to item 1 of matchingFolders
                    end if
                end repeat

                set albumName to \(Self.appleScriptStringLiteral(album.name))
                set matchingAlbums to {}
                if parentFolder is missing value then
                    set candidateContainers to get (every container whose name is albumName)
                    repeat with candidate in candidateContainers
                        if class of candidate is album then set end of matchingAlbums to candidate
                    end repeat
                else
                    set matchingAlbums to get (every album of parentFolder whose name is albumName)
                end if
                if (count of matchingAlbums) > 1 then error "Ambiguous destination album: " & albumName
                if (count of matchingAlbums) is 0 then
                    if parentFolder is missing value then
                        set targetAlbum to make new album named albumName
                    else
                        set targetAlbum to make new album named albumName at parentFolder
                    end if
                else
                    set targetAlbum to item 1 of matchingAlbums
                end if

                set requestedIDs to {\(itemLiterals)}
                set targetItems to {}
                repeat with requestedIDValue in requestedIDs
                    set requestedID to requestedIDValue as text
                    set matchingItems to get (every media item whose id is requestedID)
                    if (count of matchingItems) is not 1 then error "Imported media item is unavailable: " & requestedID
                    set end of targetItems to item 1 of matchingItems
                end repeat
                add targetItems to targetAlbum

                set albumIDs to id of every media item of targetAlbum
                repeat with requestedIDValue in requestedIDs
                    if (requestedIDValue as text) is not in albumIDs then error "Album membership could not be verified"
                end repeat
                return true
            end tell
        end timeout
        """
        let result = try execute(source)
        guard result.booleanValue else {
            throw PhotosAutomationError.malformedResponse("Album membership was not verified.")
        }
    }

    /// Exports a group with one Photos `export` command. Only items whose
    /// normalized filename stem is unique within the group are included, so
    /// every observed output can be associated with one requested asset
    /// without relying on export order. Ambiguous or unmatched items are
    /// returned as failures for the caller's isolated-export fallback.
    func exportMediaItems(
        items: [PhotosAutomationMediaItem],
        version: PhotosAutomationExportVersion,
        to stagingDirectory: URL
    ) throws -> PhotosAutomationBatchExportResult {
        guard !items.isEmpty,
              items.count <= Self.maximumBatchExportCount,
              items.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PhotosAutomationError.invalidBatchExportCount(items.count)
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: stagingDirectory.path) else {
            throw PhotosAutomationError.stagingDirectoryUnavailable(
                stagingDirectory,
                "The location must already exist and be writable by the app."
            )
        }

        let batchDirectory = stagingDirectory.appendingPathComponent(
            "photos-automation-bulk",
            isDirectory: true
        )
        do {
            if fileManager.fileExists(atPath: batchDirectory.path) {
                try fileManager.removeItem(at: batchDirectory)
            }
            try fileManager.createDirectory(at: batchDirectory, withIntermediateDirectories: false)
        } catch {
            throw PhotosAutomationError.stagingDirectoryUnavailable(
                stagingDirectory,
                error.localizedDescription
            )
        }

        let useOriginals: String
        switch version {
        case .original:
            useOriginals = "true"
        case .rendered:
            useOriginals = "false"
        }
        let itemsByStem = Dictionary(grouping: items) {
            Self.normalizedExportStem($0.filename)
        }
        let bulkItems = items.filter { item in
            let stem = Self.normalizedExportStem(item.filename)
            return !stem.isEmpty && itemsByStem[stem]?.count == 1
        }
        let operationBlocks = bulkItems.map { item in
            let identifierLiteral = Self.appleScriptStringLiteral(item.id)
            return """
                    try
                        set targetItem to missing value
                        try
                            set targetItem to media item id \(identifierLiteral)
                            if (id of targetItem as text) is not \(identifierLiteral) then set targetItem to missing value
                        end try
                        if targetItem is missing value then
                            set matchingItems to every media item whose id is \(identifierLiteral)
                            if (count of matchingItems) is greater than 0 then set targetItem to item 1 of matchingItems
                        end if
                        if targetItem is missing value then
                            set end of resultRows to {\(identifierLiteral), false, "", "", "Media item not found"}
                        else
                            set reportedFilename to filename of targetItem as text
                            set end of targetItems to targetItem
                            set end of resultRows to {\(identifierLiteral), true, id of targetItem as text, reportedFilename, ""}
                        end if
                    on error errorMessage number errorNumber
                        set end of resultRows to {\(identifierLiteral), false, "", "", (errorNumber as text) & ": " & errorMessage}
                    end try
            """
        }.joined(separator: "\n")
        let source = """
        set resultRows to {}
        set targetItems to {}
        with timeout of 600 seconds
            tell application id "\(Self.photosBundleIdentifier)"
        \(operationBlocks)
                if (count of targetItems) is greater than 0 then
                    export targetItems to POSIX file \(Self.appleScriptStringLiteral(batchDirectory.path)) using originals \(useOriginals)
                end if
            end tell
        end timeout
        return resultRows
        """

        let response: NSAppleEventDescriptor
        do {
            response = try execute(source)
        } catch {
            try? fileManager.removeItem(at: batchDirectory)
            throw error
        }

        do {
            let rows = try descriptorList(response, context: "batch export results")
            guard rows.count == bulkItems.count else {
                throw PhotosAutomationError.malformedResponse(
                    "Batch export returned \(rows.count) rows for \(bulkItems.count) items."
                )
            }

            var parsedRows: [(requestedID: String, returnedID: String, filename: String, error: String?)] = []
            parsedRows.reserveCapacity(rows.count)
            for (index, descriptor) in rows.enumerated() {
                let row = try descriptorList(descriptor, context: "batch export row")
                guard row.count == 5 else {
                    throw PhotosAutomationError.malformedResponse(
                        "A batch export row returned \(row.count) fields instead of 5."
                    )
                }
                let requestedIdentifier = try descriptorString(row[0], context: "requested media ID")
                guard requestedIdentifier == bulkItems[index].id else {
                    throw PhotosAutomationError.malformedResponse(
                        "Batch export returned media items in an unexpected order."
                    )
                }
                if descriptorBool(row[1]) {
                    parsedRows.append((
                        requestedIdentifier,
                        try descriptorString(row[2], context: "export media ID"),
                        try descriptorString(row[3], context: "export filename"),
                        nil
                    ))
                } else {
                    parsedRows.append((
                        requestedIdentifier,
                        "",
                        "",
                        try descriptorString(row[4], context: "batch export error")
                    ))
                }
            }
            let successfulCount = parsedRows.reduce(into: 0) { count, row in
                if row.error == nil { count += 1 }
            }
            let observedFiles = try waitForStableBatchExportFiles(
                in: batchDirectory,
                expectedMinimumCount: successfulCount
            )
            let filesByStem = Dictionary(grouping: observedFiles) {
                Self.normalizedExportStem($0.lastPathComponent)
            }
            let successfulRowsByStem = Dictionary(grouping: parsedRows.filter { $0.error == nil }) {
                Self.normalizedExportStem($0.filename)
            }

            let bulkResults = parsedRows.map { row in
                guard row.error == nil else {
                    return PhotosAutomationBatchExportItemResult(
                        requestedMediaItemID: row.requestedID,
                        exportResult: nil,
                        errorDescription: row.error
                    )
                }
                let stem = Self.normalizedExportStem(row.filename)
                guard successfulRowsByStem[stem]?.count == 1,
                      let matchingFiles = filesByStem[stem],
                      Self.containsCompatiblePreviewResource(
                          matchingFiles,
                          for: items.first { $0.id == row.requestedID }
                      ) else {
                    return PhotosAutomationBatchExportItemResult(
                        requestedMediaItemID: row.requestedID,
                        exportResult: nil,
                        errorDescription: "Bulk export output could not be uniquely matched to this media item."
                    )
                }
                return PhotosAutomationBatchExportItemResult(
                    requestedMediaItemID: row.requestedID,
                    exportResult: PhotosAutomationExportResult(
                        mediaItemID: row.returnedID,
                        reportedFilename: row.filename,
                        version: version,
                        destinationDirectory: batchDirectory,
                        observedFiles: matchingFiles
                    ),
                    errorDescription: nil
                )
            }
            let bulkIDs = Set(bulkItems.map(\.id))
            let ambiguousResults = items.compactMap { item -> PhotosAutomationBatchExportItemResult? in
                guard !bulkIDs.contains(item.id) else { return nil }
                return PhotosAutomationBatchExportItemResult(
                    requestedMediaItemID: item.id,
                    exportResult: nil,
                    errorDescription: "The filename is empty or duplicated in this batch; isolated export is required."
                )
            }
            let resultsByID = Dictionary(
                uniqueKeysWithValues: (bulkResults + ambiguousResults).map {
                    ($0.requestedMediaItemID, $0)
                }
            )
            return PhotosAutomationBatchExportResult(
                destinationDirectory: batchDirectory,
                itemResults: items.compactMap { resultsByID[$0.id] }
            )
        } catch {
            try? fileManager.removeItem(at: batchDirectory)
            throw error
        }
    }
}

private extension PhotosAutomationClient {
    nonisolated static let photosBundleIdentifier = "com.apple.Photos"

    nonisolated static func normalizedExportStem(_ filename: String) -> String {
        let lastComponent = URL(fileURLWithPath: filename).lastPathComponent
        let stem = (lastComponent as NSString).deletingPathExtension
        return stem
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func containsCompatiblePreviewResource(
        _ files: [URL],
        for item: PhotosAutomationMediaItem?
    ) -> Bool {
        guard let item else { return false }
        for fileURL in files {
            if let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                if item.pixelWidth <= 0 || item.pixelHeight <= 0 ||
                    (width == item.pixelWidth && height == item.pixelHeight) ||
                    (width == item.pixelHeight && height == item.pixelWidth) {
                    return true
                }
            }

            if let type = UTType(filenameExtension: fileURL.pathExtension),
               type.conforms(to: .audiovisualContent) {
                // AVFoundation validates and decodes the video when the
                // thumbnail is generated. Filename uniqueness still provides
                // the asset association here.
                return true
            }
        }
        return false
    }

    /// Waits for a shared batch destination to contain at least one resource
    /// per successfully resolved media item. Photos' normal synchronous return
    /// is the fast path; if files are delayed, the complete set must remain
    /// unchanged across observations. A rendered Live Photo or RAW pair may
    /// legitimately contribute more than one resource.
    nonisolated func waitForStableBatchExportFiles(
        in directory: URL,
        expectedMinimumCount: Int,
        timeoutSeconds: TimeInterval = 60
    ) throws -> [URL] {
        guard expectedMinimumCount > 0 else { return [] }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var previousSizes: [String: Int]?
        var latestFiles: [URL] = []
        var hasWaitedForDelayedFiles = false

        repeat {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ).filter {
                let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                return values.isRegularFile == true && (values.fileSize ?? 0) > 0
            }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
            latestFiles = files

            let sizes = try Dictionary(uniqueKeysWithValues: files.map { fileURL in
                let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return (fileURL.lastPathComponent, size)
            })
            if files.count >= expectedMinimumCount {
                if !hasWaitedForDelayedFiles || previousSizes == sizes {
                    return files
                }
            }
            previousSizes = sizes

            if Date() >= deadline { break }
            hasWaitedForDelayedFiles = true
            Thread.sleep(forTimeInterval: 0.5)
        } while true

        return latestFiles
    }

    /// Photos can return from its export command before rendered files have
    /// appeared, especially while it is downloading or rendering assets. Wait
    /// for immediately available files, then wait for delayed destinations to
    /// contain non-empty files whose sizes are unchanged across observations.
    /// On timeout, return the latest non-empty files so the decoder can make
    /// the final validity decision.
    nonisolated func waitForStableExportFiles(
        in directoriesByIndex: [Int: URL],
        successfulIndices: Set<Int>,
        timeoutSeconds: TimeInterval = 60
    ) throws -> [Int: [URL]] {
        guard !successfulIndices.isEmpty else { return [:] }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var previousSizes: [Int: [String: Int]] = [:]
        var stableObservationCounts: [Int: Int] = [:]
        var latestFiles: [Int: [URL]] = [:]
        var completedFiles: [Int: [URL]] = [:]
        var hasWaitedForDelayedFiles = false

        repeat {
            for index in successfulIndices where completedFiles[index] == nil {
                guard let directory = directoriesByIndex[index] else { continue }
                let files = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ).filter {
                    let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    return values.isRegularFile == true && (values.fileSize ?? 0) > 0
                }.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                guard !files.isEmpty else {
                    previousSizes[index] = nil
                    stableObservationCounts[index] = 0
                    continue
                }

                let sizes = try Dictionary(uniqueKeysWithValues: files.map { fileURL in
                    let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    return (fileURL.lastPathComponent, size)
                })
                latestFiles[index] = files
                if !hasWaitedForDelayedFiles {
                    // Photos normally returns only after complete files exist.
                    // Preserve that fast path; stability polling is needed
                    // only after at least one destination was initially empty.
                    completedFiles[index] = files
                } else if previousSizes[index] == sizes {
                    let stableCount = (stableObservationCounts[index] ?? 0) + 1
                    stableObservationCounts[index] = stableCount
                    if stableCount >= 1 {
                        completedFiles[index] = files
                    }
                } else {
                    previousSizes[index] = sizes
                    stableObservationCounts[index] = 0
                }
            }

            if Set(completedFiles.keys).isSuperset(of: successfulIndices) {
                return completedFiles
            }
            if Date() >= deadline { break }
            hasWaitedForDelayedFiles = true
            Thread.sleep(forTimeInterval: 0.5)
        } while true

        for index in successfulIndices where completedFiles[index] == nil {
            completedFiles[index] = latestFiles[index] ?? []
        }
        return completedFiles
    }

    nonisolated func validatePhotoLibraryURL(_ url: URL) throws {
        guard url.pathExtension.caseInsensitiveCompare("photoslibrary") == .orderedSame else {
            throw PhotosAutomationError.invalidPhotoLibrary(url)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PhotosAutomationError.libraryUnavailable(url)
        }
    }

    nonisolated func validate(limit: Int) throws {
        guard (1...Self.maximumEnumerationLimit).contains(limit) else {
            throw PhotosAutomationError.invalidLimit(limit)
        }
    }

    nonisolated func execute(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw PhotosAutomationError.scriptCompilation("NSAppleScript could not create the script object.")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        guard errorInfo == nil else {
            throw Self.mapScriptError(errorInfo!)
        }
        return result
    }

    nonisolated static func mapScriptError(_ info: NSDictionary) -> PhotosAutomationError {
        let number = (info["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
        let message = (info["NSAppleScriptErrorMessage"] as? String)
            ?? (info["NSAppleScriptErrorBriefMessage"] as? String)
            ?? "No error detail was supplied."

        switch number {
        case -1743, -10004:
            return .automationDenied(message)
        case -600, -609, -1708:
            return .photosNotAvailable(message)
        case -1712:
            return .timedOut(message)
        case -2740, -2741:
            return .scriptCompilation(message)
        default:
            return .scriptExecution(number: number, message: message)
        }
    }

    nonisolated static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    nonisolated func parseSnapshot(_ descriptor: NSAppleEventDescriptor) throws -> PhotosAutomationLibrarySnapshot {
        let list = try descriptorList(descriptor, context: "library snapshot")
        guard list.count == 6 else {
            throw PhotosAutomationError.malformedResponse("Snapshot returned \(list.count) fields instead of 6.")
        }

        return PhotosAutomationLibrarySnapshot(
            totalAlbumCount: descriptorInt(list[0]),
            totalFolderCount: descriptorInt(list[1]),
            totalMediaItemCount: descriptorInt(list[2]),
            albums: try descriptorList(list[3], context: "album rows").map(parseAlbum),
            folders: try descriptorList(list[4], context: "folder rows").map(parseFolder),
            mediaItems: try descriptorList(list[5], context: "media rows").map(parseMediaItem)
        )
    }

    nonisolated func parseMediaCatalogPage(
        _ descriptor: NSAppleEventDescriptor
    ) throws -> PhotosAutomationMediaCatalogPage {
        let list = try descriptorList(descriptor, context: "media catalog page")
        guard list.count == 2 else {
            throw PhotosAutomationError.malformedResponse(
                "Media catalog page returned \(list.count) fields instead of 2."
            )
        }
        return PhotosAutomationMediaCatalogPage(
            totalMediaItemCount: descriptorInt(list[0]),
            mediaItems: try descriptorList(list[1], context: "media catalog rows").map(parseMediaItem)
        )
    }

    nonisolated func parseAlbumCatalogPage(
        _ descriptor: NSAppleEventDescriptor
    ) throws -> PhotosAutomationAlbumCatalogPage {
        let list = try descriptorList(descriptor, context: "album catalog page")
        guard list.count == 2 else {
            throw PhotosAutomationError.malformedResponse(
                "Album catalog page returned \(list.count) fields instead of 2."
            )
        }
        return PhotosAutomationAlbumCatalogPage(
            totalAlbumCount: descriptorInt(list[0]),
            albums: try descriptorList(list[1], context: "album catalog rows").map(parseAlbum)
        )
    }

    nonisolated func parseAlbumMembershipPage(
        _ descriptor: NSAppleEventDescriptor,
        albumID: String
    ) throws -> PhotosAutomationAlbumMembershipPage {
        let list = try descriptorList(descriptor, context: "album membership page")
        guard list.count == 3 else {
            throw PhotosAutomationError.malformedResponse(
                "Album membership page returned \(list.count) fields instead of 3."
            )
        }
        guard list[0].booleanValue else {
            throw PhotosAutomationError.albumNotFound(albumID)
        }
        return PhotosAutomationAlbumMembershipPage(
            totalMediaItemCount: descriptorInt(list[1]),
            mediaItemIDs: try descriptorList(
                list[2],
                context: "album membership IDs"
            ).map { try descriptorString($0, context: "album media-item ID") }
        )
    }

    nonisolated func parseBasicMediaCatalog(
        _ descriptor: NSAppleEventDescriptor
    ) throws -> PhotosAutomationBasicCatalog {
        let response = try descriptorList(descriptor, context: "basic media catalog")
        guard response.count == 8 else {
            throw PhotosAutomationError.malformedResponse(
                "Basic media catalog returned \(response.count) fields instead of 8."
            )
        }

        let total = descriptorInt(response[0])
        guard total >= 0 else {
            throw PhotosAutomationError.malformedResponse("Basic media catalog returned a negative count.")
        }
        let identifiers = try descriptorList(response[1], context: "basic media IDs")
        let filenames = try descriptorList(response[2], context: "basic media filenames")
        let names = try descriptorList(response[3], context: "basic media names")
        let dates = try descriptorList(response[4], context: "basic media dates")
        let favorites = try descriptorList(response[5], context: "basic media favorites")
        let widths = try descriptorList(response[6], context: "basic media widths")
        let heights = try descriptorList(response[7], context: "basic media heights")
        let lists = [identifiers, filenames, names, dates, favorites, widths, heights]
        guard lists.allSatisfy({ $0.count == total }) else {
            throw PhotosAutomationError.malformedResponse(
                "Basic media property lists changed length while Photos was reading the catalog."
            )
        }

        var seenIdentifiers = Set<String>()
        var items: [PhotosAutomationMediaItem] = []
        items.reserveCapacity(total)
        for index in 0..<total {
            let identifier = descriptorOptionalString(identifiers[index])
            guard !identifier.isEmpty, seenIdentifiers.insert(identifier).inserted else {
                throw PhotosAutomationError.malformedResponse(
                    "Basic media catalog contains an empty or duplicate identifier."
                )
            }
            items.append(
                PhotosAutomationMediaItem(
                    id: identifier,
                    filename: descriptorOptionalString(filenames[index]),
                    name: descriptorOptionalString(names[index]),
                    itemDescription: "",
                    dateDescription: descriptorOptionalString(dates[index]),
                    captureDate: dates[index].dateValue,
                    isFavorite: descriptorBool(favorites[index]),
                    pixelWidth: descriptorInt(widths[index]),
                    pixelHeight: descriptorInt(heights[index]),
                    fileSize: nil,
                    locationDescription: "",
                    keywords: []
                )
            )
        }

        return PhotosAutomationBasicCatalog(totalMediaItemCount: total, mediaItems: items)
    }

    nonisolated func parseBulkMetadataCatalog(
        _ descriptor: NSAppleEventDescriptor
    ) throws -> PhotosAutomationMediaCatalogPage {
        let response = try descriptorList(descriptor, context: "bulk metadata catalog")
        guard response.count == 6 else {
            throw PhotosAutomationError.malformedResponse(
                "Bulk metadata catalog returned \(response.count) fields instead of 6."
            )
        }

        let total = descriptorInt(response[0])
        guard total >= 0 else {
            throw PhotosAutomationError.malformedResponse("Bulk metadata catalog returned a negative count.")
        }
        let identifiers = try descriptorList(response[1], context: "metadata IDs")
        let descriptions = try descriptorList(response[2], context: "metadata descriptions")
        let sizes = try descriptorList(response[3], context: "metadata sizes")
        let locations = try descriptorList(response[4], context: "metadata locations")
        let keywordLists = try descriptorList(response[5], context: "metadata keyword lists")
        let lists = [identifiers, descriptions, sizes, locations, keywordLists]
        guard lists.allSatisfy({ $0.count == total }) else {
            throw PhotosAutomationError.malformedResponse(
                "Metadata property lists changed length while Photos was reading the catalog."
            )
        }

        var seenIdentifiers = Set<String>()
        var items: [PhotosAutomationMediaItem] = []
        items.reserveCapacity(total)
        for index in 0..<total {
            let identifier = descriptorOptionalString(identifiers[index])
            guard !identifier.isEmpty, seenIdentifiers.insert(identifier).inserted else {
                throw PhotosAutomationError.malformedResponse(
                    "Bulk metadata catalog contains an empty or duplicate identifier."
                )
            }
            let locationParts = try descriptorList(
                locations[index],
                context: "metadata location"
            )
            let location = locationParts.count >= 2
                ? "\(descriptorOptionalString(locationParts[0])),\(descriptorOptionalString(locationParts[1]))"
                : ""
            let keywords = try descriptorList(
                keywordLists[index],
                context: "metadata keywords"
            ).map(descriptorOptionalString)
            items.append(
                PhotosAutomationMediaItem(
                    id: identifier,
                    filename: "",
                    name: "",
                    itemDescription: descriptorOptionalString(descriptions[index]),
                    dateDescription: "",
                    captureDate: nil,
                    isFavorite: false,
                    pixelWidth: 0,
                    pixelHeight: 0,
                    fileSize: descriptorOptionalFileSize(sizes[index]),
                    locationDescription: location,
                    keywords: keywords
                )
            )
        }

        return PhotosAutomationMediaCatalogPage(
            totalMediaItemCount: total,
            mediaItems: items
        )
    }

    nonisolated func parseMetadataRow(
        _ descriptor: NSAppleEventDescriptor
    ) throws -> PhotosAutomationMediaItem {
        let row = try descriptorList(descriptor, context: "targeted metadata row")
        guard row.count == 5 else {
            throw PhotosAutomationError.malformedResponse(
                "A targeted metadata row returned \(row.count) fields instead of 5."
            )
        }
        return PhotosAutomationMediaItem(
            id: try descriptorString(row[0], context: "metadata media ID"),
            filename: "",
            name: "",
            itemDescription: descriptorOptionalString(row[1]),
            dateDescription: "",
            captureDate: nil,
            isFavorite: false,
            pixelWidth: 0,
            pixelHeight: 0,
            fileSize: descriptorOptionalFileSize(row[2]),
            locationDescription: descriptorOptionalString(row[3]),
            keywords: try descriptorList(row[4], context: "metadata keywords")
                .map(descriptorOptionalString)
        )
    }

    nonisolated func parseSearchResult(_ descriptor: NSAppleEventDescriptor) throws -> PhotosAutomationSearchResult {
        let list = try descriptorList(descriptor, context: "search result")
        guard list.count == 2 else {
            throw PhotosAutomationError.malformedResponse("Search returned \(list.count) fields instead of 2.")
        }
        return PhotosAutomationSearchResult(
            totalMatchCount: descriptorInt(list[0]),
            mediaItems: try descriptorList(list[1], context: "search media rows").map(parseMediaItem)
        )
    }

    nonisolated func parseAlbum(_ descriptor: NSAppleEventDescriptor) throws -> PhotosAutomationAlbum {
        let row = try descriptorList(descriptor, context: "album row")
        guard row.count == 4 else {
            throw PhotosAutomationError.malformedResponse("An album row returned \(row.count) fields instead of 4.")
        }
        return PhotosAutomationAlbum(
            id: try descriptorString(row[0], context: "album ID"),
            name: try descriptorString(row[1], context: "album name"),
            parentName: nilIfEmpty(try descriptorString(row[2], context: "album parent")),
            mediaItemCount: descriptorInt(row[3])
        )
    }

    nonisolated func parseFolder(_ descriptor: NSAppleEventDescriptor) throws -> PhotosAutomationFolder {
        let row = try descriptorList(descriptor, context: "folder row")
        guard row.count == 5 else {
            throw PhotosAutomationError.malformedResponse("A folder row returned \(row.count) fields instead of 5.")
        }
        return PhotosAutomationFolder(
            id: try descriptorString(row[0], context: "folder ID"),
            name: try descriptorString(row[1], context: "folder name"),
            parentName: nilIfEmpty(try descriptorString(row[2], context: "folder parent")),
            albumCount: descriptorInt(row[3]),
            folderCount: descriptorInt(row[4])
        )
    }

    nonisolated func parseMediaItem(_ descriptor: NSAppleEventDescriptor) throws -> PhotosAutomationMediaItem {
        let row = try descriptorList(descriptor, context: "media row")
        guard row.count == 11 else {
            throw PhotosAutomationError.malformedResponse("A media row returned \(row.count) fields instead of 11.")
        }
        let keywordDescriptors = try descriptorList(row[10], context: "media keywords")
        return PhotosAutomationMediaItem(
            id: try descriptorString(row[0], context: "media ID"),
            filename: try descriptorString(row[1], context: "media filename"),
            name: try descriptorString(row[2], context: "media name"),
            itemDescription: try descriptorString(row[3], context: "media description"),
            dateDescription: try descriptorString(row[4], context: "media date"),
            captureDate: row[4].dateValue,
            isFavorite: descriptorBool(row[5]),
            pixelWidth: descriptorInt(row[6]),
            pixelHeight: descriptorInt(row[7]),
            fileSize: descriptorOptionalFileSize(row[8]),
            locationDescription: try descriptorString(row[9], context: "media location"),
            keywords: try keywordDescriptors.map { try descriptorString($0, context: "media keyword") }
        )
    }

    nonisolated func descriptorList(
        _ descriptor: NSAppleEventDescriptor,
        context: String
    ) throws -> [NSAppleEventDescriptor] {
        guard descriptor.numberOfItems >= 0 else {
            throw PhotosAutomationError.malformedResponse("\(context) is not a list.")
        }
        if descriptor.numberOfItems == 0 { return [] }
        return try (1...descriptor.numberOfItems).map { index in
            guard let item = descriptor.atIndex(index) else {
                throw PhotosAutomationError.malformedResponse("\(context) is missing item \(index).")
            }
            return item
        }
    }

    nonisolated func descriptorString(
        _ descriptor: NSAppleEventDescriptor,
        context: String
    ) throws -> String {
        guard let value = descriptor.stringValue else {
            throw PhotosAutomationError.malformedResponse("\(context) is not text.")
        }
        return value
    }

    nonisolated func descriptorOptionalString(_ descriptor: NSAppleEventDescriptor) -> String {
        descriptor.stringValue ?? ""
    }

    nonisolated func descriptorInt(_ descriptor: NSAppleEventDescriptor) -> Int {
        Int(descriptor.int32Value)
    }

    /// File size is best-effort metadata. Photos can report an empty value or
    /// zero for an unavailable/iCloud-backed resource, and some AppleScript
    /// coercions use floating-point text for large integers. None of those
    /// cases should invalidate the containing media item or metadata batch.
    nonisolated func descriptorOptionalFileSize(
        _ descriptor: NSAppleEventDescriptor
    ) -> Int? {
        guard let rawValue = descriptor.stringValue else { return nil }
        let text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let value = Int(text), value > 0 {
            return value
        }
        guard let approximateValue = Double(text),
              approximateValue.isFinite,
              approximateValue > 0,
              approximateValue < Double(Int.max) else {
            return nil
        }
        return Int(approximateValue.rounded(.towardZero))
    }

    nonisolated func descriptorBool(_ descriptor: NSAppleEventDescriptor) -> Bool {
        descriptor.booleanValue
    }

    nonisolated func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
