import Combine
import Foundation
import OSLog
import UniformTypeIdentifiers

@MainActor
final class RegisteredLibraryProbeModel: ObservableObject {
    nonisolated private static let fingerprintPageSize = 200
    nonisolated private static let batchFingerprintSize = 50
    nonisolated private static let initialCatalogPageSize = 100
    nonisolated private static let catalogPageSize = 500
    nonisolated private static let albumCatalogPageSize = 500
    nonisolated private static let metadataPageSize = 500
    nonisolated private static let targetedMetadataBatchSize = 200
    nonisolated private static let exportBatchSize = 100
    /// Original exports can contain large images and paired movies.
    nonisolated private static let livePhotoExportBatchSize = 20
    nonisolated private static let previewRetryDelay: Duration = .seconds(30)
    nonisolated private static let thumbnailCheckpointInterval = 100
    nonisolated private static let performanceLogger = Logger(
        subsystem: "PhotoLibraries",
        category: "PreviewIndexing"
    )

    private let client = PhotosAutomationClient()
    private var previewTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var automaticProbeTask: Task<Void, Never>?
    private var isAutomaticIndexing = false
    private var lastAutomaticSyncStartedAt: Date?
    private var directTasks: [LibraryID: Task<Void, Never>] = [:]
    private var lastDirectReadAt: [LibraryID: Date] = [:]
    private var pendingTransferRefreshes: Set<LibraryID> = []
    @Published private(set) var directErrors: [LibraryID: String] = [:]

    @Published private(set) var openResult: PhotosAutomationOpenResult?
    @Published private(set) var snapshot: PhotosAutomationLibrarySnapshot?
    @Published private(set) var searchResult: PhotosAutomationSearchResult?
    @Published private(set) var exportResult: PhotosAutomationExportResult?
    @Published private(set) var isWorking = false
    @Published private(set) var userConfirmedPhotosReady = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var previewCompletedCount = 0
    @Published private(set) var previewTotalCount = 0
    @Published private(set) var isIndexing = false
    @Published private(set) var isWaitingForPhotos = false
    @Published private(set) var activeLibraryID: LibraryID?
    @Published private(set) var isWaitingForPreviewRetry = false
    @Published private(set) var deferredPreviewCount = 0
    @Published private(set) var isCancellingIndex = false

    @Published var searchQuery = ""

    var isPhotosRunning: Bool { client.isPhotosRunning }

    func loadDirectCatalog(
        registry: LibraryRegistry, libraryID: LibraryID,
        store: LibraryPreviewStore, forceRefresh: Bool = false
    ) {
        guard directTasks[libraryID] == nil,
              (forceRefresh || lastDirectReadAt[libraryID].map {
                  Date().timeIntervalSince($0) >= 60
              } != false),
              let selected = registry.libraries.first(where: { $0.id == libraryID }),
              !selected.descriptor.kind.isSystemPhotoLibrary,
              selected.availability == .online else { return }
        let descriptor = selected.descriptor
        directTasks[libraryID] = Task { [weak self] in
            defer {
                self?.directTasks[libraryID] = nil
                if self?.pendingTransferRefreshes.contains(libraryID) == true {
                    _ = self?.pendingTransferRefreshes.remove(libraryID)
                    self?.loadDirectCatalog(
                        registry: registry, libraryID: libraryID,
                        store: store, forceRefresh: true
                    )
                }
            }
            do {
                let provider = RegisteredPhotoLibraryProvider(
                    bookmarkData: descriptor.bookmarkData
                )
                // The catalog is public SQLite data in the selected package.
                // Read it outside the media worker so a pending image or video
                // request cannot prevent a library refresh.
                let catalog = try await registry.withReadAccessOffMain(to: libraryID) { url in
                    try DirectLibraryCatalog.read(from: url)
                }
                try Task.checkCancellation()
                try store.adoptDirectCatalog(
                    catalog, provider: provider, libraryID: libraryID,
                    displayName: descriptor.metadata.displayName
                )
                self?.lastDirectReadAt[libraryID] = .now
                self?.directErrors[libraryID] = nil
                self?.statusMessage = "Read \(catalog.items.count) items directly from \(descriptor.metadata.displayName)."
            } catch is CancellationError {
                return
            } catch {
                self?.directErrors[libraryID] = error.localizedDescription
            }
        }
    }

    func refreshDirectCatalogs(registry: LibraryRegistry, store: LibraryPreviewStore) {
        for library in registry.libraries where !library.descriptor.kind.isSystemPhotoLibrary {
            loadDirectCatalog(registry: registry, libraryID: library.id, store: store)
        }
    }

    func refreshAfterTransfer(
        registry: LibraryRegistry, libraryID: LibraryID, store: LibraryPreviewStore
    ) {
        if directTasks[libraryID] != nil {
            pendingTransferRefreshes.insert(libraryID)
        } else {
            loadDirectCatalog(
                registry: registry, libraryID: libraryID,
                store: store, forceRefresh: true
            )
        }
    }

    func cancelAutomaticSync() {
        automaticProbeTask?.cancel()
        if isAutomaticIndexing {
            cancelPreviewLoading()
        }
    }

    func attemptAutomaticSync(
        registry: LibraryRegistry,
        store: LibraryPreviewStore,
        bypassThrottle: Bool = false
    ) {
        guard client.isPhotosRunning,
              automaticProbeTask == nil,
              readinessTask == nil,
              previewTask == nil,
              !isWorking,
              store.activeIndexLibraryID == nil,
              (bypassThrottle
                || (lastAutomaticSyncStartedAt.map({ Date().timeIntervalSince($0) >= 300 }) ?? true)),
              !(openResult != nil && !userConfirmedPhotosReady) else {
            return
        }

        let candidates = registry.libraries.compactMap { library -> AutoSyncCandidate? in
            guard !library.descriptor.kind.isSystemPhotoLibrary,
                  library.availability == .online,
                  let manifest = store.manifest(for: library.id),
                  !manifest.items.isEmpty else {
                return nil
            }
            return AutoSyncCandidate(library: library, manifest: manifest)
        }
        guard !candidates.isEmpty else { return }

        automaticProbeTask = Task { [weak self] in
            guard let self else { return }
            defer { automaticProbeTask = nil }
            do {
                let sample = try await Task.detached(priority: .utility) {
                    try PhotosAutomationClient().mediaCatalogPage(
                        offset: 0,
                        limit: Self.fingerprintPageSize
                    )
                }.value
                try Task.checkCancellation()

                let matches = candidates.filter {
                    Self.fingerprintMatches(sample: sample, manifest: $0.manifest)
                }
                guard matches.count == 1, let match = matches.first else { return }

                activeLibraryID = match.library.id
                lastAutomaticSyncStartedAt = .now
                userConfirmedPhotosReady = true
                openResult = nil
                if Self.manifestNeedsCompletion(match.manifest)
                    || store.hasMissingPlaybackVideos(for: match.library.id)
                    || store.hasPendingLivePhotoChecks(for: match.library.id) {
                    statusMessage = "Verified the library currently open in Photos. Completing its index automatically."
                    indexPreviews(
                        libraryID: match.library.id,
                        displayName: match.library.descriptor.metadata.displayName,
                        forceRefresh: false,
                        initialCatalogPage: sample,
                        isAutomatic: true,
                        store: store
                    )
                    return
                }

                statusMessage = "Checking \(match.library.descriptor.metadata.displayName) for changes."
                let catalog = try await readAutomaticSyncCatalog()
                try Task.checkCancellation()
                guard !Self.catalogMatchesManifest(catalog, manifest: match.manifest) else {
                    statusMessage = "No changes detected in \(match.library.descriptor.metadata.displayName)."
                    return
                }

                statusMessage = "Changes detected. Synchronizing \(match.library.descriptor.metadata.displayName)."
                indexPreviews(
                    libraryID: match.library.id,
                    displayName: match.library.descriptor.metadata.displayName,
                    forceRefresh: false,
                    preparedCatalog: catalog,
                    isAutomatic: true,
                    store: store
                )
            } catch is CancellationError {
                return
            } catch {
                // Automatic probing is opportunistic. A Photos modal dialog,
                // incomplete launch, or ambiguous response must not disturb
                // cached browsing or trigger writes to an uncertain library.
                statusMessage = "Automatic change checking could not finish. The cached index was not changed."
                return
            }
        }
    }

    func openAndIndex(
        registry: LibraryRegistry,
        libraryID: LibraryID,
        displayName: String,
        forceRefresh: Bool,
        store: LibraryPreviewStore
    ) {
        guard readinessTask == nil,
              previewTask == nil,
              store.activeIndexLibraryID == nil else {
            errorMessage = "Another library is being indexed. Wait or cancel before switching Photos."
            return
        }
        automaticProbeTask?.cancel()
        activeLibraryID = libraryID
        isCancellingIndex = false
        errorMessage = nil
        isWorking = true
        let knownFingerprints = registry.libraries.compactMap { library -> KnownLibraryFingerprint? in
            guard !library.descriptor.kind.isSystemPhotoLibrary,
                  let manifest = store.manifest(for: library.id),
                  !manifest.items.isEmpty else {
                return nil
            }
            return KnownLibraryFingerprint(
                libraryID: library.id,
                displayName: library.descriptor.metadata.displayName,
                manifest: manifest
            )
        }
        let targetHasKnownFingerprint = knownFingerprints.contains {
            $0.libraryID == libraryID
        }
        let photosProcessIdentifierBeforeOpen = client.photosProcessIdentifier
        isWaitingForPhotos = true

        readinessTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isWorking = false
                isWaitingForPhotos = false
                readinessTask = nil
            }

            do {
                let result = try await registry.withReadAccess(to: libraryID) { url in
                    try await self.client.openPhotoLibrary(at: url)
                }
                openResult = result
                userConfirmedPhotosReady = false
                snapshot = nil
                searchResult = nil
                statusMessage = "Opening \(displayName) in Photos and waiting for its catalog to become ready."
                isWorking = false

                let deadline = Date().addingTimeInterval(120)
                var previousPage: PhotosAutomationMediaCatalogPage?
                var observedProcessIdentifier = photosProcessIdentifierBeforeOpen
                var catalogProbeNotBefore = Date().addingTimeInterval(8)

                // Opening the library normally makes Photos relaunch, but
                // opening the library that Photos already has open may keep
                // the same process. Treat a PID change as a useful signal,
                // not as a requirement, then verify readiness by observing a
                // stable catalog response below.
                while Date() < catalogProbeNotBefore, Date() < deadline {
                    try Task.checkCancellation()
                    let currentProcessIdentifier = client.photosProcessIdentifier
                    if currentProcessIdentifier != nil,
                       currentProcessIdentifier != observedProcessIdentifier {
                        observedProcessIdentifier = currentProcessIdentifier
                        catalogProbeNotBefore = Date().addingTimeInterval(4)
                        statusMessage = "Photos restarted. Waiting for \(displayName)'s catalog to initialize…"
                    } else {
                        statusMessage = currentProcessIdentifier == nil
                            ? "Waiting for Photos to launch…"
                            : "Waiting for Photos to open \(displayName)…"
                    }
                    try await Task.sleep(for: .seconds(2))
                }

                while Date() < deadline {
                    try Task.checkCancellation()
                    let currentProcessIdentifier = client.photosProcessIdentifier
                    guard let currentProcessIdentifier else {
                        previousPage = nil
                        observedProcessIdentifier = nil
                        statusMessage = "Waiting for Photos to launch…"
                        try await Task.sleep(for: .seconds(2))
                        continue
                    }

                    if currentProcessIdentifier != observedProcessIdentifier {
                        observedProcessIdentifier = currentProcessIdentifier
                        previousPage = nil
                        statusMessage = "Photos restarted. Waiting for \(displayName)'s catalog to initialize…"
                        try await Task.sleep(for: .seconds(4))
                        continue
                    }

                    let page = try await Task.detached(priority: .userInitiated) {
                        try PhotosAutomationClient().mediaCatalogPage(
                            offset: 0,
                            limit: Self.fingerprintPageSize,
                            timeoutSeconds: 15
                        )
                    }.value
                    try Task.checkCancellation()

                    if page == previousPage {
                        let matchingFingerprints = knownFingerprints.filter {
                            Self.fingerprintMatches(sample: page, manifest: $0.manifest)
                        }
                        let targetMatches = matchingFingerprints.contains {
                            $0.libraryID == libraryID
                        }
                        let otherMatches = matchingFingerprints.filter {
                            $0.libraryID != libraryID
                        }

                        if targetHasKnownFingerprint,
                           (!targetMatches || !otherMatches.isEmpty) {
                            if let wrongLibrary = otherMatches.first, !targetMatches {
                                statusMessage = "Photos is still using \(wrongLibrary.displayName). Switch to \(displayName) in Photos to continue; no \(displayName) index data has been changed."
                            } else if targetMatches, !otherMatches.isEmpty {
                                statusMessage = "The Photos catalog identity is ambiguous between registered libraries. Indexing is paused to protect \(displayName)'s cache."
                            } else {
                                statusMessage = "Photos has not yet opened \(displayName). Waiting for its verified catalog; no index data has been changed."
                            }
                            previousPage = nil
                            try await Task.sleep(for: .seconds(2))
                            continue
                        }

                        if !targetHasKnownFingerprint, let wrongLibrary = otherMatches.first {
                            statusMessage = "Photos is still using \(wrongLibrary.displayName). Switch to \(displayName) in Photos to continue; a new index will not be created from the wrong library."
                            previousPage = nil
                            try await Task.sleep(for: .seconds(2))
                            continue
                        }

                        userConfirmedPhotosReady = true
                        openResult = nil
                        statusMessage = forceRefresh
                            ? "Photos catalog is ready. Rebuilding all previews automatically."
                            : "Photos catalog is ready. Indexing automatically."
                        indexPreviews(
                            libraryID: libraryID,
                            displayName: displayName,
                            forceRefresh: forceRefresh,
                            initialCatalogPage: page,
                            store: store
                        )
                        return
                    }

                    previousPage = page
                    statusMessage = "Photos is open. Waiting for \(displayName)'s catalog to stabilize…"
                    try await Task.sleep(for: .seconds(2))
                }

                throw PhotosAutomationError.timedOut(
                    "The catalog did not become stable within two minutes. Retry after Photos finishes loading the library."
                )
            } catch is CancellationError {
                openResult = nil
                statusMessage = "Waiting for Photos was cancelled."
            } catch {
                openResult = nil
                errorMessage = error.localizedDescription
                if let automationError = error as? PhotosAutomationError,
                   let suggestion = automationError.recoverySuggestion {
                    errorMessage = "\(error.localizedDescription) \(suggestion)"
                }
            }
        }
    }

    /// Requests that macOS open the selected package in Photos without reading,
    /// indexing, or otherwise changing this app's cached library data. Photos
    /// may still show its own switch-library confirmation, and its public APIs
    /// do not let this app verify which library has ultimately finished loading.
    func openInPhotos(
        registry: LibraryRegistry,
        libraryID: LibraryID,
        displayName: String,
        store: LibraryPreviewStore
    ) {
        guard readinessTask == nil,
              previewTask == nil,
              store.activeIndexLibraryID == nil,
              !isWorking else {
            errorMessage = "Wait for the current indexing or Photos readiness operation to finish before opening another library."
            return
        }

        automaticProbeTask?.cancel()
        activeLibraryID = libraryID
        isCancellingIndex = false
        errorMessage = nil
        isWorking = true
        let isSystemLibrary = registry.descriptors.first { $0.id == libraryID }?
            .kind.isSystemPhotoLibrary == true

        Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }

            do {
                let photosPIDBeforeOpen = client.photosProcessIdentifier
                _ = try await registry.withReadAccess(to: libraryID) { url in
                    try await self.client.openPhotoLibrary(at: url)
                }
                // An accepted document-open request does not prove that Photos
                // completed a library switch.
                openResult = nil
                userConfirmedPhotosReady = false
                snapshot = nil
                searchResult = nil
                statusMessage = "Requested Photos open \(displayName). Confirm any Photos switch dialog."

                guard isSystemLibrary, let photosPIDBeforeOpen else { return }
                let deadline = Date().addingTimeInterval(60)
                while Date() < deadline {
                    let currentPID = client.photosProcessIdentifier
                    if currentPID != photosPIDBeforeOpen {
                        // Photos may relaunch itself after switching libraries.
                        // Only resend the document if it remains closed.
                        guard currentPID == nil else {
                            statusMessage = "Photos reopened. Wait for \(displayName) to finish loading."
                            return
                        }
                        statusMessage = "Photos closed while switching. Waiting for it to reopen…"
                        try await Task.sleep(for: .seconds(5))
                        guard client.photosProcessIdentifier == nil else {
                            statusMessage = "Photos reopened. Wait for \(displayName) to finish loading."
                            return
                        }
                        _ = try await registry.withReadAccess(to: libraryID) { url in
                            try await self.client.openPhotoLibrary(at: url)
                        }
                        statusMessage = "Requested Photos reopen \(displayName). Wait for the library to finish loading."
                        return
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
                statusMessage = "Photos is still open. If it did not switch to \(displayName), quit Photos and try again."
            } catch is CancellationError {
                statusMessage = "Opening \(displayName) in Photos was cancelled."
            } catch {
                errorMessage = error.localizedDescription
                if let automationError = error as? PhotosAutomationError,
                   let suggestion = automationError.recoverySuggestion {
                    errorMessage = "\(error.localizedDescription) \(suggestion)"
                }
            }
        }
    }

    func search() {
        guard requireConfirmation(), !isIndexing else { return }
        run {
            searchResult = try client.search(searchQuery, limit: 50)
            statusMessage = "Search completed in the library currently open in Photos."
        }
    }

    func export(_ item: PhotosAutomationMediaItem, version: PhotosAutomationExportVersion) {
        guard requireConfirmation(), !isIndexing else { return }
        run {
            let stagingRoot = try Self.automationStagingRoot()
            exportResult = try client.exportMediaItem(
                identifier: item.id,
                version: version,
                to: stagingRoot
            )
            statusMessage = "Photos returned from export. Observed files are shown below; this is not a complete resource-fidelity guarantee."
        }
    }

    private func indexPreviews(
        libraryID: LibraryID,
        displayName: String,
        forceRefresh: Bool,
        initialCatalogPage: PhotosAutomationMediaCatalogPage? = nil,
        preparedCatalog: PreparedAutomaticSyncCatalog? = nil,
        isAutomatic: Bool = false,
        store: LibraryPreviewStore
    ) {
        guard requireConfirmation(), activeLibraryID == libraryID, !isIndexing else {
            if activeLibraryID != libraryID {
                errorMessage = "The library selected for indexing has not been verified as the library currently open in Photos."
            }
            return
        }
        guard store.claimIndex(for: libraryID) else {
            errorMessage = "Another library is being indexed. Wait or cancel before switching Photos."
            return
        }
        activeLibraryID = libraryID
        errorMessage = nil
        previewCompletedCount = 0
        previewTotalCount = 0
        deferredPreviewCount = 0
        isCancellingIndex = false
        isIndexing = true
        isAutomaticIndexing = isAutomatic

        previewTask = Task { [self] in
            var cacheRoot: URL?
            var didBeginIndex = false
            do {
                let catalogResult: (
                    items: [PhotosAutomationMediaItem],
                    totalMediaItemCount: Int,
                    metadataNeedsEnrichment: Bool
                )
                if let preparedCatalog {
                    catalogResult = (
                        preparedCatalog.items,
                        preparedCatalog.totalMediaItemCount,
                        false
                    )
                } else {
                    do {
                        statusMessage = "Reading the fast basic catalog from Photos."
                        let basicCatalog = try await Task.detached(priority: .userInitiated) {
                            try PhotosAutomationClient().basicMediaCatalog()
                        }.value
                        try Task.checkCancellation()
                        try await publishProgressIncrementally(
                            from: 0,
                            through: basicCatalog.mediaItems.count,
                            total: basicCatalog.totalMediaItemCount,
                            phase: .readingCatalog,
                            store: store,
                            for: libraryID
                        )
                        catalogResult = (
                            basicCatalog.mediaItems,
                            basicCatalog.totalMediaItemCount,
                            true
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        statusMessage = "Fast catalog access is unavailable. Using the compatible 500-item paging method."
                        let firstPage: PhotosAutomationMediaCatalogPage
                        if let initialCatalogPage {
                            firstPage = initialCatalogPage
                        } else {
                            firstPage = try await Task.detached(priority: .userInitiated) {
                                try PhotosAutomationClient().mediaCatalogPage(
                                    offset: 0,
                                    limit: Self.initialCatalogPageSize
                                )
                            }.value
                        }
                        try Task.checkCancellation()
                        previewTotalCount = firstPage.totalMediaItemCount
                        try await publishProgressIncrementally(
                            from: 0,
                            through: firstPage.mediaItems.count,
                            total: firstPage.totalMediaItemCount,
                            phase: .readingCatalog,
                            store: store,
                            for: libraryID
                        )

                        var pagedItems = firstPage.mediaItems
                        while pagedItems.count < firstPage.totalMediaItemCount {
                            try Task.checkCancellation()
                            let offset = pagedItems.count
                            let page = try await Task.detached(priority: .userInitiated) {
                                try PhotosAutomationClient().mediaCatalogPage(
                                    offset: offset,
                                    limit: Self.catalogPageSize
                                )
                            }.value
                            guard !page.mediaItems.isEmpty else {
                                throw PhotosAutomationError.malformedResponse(
                                    "Photos returned an empty media page at offset \(offset)."
                                )
                            }
                            let previousCount = pagedItems.count
                            pagedItems.append(contentsOf: page.mediaItems)
                            try await publishProgressIncrementally(
                                from: previousCount,
                                through: pagedItems.count,
                                total: firstPage.totalMediaItemCount,
                                phase: .readingCatalog,
                                store: store,
                                for: libraryID
                            )
                        }
                        catalogResult = (
                            pagedItems,
                            firstPage.totalMediaItemCount,
                            false
                        )
                    }
                }
                let items = catalogResult.items
                let totalMediaItemCount = catalogResult.totalMediaItemCount
                let metadataNeedsEnrichment = catalogResult.metadataNeedsEnrichment

                let albums: [PhotosAutomationAlbum]
                if let preparedCatalog {
                    albums = preparedCatalog.albums
                } else {
                    statusMessage = "Reading albums from Photos."
                    albums = try await readAlbums(catalogItemIDs: Set(items.map(\.id)))
                }

                let plan = try store.beginIndex(
                    libraryID: libraryID,
                    displayName: displayName,
                    totalMediaItemCount: totalMediaItemCount,
                    items: items,
                    albums: albums,
                    forceRefresh: forceRefresh,
                    metadataNeedsEnrichment: metadataNeedsEnrichment
                )
                didBeginIndex = true
                let root = try Self.preparePreviewCache(for: libraryID)
                cacheRoot = root
                previewCompletedCount = items.count - plan.itemsNeedingPreviews.count
                previewTotalCount = items.count
                var itemsSinceCheckpoint = 0
                store.updateIndexProgress(
                    completed: previewCompletedCount,
                    total: items.count,
                    phase: .generatingPreviews,
                    for: libraryID
                )

                var previewWorkItems = plan.itemsNeedingPreviews
                let initialPreviewItemCount = previewWorkItems.count
                var deferredItemIDs = Set<String>()
                var batchStart = 0
                while batchStart < previewWorkItems.count {
                    try Task.checkCancellation()
                    let currentFingerprint = try await Task.detached(priority: .utility) {
                        try PhotosAutomationClient().catalogFingerprint(
                            limit: Self.batchFingerprintSize
                        )
                    }.value
                    try Task.checkCancellation()
                    guard let currentManifest = store.manifest(for: libraryID),
                          Self.fingerprintMatches(
                            fingerprint: currentFingerprint,
                            manifest: currentManifest
                          ) else {
                        throw PhotosAutomationError.malformedResponse(
                            "Photos changed to a different library before the next preview batch. Indexing stopped before exporting more items."
                        )
                    }
                    let currentPassEnd = batchStart < initialPreviewItemCount
                        ? initialPreviewItemCount
                        : previewWorkItems.count
                    let batchEnd = min(
                        batchStart + Self.exportBatchSize,
                        currentPassEnd
                    )
                    let batchItems = Array(
                        previewWorkItems[batchStart..<batchEnd]
                    )
                    let isDeferredPass = batchStart >= initialPreviewItemCount
                    let batchResult: PhotosAutomationBatchExportResult?
                    do {
                        batchResult = try await exportPreviewBatchWithRecovery(
                            batchItems,
                            to: root,
                            libraryID: libraryID,
                            store: store
                        )
                    } catch PreviewIndexingError.previewBatchShouldBeDeferred {
                        if !isDeferredPass {
                            previewWorkItems.append(contentsOf: batchItems)
                            deferredItemIDs.formUnion(batchItems.map(\.id))
                            statusMessage = "Deferred \(batchItems.count) previews that Photos did not produce. Continuing with later items."
                        } else {
                            deferredItemIDs.formUnion(batchItems.map(\.id))
                            statusMessage = "Photos still did not produce \(batchItems.count) deferred previews. They remain pending for the next synchronization."
                        }
                        deferredPreviewCount = deferredItemIDs.count
                        batchStart = batchEnd
                        continue
                    }
                    var updates: [LibraryPreviewUpdate]

                    if let batchResult {
                        do {
                            updates = try await Self.makePreviewUpdates(from: batchResult)
                        } catch {
                            try? FileManager.default.removeItem(at: batchResult.destinationDirectory)
                            throw error
                        }
                        try? FileManager.default.removeItem(at: batchResult.destinationDirectory)
                    } else {
                        // Split only a failed bulk command. Successful halves
                        // remain batched; a persistently failing leaf uses the
                        // proven isolated-export path.
                        updates = try await makePreviewUpdatesByBisecting(
                            batchItems,
                            stagingRoot: root
                        )
                    }

                    if batchResult != nil,
                       updates.contains(where: { $0.thumbnailData == nil }) {
                        updates = try await retryFailedPreviewUpdates(
                            updates,
                            items: batchItems,
                            stagingRoot: root
                        )
                    }

                    let failedUpdateIDs = Set(updates.compactMap { update in
                        update.thumbnailData == nil ? update.itemID : nil
                    })
                    if !failedUpdateIDs.isEmpty {
                        deferredItemIDs.formUnion(failedUpdateIDs)
                        if !isDeferredPass {
                            let failedItems = batchItems.filter {
                                failedUpdateIDs.contains($0.id)
                            }
                            previewWorkItems.append(contentsOf: failedItems)
                            statusMessage = "Deferred \(failedItems.count) previews that Photos did not produce. Continuing with later items."
                        } else {
                            statusMessage = "Photos still did not produce \(failedUpdateIDs.count) deferred previews. They remain pending for the next synchronization."
                        }
                    }
                    try Task.checkCancellation()
                    let completedBeforeBatch = previewCompletedCount
                    try await store.storePreviewUpdates(updates, libraryID: libraryID)
                    let completedAfterBatch = store.manifest(for: libraryID)?
                        .thumbnailFilenames.count ?? completedBeforeBatch
                    previewCompletedCount = completedAfterBatch
                    try await publishProgressIncrementally(
                        from: completedBeforeBatch,
                        through: completedAfterBatch,
                        total: previewTotalCount,
                        phase: .generatingPreviews,
                        store: store,
                        for: libraryID
                    )
                    itemsSinceCheckpoint += updates.count
                    if itemsSinceCheckpoint >= Self.thumbnailCheckpointInterval {
                        try await store.checkpointIndex(libraryID: libraryID)
                        itemsSinceCheckpoint = 0
                    }
                    deferredItemIDs.subtract(updates.compactMap { update in
                        store.hasThumbnail(for: update.itemID, libraryID: libraryID)
                            ? update.itemID
                            : nil
                    })
                    deferredPreviewCount = deferredItemIDs.count

                    batchStart = batchEnd
                }
                try await store.checkpointIndex(libraryID: libraryID)
                let remainingDeferredCount = store.manifest(for: libraryID)?
                    .pendingPreviewItemIDs?
                    .reduce(into: 0) { count, itemID in
                        if deferredItemIDs.contains(itemID) { count += 1 }
                    } ?? 0
                if remainingDeferredCount > 0 {
                    throw PreviewIndexingError.deferredPreviewsRemain(remainingDeferredCount)
                }

                let pendingMetadataIDs = store.manifest(for: libraryID)?
                    .pendingMetadataItemIDs ?? []
                if metadataNeedsEnrichment, !pendingMetadataIDs.isEmpty {
                    var enrichmentCompleted = false

                    if pendingMetadataIDs.count == totalMediaItemCount {
                        store.updateIndexProgress(
                            completed: 0,
                            total: totalMediaItemCount,
                            phase: .enrichingMetadata,
                            for: libraryID
                        )
                        let startedAt = Date()
                        do {
                            let catalog = try await Task.detached(priority: .utility) {
                                try PhotosAutomationClient().bulkMetadataCatalog()
                            }.value
                            try Task.checkCancellation()
                            guard catalog.totalMediaItemCount == totalMediaItemCount,
                                  catalog.mediaItems.count == totalMediaItemCount else {
                                throw PhotosAutomationError.malformedResponse(
                                    "The Photos catalog changed while bulk metadata was being read."
                                )
                            }
                            _ = try await publishMetadataIncrementally(
                                catalog.mediaItems,
                                completed: 0,
                                total: totalMediaItemCount,
                                store: store,
                                libraryID: libraryID
                            )
                            try await store.checkpointIndex(libraryID: libraryID)
                            let elapsed = Date().timeIntervalSince(startedAt)
                            Self.performanceLogger.info(
                                "Bulk metadata enriched \(totalMediaItemCount, privacy: .public) items in \(elapsed, privacy: .public) seconds"
                            )
                            enrichmentCompleted = true
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            statusMessage = "Bulk metadata access is unavailable. Using the compatible 500-item paging method."
                            Self.performanceLogger.error(
                                "Bulk metadata enrichment failed: \(error.localizedDescription)"
                            )
                        }
                    } else {
                        store.updateIndexProgress(
                            completed: 0,
                            total: pendingMetadataIDs.count,
                            phase: .enrichingMetadata,
                            for: libraryID
                        )
                        let startedAt = Date()
                        do {
                            var pendingOffset = 0
                            var metadataCompleted = 0
                            while pendingOffset < pendingMetadataIDs.count {
                                try Task.checkCancellation()
                                let pendingEnd = min(
                                    pendingOffset + Self.targetedMetadataBatchSize,
                                    pendingMetadataIDs.count
                                )
                                let identifiers = Array(pendingMetadataIDs[pendingOffset..<pendingEnd])
                                let page = try await Task.detached(priority: .utility) {
                                    try PhotosAutomationClient().metadataForIdentifiers(identifiers)
                                }.value
                                guard page.mediaItems.count == identifiers.count,
                                      Set(page.mediaItems.map(\.id)) == Set(identifiers) else {
                                    throw PhotosAutomationError.malformedResponse(
                                        "Photos did not return every requested metadata record."
                                    )
                                }
                                metadataCompleted = try await publishMetadataIncrementally(
                                    page.mediaItems,
                                    completed: metadataCompleted,
                                    total: pendingMetadataIDs.count,
                                    store: store,
                                    libraryID: libraryID
                                )
                                pendingOffset = pendingEnd
                            }
                            try await store.checkpointIndex(libraryID: libraryID)
                            let elapsed = Date().timeIntervalSince(startedAt)
                            Self.performanceLogger.info(
                                "Targeted metadata enriched \(pendingMetadataIDs.count, privacy: .public) items in \(elapsed, privacy: .public) seconds"
                            )
                            enrichmentCompleted = true
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            statusMessage = "Targeted metadata access is unavailable. Using the compatible 500-item paging method."
                            Self.performanceLogger.error(
                                "Targeted metadata enrichment failed: \(error.localizedDescription)"
                            )
                        }
                    }

                    if !enrichmentCompleted {
                        var metadataOffset = 0
                        var metadataCompleted = 0
                        store.updateIndexProgress(
                            completed: 0,
                            total: totalMediaItemCount,
                            phase: .enrichingMetadata,
                            for: libraryID
                        )
                        while metadataOffset < totalMediaItemCount {
                            try Task.checkCancellation()
                            let page = try await Task.detached(priority: .utility) {
                                try PhotosAutomationClient().mediaCatalogPage(
                                    offset: metadataOffset,
                                    limit: Self.metadataPageSize
                                )
                            }.value
                            guard page.totalMediaItemCount == totalMediaItemCount,
                                  !page.mediaItems.isEmpty else {
                                throw PhotosAutomationError.malformedResponse(
                                    "The Photos catalog changed during metadata fallback at offset \(metadataOffset)."
                                )
                            }
                            metadataCompleted = try await publishMetadataIncrementally(
                                page.mediaItems,
                                completed: metadataCompleted,
                                total: totalMediaItemCount,
                                store: store,
                                libraryID: libraryID
                            )
                            metadataOffset += page.mediaItems.count
                        }
                        try await store.checkpointIndex(libraryID: libraryID)
                    }
                }
                if !plan.itemsNeedingPlaybackVideos.isEmpty {
                    let videoItems = plan.itemsNeedingPlaybackVideos
                    store.updateIndexProgress(
                        completed: 0,
                        total: videoItems.count,
                        phase: .generatingPlaybackVideos,
                        for: libraryID
                    )
                    var completedVideoCount = 0
                    var failedVideoCount = 0
                    for item in videoItems {
                        try Task.checkCancellation()
                        let fingerprint = try await Task.detached(priority: .utility) {
                            try PhotosAutomationClient().catalogFingerprint(
                                limit: Self.batchFingerprintSize
                            )
                        }.value
                        guard let currentManifest = store.manifest(for: libraryID),
                              Self.fingerprintMatches(
                                fingerprint: fingerprint,
                                manifest: currentManifest
                              ) else {
                            throw PhotosAutomationError.malformedResponse(
                                "Photos changed libraries before video playback caching finished."
                            )
                        }
                        do {
                            let result = try await Task.detached(priority: .utility) {
                                try PhotosAutomationClient().exportMediaItem(
                                    identifier: item.id,
                                    version: .original,
                                    to: root
                                )
                            }.value
                            defer { try? FileManager.default.removeItem(at: result.destinationDirectory) }
                            let proxy = try await VideoPlaybackProxyLoader.create(
                                from: result,
                                expectedItem: item,
                                stagingRoot: root
                            )
                            defer { try? FileManager.default.removeItem(at: proxy) }
                            try await store.storePlaybackVideo(proxy, for: item.id, libraryID: libraryID)
                            try await store.checkpointIndex(libraryID: libraryID)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failedVideoCount += 1
                            Self.performanceLogger.error(
                                "Playback proxy failed for \(item.id, privacy: .private): \(error.localizedDescription, privacy: .public)"
                            )
                        }
                        completedVideoCount += 1
                        store.updateIndexProgress(
                            completed: completedVideoCount,
                            total: videoItems.count,
                            phase: .generatingPlaybackVideos,
                            for: libraryID
                        )
                    }
                    if failedVideoCount > 0 {
                        statusMessage = "\(failedVideoCount) videos could not be cached. They will be retried on the next synchronization."
                    }
                }
                if !plan.itemsNeedingLivePhotoChecks.isEmpty {
                    let photoItems = plan.itemsNeedingLivePhotoChecks
                    store.updateIndexProgress(
                        completed: 0,
                        total: photoItems.count,
                        phase: .checkingLivePhotos,
                        for: libraryID
                    )
                    var failedCount = 0
                    var batchStart = 0
                    while batchStart < photoItems.count {
                        try Task.checkCancellation()
                        let fingerprint = try await Task.detached(priority: .utility) {
                            try PhotosAutomationClient().catalogFingerprint(
                                limit: Self.batchFingerprintSize
                            )
                        }.value
                        guard let currentManifest = store.manifest(for: libraryID),
                              Self.fingerprintMatches(
                                fingerprint: fingerprint,
                                manifest: currentManifest
                              ) else {
                            throw PhotosAutomationError.malformedResponse(
                                "Photos changed libraries before Live Photo caching finished."
                            )
                        }

                        let batchEnd = min(
                            batchStart + Self.livePhotoExportBatchSize,
                            photoItems.count
                        )
                        let batchItems = Array(photoItems[batchStart..<batchEnd])
                        var batchResult: PhotosAutomationBatchExportResult?
                        do {
                            let exported = try await Task.detached(priority: .utility) {
                                try PhotosAutomationClient().exportMediaItems(
                                    items: batchItems,
                                    version: .original,
                                    to: root
                                )
                            }.value
                            if Task.isCancelled {
                                try? FileManager.default.removeItem(at: exported.destinationDirectory)
                                throw CancellationError()
                            }
                            batchResult = exported
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            Self.performanceLogger.error(
                                "Live Photo batch export failed for \(batchItems.count, privacy: .public) items: \(error.localizedDescription, privacy: .public). Retrying items separately."
                            )
                            batchResult = nil
                        }
                        defer {
                            if let batchResult {
                                try? FileManager.default.removeItem(at: batchResult.destinationDirectory)
                            }
                        }

                        // Confirm that Photos stayed on the same library while
                        // the original-resource export command was running.
                        let fingerprintAfterExport = try await Task.detached(priority: .utility) {
                            try PhotosAutomationClient().catalogFingerprint(
                                limit: Self.batchFingerprintSize
                            )
                        }.value
                        try Task.checkCancellation()
                        guard let currentManifestAfterExport = store.manifest(for: libraryID),
                              Self.fingerprintMatches(
                                fingerprint: fingerprintAfterExport,
                                manifest: currentManifestAfterExport
                              ) else {
                            throw PhotosAutomationError.malformedResponse(
                                "Photos changed libraries during Live Photo batch export."
                            )
                        }

                        // A paired movie with an unexpected filename cannot be
                        // assigned safely by stem. Recheck the whole batch in
                        // isolated export directories in that case.
                        let hasUnassignedMovie = batchResult.map(Self.hasUnassignedLivePhotoMovie) ?? false
                        let resultsByID = Dictionary(uniqueKeysWithValues:
                            (batchResult?.itemResults ?? []).map { ($0.requestedMediaItemID, $0) }
                        )
                        for (offset, item) in batchItems.enumerated() {
                            try Task.checkCancellation()
                            do {
                                let batchExport = resultsByID[item.id]?.exportResult
                                if let batchExport, !hasUnassignedMovie {
                                    do {
                                        try await recordLivePhotoCheck(
                                            from: batchExport,
                                            item: item,
                                            stagingRoot: root,
                                            libraryID: libraryID,
                                            store: store
                                        )
                                    } catch is CancellationError {
                                        throw CancellationError()
                                    } catch {
                                        try await recordLivePhotoCheckIndividually(
                                            item,
                                            stagingRoot: root,
                                            libraryID: libraryID,
                                            store: store
                                        )
                                    }
                                } else {
                                    try await recordLivePhotoCheckIndividually(
                                        item,
                                        stagingRoot: root,
                                        libraryID: libraryID,
                                        store: store
                                    )
                                }
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                failedCount += 1
                                Self.performanceLogger.error(
                                    "Live Photo check failed for \(item.id, privacy: .private): \(error.localizedDescription, privacy: .public)"
                                )
                            }
                            store.updateIndexProgress(
                                completed: batchStart + offset + 1,
                                total: photoItems.count,
                                phase: .checkingLivePhotos,
                                for: libraryID
                            )
                        }
                        try await store.checkpointIndex(libraryID: libraryID)
                        batchStart = batchEnd
                    }
                    if failedCount > 0 {
                        statusMessage = "\(failedCount) photos could not be checked for Live Photo motion. They will be retried on the next synchronization."
                    }
                }
                try store.finishIndex(libraryID: libraryID, completed: true)
                let finalManifest = store.manifest(for: libraryID)
                let pendingCount = finalManifest?.pendingPreviewItemIDs?.count ?? 0
                let pendingMetadataCount = finalManifest?.pendingMetadataItemIDs?.count ?? 0
                let missingVideoCount = finalManifest?.items.filter {
                    UnifiedSearchViewModel.mediaType(for: $0.filename) == "video"
                        && !store.hasPlaybackVideo(for: $0.id, libraryID: libraryID)
                }.count ?? 0
                let checkedLivePhotoIDs = Set(finalManifest?.livePhotoCheckedItemIDs ?? [])
                let pendingLivePhotoCount = finalManifest?.items.filter {
                    UnifiedSearchViewModel.mediaType(for: $0.filename) != "video"
                        && !checkedLivePhotoIDs.contains($0.id)
                }.count ?? 0
                if pendingCount == 0, pendingMetadataCount == 0,
                   missingVideoCount == 0, pendingLivePhotoCount == 0 {
                    if forceRefresh {
                        statusMessage = "Index is current. Rebuilt \(plan.rebuiltCount) previews."
                    } else {
                        statusMessage = "Index is current. Added \(plan.addedCount), updated \(plan.modifiedCount), removed \(plan.removedCount), and filled \(plan.missingPreviewCount) missing previews."
                    }
                } else {
                    statusMessage = "Index synchronized with \(pendingCount) previews, \(pendingMetadataCount) metadata records, \(missingVideoCount) videos, and \(pendingLivePhotoCount) Live Photo checks still needing retry. Completed work remains cached."
                }
            } catch is CancellationError {
                if didBeginIndex {
                    try? store.finishIndex(libraryID: libraryID, completed: false)
                }
                statusMessage = "Indexing cancelled. Completed thumbnails remain in the app cache."
            } catch PreviewIndexingError.deferredPreviewsRemain(let count) {
                if didBeginIndex {
                    try? store.finishIndex(libraryID: libraryID, completed: false)
                }
                errorMessage = nil
                statusMessage = "Indexing continued past unavailable batches. \(count) previews remain safely deferred for the next synchronization."
            } catch {
                if didBeginIndex {
                    try? store.finishIndex(libraryID: libraryID, completed: false)
                }
                errorMessage = error.localizedDescription
            }
            if let cacheRoot {
                try? FileManager.default.removeItem(at: cacheRoot)
            }
            store.releaseIndex(for: libraryID)
            isIndexing = false
            isAutomaticIndexing = false
            isCancellingIndex = false
            previewTask = nil
        }
        store.setIndexCancellation({ [weak self] in self?.cancelPreviewLoading() }, for: libraryID)
    }

    func cancelPreviewLoading() {
        guard previewTask != nil, !isCancellingIndex else { return }
        isCancellingIndex = true
        statusMessage = "Cancellation requested. Waiting for the current Photos export batch to return; no further batch will start."
        previewTask?.cancel()
    }

    private static func isMovieFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
    }

    private static func hasUnassignedLivePhotoMovie(
        _ batch: PhotosAutomationBatchExportResult
    ) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: batch.destinationDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return true }
        let assigned = Set(batch.itemResults.compactMap(\.exportResult)
            .flatMap(\.observedFiles).map(\.standardizedFileURL))
        return files.contains { isMovieFile($0) && !assigned.contains($0.standardizedFileURL) }
    }

    private func recordLivePhotoCheckIndividually(
        _ item: PhotosAutomationMediaItem,
        stagingRoot: URL,
        libraryID: LibraryID,
        store: LibraryPreviewStore
    ) async throws {
        let fingerprint = try await Task.detached(priority: .utility) {
            try PhotosAutomationClient().catalogFingerprint(
                limit: Self.batchFingerprintSize
            )
        }.value
        try Task.checkCancellation()
        guard let manifest = store.manifest(for: libraryID),
              Self.fingerprintMatches(fingerprint: fingerprint, manifest: manifest) else {
            throw PhotosAutomationError.malformedResponse(
                "Photos changed libraries before an isolated Live Photo export."
            )
        }
        let result = try await Task.detached(priority: .utility) {
            try PhotosAutomationClient().exportMediaItem(
                identifier: item.id,
                version: .original,
                to: stagingRoot
            )
        }.value
        defer { try? FileManager.default.removeItem(at: result.destinationDirectory) }
        try Task.checkCancellation()
        try await recordLivePhotoCheck(
            from: result,
            item: item,
            stagingRoot: stagingRoot,
            libraryID: libraryID,
            store: store
        )
    }

    private func recordLivePhotoCheck(
        from result: PhotosAutomationExportResult,
        item: PhotosAutomationMediaItem,
        stagingRoot: URL,
        libraryID: LibraryID,
        store: LibraryPreviewStore
    ) async throws {
        guard result.mediaItemID == item.id,
              result.reportedFilename == item.filename else {
            throw PhotosAutomationError.malformedResponse(
                "Live Photo export identity did not match the selected item."
            )
        }
        let movies = result.observedFiles.filter(Self.isMovieFile)
        let images = result.observedFiles.filter {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        }
        if movies.isEmpty, !images.isEmpty {
            store.markLivePhotoChecked(item.id, libraryID: libraryID)
        } else if movies.count == 1, !images.isEmpty {
            let proxy = try await VideoPlaybackProxyLoader.create(
                from: result,
                expectedItem: item,
                stagingRoot: stagingRoot
            )
            defer { try? FileManager.default.removeItem(at: proxy) }
            try Task.checkCancellation()
            try store.storeLivePhotoVideo(proxy, for: item.id, libraryID: libraryID)
        } else {
            throw PhotosAutomationError.malformedResponse(
                "The Live Photo export did not contain one identifiable image and motion clip."
            )
        }
    }

    func cancelWaitingForPhotos() {
        readinessTask?.cancel()
    }

    func clearPreviewCache(libraryID: LibraryID, store: LibraryPreviewStore) {
        guard store.activeIndexLibraryID == nil else {
            errorMessage = "Wait for indexing to finish before clearing the cache."
            return
        }
        activeLibraryID = libraryID
        previewCompletedCount = 0
        previewTotalCount = 0

        do {
            try store.clear(libraryID: libraryID)
            let root = try Self.previewCacheRoot(for: libraryID)
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            statusMessage = "Cleared this library's app-owned preview cache."
        } catch {
            errorMessage = "Could not clear preview cache: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func removeRegistration(
        libraryID: LibraryID,
        registry: LibraryRegistry,
        store: LibraryPreviewStore
    ) -> Bool {
        guard store.activeIndexLibraryID == nil else {
            errorMessage = "Wait for indexing to finish or cancel it before removing this registration."
            return false
        }
        activeLibraryID = libraryID
        errorMessage = nil

        do {
            try store.clear(libraryID: libraryID)
            let stagingRoot = try Self.previewCacheRoot(for: libraryID)
            if FileManager.default.fileExists(atPath: stagingRoot.path) {
                try FileManager.default.removeItem(at: stagingRoot)
            }
            registry.removeLibrary(id: libraryID)
            statusMessage = "Removed the library registration and its app-owned preview cache."
            return true
        } catch {
            errorMessage = "Could not remove the registration because its preview cache could not be cleared: \(error.localizedDescription)"
            return false
        }
    }

    private func requireConfirmation() -> Bool {
        guard userConfirmedPhotosReady else {
            errorMessage = "Confirm that Photos has finished opening the intended library before reading or exporting."
            return false
        }
        return true
    }

    private func run(_ operation: () throws -> Void) {
        guard !isWorking else { return }
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try operation()
        } catch {
            errorMessage = error.localizedDescription
            if let automationError = error as? PhotosAutomationError,
               let suggestion = automationError.recoverySuggestion {
                errorMessage = "\(error.localizedDescription) \(suggestion)"
            }
        }
    }

    private func exportPreviewBatchWithRecovery(
        _ items: [PhotosAutomationMediaItem],
        to stagingRoot: URL,
        libraryID: LibraryID,
        store: LibraryPreviewStore
    ) async throws -> PhotosAutomationBatchExportResult? {
        var didRetryAfterDelay = false
        while true {
            do {
                let result = try await Self.exportPreviewBatch(items, to: stagingRoot)
                isWaitingForPreviewRetry = false
                return result
            } catch is CancellationError {
                isWaitingForPreviewRetry = false
                throw CancellationError()
            } catch is PreviewIndexingError {
                guard !didRetryAfterDelay else {
                    isWaitingForPreviewRetry = false
                    throw PreviewIndexingError.previewBatchShouldBeDeferred(items.count)
                }
                didRetryAfterDelay = true
                try await waitBeforePreviewRetry(libraryID: libraryID, store: store)
            }
        }
    }

    private func waitBeforePreviewRetry(
        libraryID: LibraryID,
        store: LibraryPreviewStore
    ) async throws {
        isWaitingForPreviewRetry = true
        statusMessage = "Photos did not produce this preview batch. Waiting 30 seconds, then retrying automatically."
        do {
            try await Task.sleep(for: Self.previewRetryDelay)
            let sample = try await Task.detached(priority: .utility) {
                try PhotosAutomationClient().mediaCatalogPage(
                    offset: 0,
                    limit: Self.fingerprintPageSize
                )
            }.value
            try Task.checkCancellation()
            guard let manifest = store.manifest(for: libraryID),
                  Self.fingerprintMatches(sample: sample, manifest: manifest) else {
                throw PhotosAutomationError.malformedResponse(
                    "The library currently open in Photos changed while preview indexing was waiting to retry."
                )
            }
            isWaitingForPreviewRetry = false
            statusMessage = "Retrying the same preview batch after a 30-second pause."
        } catch {
            isWaitingForPreviewRetry = false
            throw error
        }
    }

    nonisolated private static func exportPreviewBatch(
        _ items: [PhotosAutomationMediaItem],
        to stagingRoot: URL
    ) async throws -> PhotosAutomationBatchExportResult? {
        let startedAt = Date()
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try PhotosAutomationClient().exportMediaItems(
                    items: items,
                    version: .rendered,
                    to: stagingRoot
                )
            }.value
            do {
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: result.destinationDirectory)
                throw error
            }

            let exportedResults = result.itemResults.compactMap(\.exportResult)
            let readyResultCount = exportedResults.filter { !$0.observedFiles.isEmpty }.count
            if !exportedResults.isEmpty, readyResultCount == 0 {
                try? FileManager.default.removeItem(at: result.destinationDirectory)
                performanceLogger.notice(
                    "Photos returned no ready files for \(items.count, privacy: .public) items; waiting 30 seconds before retry"
                )
                throw PreviewIndexingError.photosReturnedNoFiles(items.count)
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            performanceLogger.info(
                "Photos exported \(items.count, privacy: .public) preview items in \(elapsed, privacy: .public) seconds"
            )
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PreviewIndexingError {
            throw error
        } catch {
            let elapsed = Date().timeIntervalSince(startedAt)
            performanceLogger.error(
                "Photos batch export failed after \(elapsed, privacy: .public) seconds: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func retryFailedPreviewUpdates(
        _ updates: [LibraryPreviewUpdate],
        items: [PhotosAutomationMediaItem],
        stagingRoot: URL
    ) async throws -> [LibraryPreviewUpdate] {
        let failedIDs = Set(updates.compactMap { update in
            update.thumbnailData == nil ? update.itemID : nil
        })
        guard !failedIDs.isEmpty else { return updates }
        let retryItems = items.filter { failedIDs.contains($0.id) }
        guard !retryItems.isEmpty else { return updates }

        let retryUpdates = try await makeIsolatedPreviewUpdates(
            retryItems,
            stagingRoot: stagingRoot
        )
        let retryByID = Dictionary(uniqueKeysWithValues: retryUpdates.map { ($0.itemID, $0) })
        return updates.map { retryByID[$0.itemID] ?? $0 }
    }

    /// Recursively reduces only a batch whose single Photos export command
    /// failed. This keeps healthy groups batched while isolating one bad asset
    /// without discarding the rest of the batch.
    private func makePreviewUpdatesByBisecting(
        _ items: [PhotosAutomationMediaItem],
        stagingRoot: URL
    ) async throws -> [LibraryPreviewUpdate] {
        try Task.checkCancellation()
        guard !items.isEmpty else { return [] }
        if items.count == 1 {
            return try await makeIsolatedPreviewUpdates(items, stagingRoot: stagingRoot)
        }

        let midpoint = items.count / 2
        let groups = [Array(items[..<midpoint]), Array(items[midpoint...])]
        var updates: [LibraryPreviewUpdate] = []
        updates.reserveCapacity(items.count)

        for group in groups where !group.isEmpty {
            try Task.checkCancellation()
            do {
                if let result = try await Self.exportPreviewBatch(group, to: stagingRoot) {
                    let groupUpdates: [LibraryPreviewUpdate]
                    do {
                        groupUpdates = try await Self.makePreviewUpdates(from: result)
                    } catch {
                        try? FileManager.default.removeItem(at: result.destinationDirectory)
                        throw error
                    }
                    try? FileManager.default.removeItem(at: result.destinationDirectory)
                    updates.append(contentsOf: try await retryFailedPreviewUpdates(
                        groupUpdates,
                        items: group,
                        stagingRoot: stagingRoot
                    ))
                } else {
                    updates.append(contentsOf: try await makePreviewUpdatesByBisecting(
                        group,
                        stagingRoot: stagingRoot
                    ))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                updates.append(contentsOf: try await makeIsolatedPreviewUpdates(
                    group,
                    stagingRoot: stagingRoot
                ))
            }
        }
        return updates
    }

    private func makeIsolatedPreviewUpdates(
        _ items: [PhotosAutomationMediaItem],
        stagingRoot: URL
    ) async throws -> [LibraryPreviewUpdate] {
        let startedAt = Date()
        var updates: [LibraryPreviewUpdate] = []
        updates.reserveCapacity(items.count)
        for item in items {
            try Task.checkCancellation()
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PhotosAutomationClient().exportMediaItem(
                        identifier: item.id,
                        version: .rendered,
                        to: stagingRoot
                    )
                }.value
                defer { try? FileManager.default.removeItem(at: result.destinationDirectory) }
                try Task.checkCancellation()
                let payload = try await PreviewThumbnailLoader.payload(
                    from: result.observedFiles
                )
                let technicalMetadata = try await Self.previewTechnicalMetadata(
                    rendered: payload.technicalMetadata,
                    itemID: item.id,
                    filename: item.filename,
                    stagingRoot: stagingRoot
                )
                updates.append(
                    LibraryPreviewUpdate(
                        itemID: item.id,
                        thumbnailData: payload.thumbnailData,
                        viewerPreviewData: payload.viewerPreviewData,
                        technicalMetadata: technicalMetadata,
                        errorDescription: nil
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                updates.append(
                    LibraryPreviewUpdate(
                        itemID: item.id,
                        thumbnailData: nil,
                        viewerPreviewData: nil,
                        technicalMetadata: nil,
                        errorDescription: error.localizedDescription
                    )
                )
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        Self.performanceLogger.info(
            "Isolated fallback processed \(updates.count, privacy: .public) preview items in \(elapsed, privacy: .public) seconds"
        )
        return updates
    }

    nonisolated private static func makePreviewUpdates(
        from batchResult: PhotosAutomationBatchExportResult
    ) async throws -> [LibraryPreviewUpdate] {
        let startedAt = Date()
        var updates: [LibraryPreviewUpdate] = []
        updates.reserveCapacity(batchResult.itemResults.count)
        for itemResult in batchResult.itemResults {
            try Task.checkCancellation()
            guard let exportResult = itemResult.exportResult else {
                updates.append(
                    LibraryPreviewUpdate(
                        itemID: itemResult.requestedMediaItemID,
                        thumbnailData: nil,
                        viewerPreviewData: nil,
                        technicalMetadata: nil,
                        errorDescription: itemResult.errorDescription
                    )
                )
                continue
            }
            do {
                let payload = try await PreviewThumbnailLoader.payload(
                    from: exportResult.observedFiles
                )
                let technicalMetadata = try await previewTechnicalMetadata(
                    rendered: payload.technicalMetadata,
                    itemID: itemResult.requestedMediaItemID,
                    filename: exportResult.reportedFilename,
                    stagingRoot: batchResult.destinationDirectory
                )
                updates.append(
                    LibraryPreviewUpdate(
                        itemID: itemResult.requestedMediaItemID,
                        thumbnailData: payload.thumbnailData,
                        viewerPreviewData: payload.viewerPreviewData,
                        technicalMetadata: technicalMetadata,
                        errorDescription: nil
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                updates.append(
                    LibraryPreviewUpdate(
                        itemID: itemResult.requestedMediaItemID,
                        thumbnailData: nil,
                        viewerPreviewData: nil,
                        technicalMetadata: nil,
                        errorDescription: error.localizedDescription
                    )
                )
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        performanceLogger.info(
            "Converted \(updates.count, privacy: .public) preview items in \(elapsed, privacy: .public) seconds"
        )
        return updates
    }

    /// Photos' rendered export can omit camera EXIF even when the library still
    /// has it. Keep the rendered preview and fill its missing fields from the
    /// original export. A metadata-only failure must not discard the preview.
    nonisolated private static func previewTechnicalMetadata(
        rendered: PhotoTechnicalMetadata?,
        itemID: String,
        filename: String,
        stagingRoot: URL
    ) async throws -> PhotoTechnicalMetadata? {
        let fileExtension = URL(fileURLWithPath: filename).pathExtension
        let isImage = UTType(filenameExtension: fileExtension)?.conforms(to: .image) == true
        let isMissingCameraDetails = rendered?.cameraMake == nil
            || rendered?.cameraModel == nil
            || rendered?.lensModel == nil
        guard isImage && isMissingCameraDetails else {
            return rendered
        }
        do {
            let originalExport = try await Task.detached(priority: .utility) {
                try PhotosAutomationClient().exportMediaItem(
                    identifier: itemID,
                    version: .original,
                    to: stagingRoot
                )
            }.value
            defer { try? FileManager.default.removeItem(at: originalExport.destinationDirectory) }
            try Task.checkCancellation()
            guard let original = PhotoTechnicalMetadataExtractor.metadata(
                from: originalExport.observedFiles
            ) else {
                return rendered
            }
            return rendered?.fillingMissingCameraValues(from: original) ?? original
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return rendered
        }
    }

    private func readAutomaticSyncCatalog() async throws -> PreparedAutomaticSyncCatalog {
        let items: [PhotosAutomationMediaItem]
        let totalMediaItemCount: Int
        do {
            let basicCatalog = try await Task.detached(priority: .utility) {
                try PhotosAutomationClient().basicMediaCatalog()
            }.value
            try Task.checkCancellation()
            let metadataCatalog = try await Task.detached(priority: .utility) {
                try PhotosAutomationClient().bulkMetadataCatalog()
            }.value
            try Task.checkCancellation()

            guard basicCatalog.totalMediaItemCount == metadataCatalog.totalMediaItemCount,
                  basicCatalog.mediaItems.count == basicCatalog.totalMediaItemCount,
                  metadataCatalog.mediaItems.count == metadataCatalog.totalMediaItemCount else {
                throw PhotosAutomationError.malformedResponse(
                    "Photos changed while its catalog metadata was being checked."
                )
            }
            let metadataByID = Dictionary(
                uniqueKeysWithValues: metadataCatalog.mediaItems.map { ($0.id, $0) }
            )
            guard metadataByID.count == basicCatalog.mediaItems.count,
                  Set(basicCatalog.mediaItems.map(\.id)) == Set(metadataByID.keys) else {
                throw PhotosAutomationError.malformedResponse(
                    "Photos returned different media items while catalog metadata was being checked."
                )
            }
            items = basicCatalog.mediaItems.map { item in
                let metadata = metadataByID[item.id]!
                return PhotosAutomationMediaItem(
                    id: item.id,
                    filename: item.filename,
                    name: item.name,
                    itemDescription: metadata.itemDescription,
                    dateDescription: item.dateDescription,
                    captureDate: item.captureDate,
                    isFavorite: item.isFavorite,
                    pixelWidth: item.pixelWidth,
                    pixelHeight: item.pixelHeight,
                    fileSize: metadata.fileSize,
                    locationDescription: metadata.locationDescription,
                    keywords: metadata.keywords
                )
            }
            totalMediaItemCount = basicCatalog.totalMediaItemCount
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            statusMessage = "Fast change checking is unavailable. Reading the complete Photos catalog."
            let catalog = try await readPagedMediaCatalog()
            items = catalog.mediaItems
            totalMediaItemCount = catalog.totalMediaItemCount
        }

        try Task.checkCancellation()
        let albums = try await readAlbums(
            catalogItemIDs: Set(items.map(\.id)),
            isChangeCheck: true
        )
        return PreparedAutomaticSyncCatalog(
            totalMediaItemCount: totalMediaItemCount,
            items: items,
            albums: albums
        )
    }

    private func readPagedMediaCatalog() async throws -> PhotosAutomationMediaCatalogPage {
        let firstPage = try await Task.detached(priority: .utility) {
            try PhotosAutomationClient().mediaCatalogPage(
                offset: 0,
                limit: Self.catalogPageSize
            )
        }.value
        try Task.checkCancellation()

        var items = firstPage.mediaItems
        while items.count < firstPage.totalMediaItemCount {
            try Task.checkCancellation()
            let offset = items.count
            let page = try await Task.detached(priority: .utility) {
                try PhotosAutomationClient().mediaCatalogPage(
                    offset: offset,
                    limit: Self.catalogPageSize
                )
            }.value
            guard page.totalMediaItemCount == firstPage.totalMediaItemCount,
                  !page.mediaItems.isEmpty else {
                throw PhotosAutomationError.malformedResponse(
                    "Photos changed while its complete catalog was being checked at offset \(offset)."
                )
            }
            items.append(contentsOf: page.mediaItems)
        }
        guard items.count == firstPage.totalMediaItemCount,
              Set(items.map(\.id)).count == items.count else {
            throw PhotosAutomationError.malformedResponse(
                "Photos returned an incomplete or duplicate catalog during change checking."
            )
        }
        return PhotosAutomationMediaCatalogPage(
            totalMediaItemCount: firstPage.totalMediaItemCount,
            mediaItems: items
        )
    }

    private func readAlbums(
        catalogItemIDs: Set<String>,
        isChangeCheck: Bool = false
    ) async throws -> [PhotosAutomationAlbum] {
        let firstAlbumPage = try await Task.detached(priority: .utility) {
            try PhotosAutomationClient().albumCatalogPage(
                offset: 0,
                limit: Self.albumCatalogPageSize
            )
        }.value
        try Task.checkCancellation()
        var albumMetadata = firstAlbumPage.albums
        while albumMetadata.count < firstAlbumPage.totalAlbumCount {
            try Task.checkCancellation()
            let offset = albumMetadata.count
            let page = try await Task.detached(priority: .utility) {
                try PhotosAutomationClient().albumCatalogPage(
                    offset: offset,
                    limit: Self.albumCatalogPageSize
                )
            }.value
            guard page.totalAlbumCount == firstAlbumPage.totalAlbumCount,
                  !page.albums.isEmpty else {
                throw PhotosAutomationError.malformedResponse(
                    "Photos changed while album metadata was being read at offset \(offset)."
                )
            }
            albumMetadata.append(contentsOf: page.albums)
        }
        guard albumMetadata.count == firstAlbumPage.totalAlbumCount,
              Set(albumMetadata.map(\.id)).count == albumMetadata.count else {
            throw PhotosAutomationError.malformedResponse(
                "Photos returned incomplete or duplicate album metadata."
            )
        }

        var albums: [PhotosAutomationAlbum] = []
        albums.reserveCapacity(albumMetadata.count)
        for (albumIndex, album) in albumMetadata.enumerated() {
            try Task.checkCancellation()
            statusMessage = isChangeCheck
                ? "Checking album \(albumIndex + 1) of \(albumMetadata.count) for changes."
                : "Reading album \(albumIndex + 1) of \(albumMetadata.count) from Photos."

            var memberIDs: [String] = []
            if album.mediaItemCount > 0 {
                let firstMembershipPage = try await Task.detached(priority: .utility) {
                    try PhotosAutomationClient().albumMembershipPage(
                        albumID: album.id,
                        offset: 0,
                        limit: Self.albumCatalogPageSize
                    )
                }.value
                guard firstMembershipPage.totalMediaItemCount == album.mediaItemCount else {
                    throw PhotosAutomationError.malformedResponse(
                        "Photos changed album \(album.name) while its membership was being read."
                    )
                }
                memberIDs = firstMembershipPage.mediaItemIDs
                while memberIDs.count < firstMembershipPage.totalMediaItemCount {
                    try Task.checkCancellation()
                    let offset = memberIDs.count
                    let page = try await Task.detached(priority: .utility) {
                        try PhotosAutomationClient().albumMembershipPage(
                            albumID: album.id,
                            offset: offset,
                            limit: Self.albumCatalogPageSize
                        )
                    }.value
                    guard page.totalMediaItemCount == firstMembershipPage.totalMediaItemCount,
                          !page.mediaItemIDs.isEmpty else {
                        throw PhotosAutomationError.malformedResponse(
                            "Photos changed album \(album.name) while membership was being read at offset \(offset)."
                        )
                    }
                    memberIDs.append(contentsOf: page.mediaItemIDs)
                }
            }

            guard memberIDs.count == album.mediaItemCount,
                  Set(memberIDs).count == memberIDs.count else {
                throw PhotosAutomationError.malformedResponse(
                    "Photos returned incomplete or duplicate media items for album \(album.name)."
                )
            }
            // Photos can retain album references that it does not expose
            // through the root `media items` catalog. Only cache album
            // members that the app can resolve to an indexed item.
            let indexedMemberIDs = memberIDs.filter(catalogItemIDs.contains)
            let excludedMemberCount = memberIDs.count - indexedMemberIDs.count
            if excludedMemberCount > 0 {
                Self.performanceLogger.notice(
                    "Excluded \(excludedMemberCount, privacy: .public) non-catalog members from album \(album.name, privacy: .public)"
                )
            }
            albums.append(
                PhotosAutomationAlbum(
                    id: album.id,
                    name: album.name,
                    parentName: album.parentName,
                    mediaItemCount: indexedMemberIDs.count,
                    mediaItemIDs: indexedMemberIDs
                )
            )
        }
        return albums
    }

    nonisolated private static func manifestNeedsCompletion(
        _ manifest: LibraryPreviewManifest
    ) -> Bool {
        !manifest.isComplete
            || !(manifest.pendingPreviewItemIDs?.isEmpty ?? true)
            || !(manifest.pendingMetadataItemIDs?.isEmpty ?? true)
            || manifest.items.count < manifest.totalMediaItemCount
            || manifest.albums == nil
            || manifest.albums?.contains(where: { $0.mediaItemIDs == nil }) == true
    }

    nonisolated private static func catalogMatchesManifest(
        _ catalog: PreparedAutomaticSyncCatalog,
        manifest: LibraryPreviewManifest
    ) -> Bool {
        guard !manifestNeedsCompletion(manifest),
              catalog.totalMediaItemCount == manifest.totalMediaItemCount,
              catalog.items.count == manifest.items.count,
              catalog.albums.count == manifest.albums?.count,
              Set(catalog.items.map(\.id)).count == catalog.items.count,
              Set(manifest.items.map(\.id)).count == manifest.items.count,
              Set(catalog.albums.map(\.id)).count == catalog.albums.count,
              let manifestAlbums = manifest.albums,
              Set(manifestAlbums.map(\.id)).count == manifestAlbums.count else {
            return false
        }

        let manifestItemsByID = Dictionary(
            uniqueKeysWithValues: manifest.items.map { ($0.id, $0) }
        )
        for item in catalog.items {
            guard let cached = manifestItemsByID[item.id],
                  mediaItemMatches(item, cached) else {
                return false
            }
        }

        let manifestAlbumsByID = Dictionary(
            uniqueKeysWithValues: manifestAlbums.map { ($0.id, $0) }
        )
        for album in catalog.albums {
            guard let cached = manifestAlbumsByID[album.id],
                  album.name == cached.name,
                  album.parentName == cached.parentName,
                  album.mediaItemCount == cached.mediaItemCount,
                  let memberIDs = album.mediaItemIDs,
                  let cachedMemberIDs = cached.mediaItemIDs,
                  memberIDs.count == cachedMemberIDs.count,
                  Set(memberIDs) == Set(cachedMemberIDs) else {
                return false
            }
        }
        return true
    }

    nonisolated private static func mediaItemMatches(
        _ lhs: PhotosAutomationMediaItem,
        _ rhs: PhotosAutomationMediaItem
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.filename == rhs.filename
            && lhs.name == rhs.name
            && lhs.itemDescription == rhs.itemDescription
            && lhs.dateDescription == rhs.dateDescription
            && lhs.captureDate == rhs.captureDate
            && lhs.isFavorite == rhs.isFavorite
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && lhs.fileSize == rhs.fileSize
            && lhs.locationDescription == rhs.locationDescription
            && lhs.keywords.count == rhs.keywords.count
            && Set(lhs.keywords) == Set(rhs.keywords)
    }

    private func publishProgressIncrementally(
        from completed: Int,
        through target: Int,
        total: Int,
        phase: LibraryIndexPhase,
        store: LibraryPreviewStore,
        for libraryID: LibraryID
    ) async throws {
        guard target > completed else { return }
        for current in (completed + 1)...target {
            try Task.checkCancellation()
            store.updateIndexProgress(
                completed: current,
                total: total,
                phase: phase,
                for: libraryID
            )
            await Task.yield()
        }
    }

    private func publishMetadataIncrementally(
        _ items: [PhotosAutomationMediaItem],
        completed: Int,
        total: Int,
        store: LibraryPreviewStore,
        libraryID: LibraryID
    ) async throws -> Int {
        var completedCount = completed
        for item in items {
            try Task.checkCancellation()
            try store.mergeMetadataItem(item, libraryID: libraryID)
            completedCount += 1
            store.updateIndexProgress(
                completed: completedCount,
                total: total,
                phase: .enrichingMetadata,
                for: libraryID
            )
            await Task.yield()
        }
        return completedCount
    }

    private static func automationStagingRoot() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let root = applicationSupport
            .appendingPathComponent("Photo Libraries", isDirectory: true)
            .appendingPathComponent("Automation Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func previewCacheRoot(for libraryID: LibraryID) throws -> URL {
        try automationStagingRoot()
            .appendingPathComponent("Preview Cache", isDirectory: true)
            .appendingPathComponent(libraryID.rawValue.uuidString, isDirectory: true)
    }

    private static func preparePreviewCache(for libraryID: LibraryID) throws -> URL {
        let root = try previewCacheRoot(for: libraryID)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Reuse one stable job path across indexing sessions. Together with
        // the fixed batch slots, this prevents Photos from receiving a new
        // sandbox destination path for every group of previews.
        let job = root.appendingPathComponent("active-job", isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
        return job
    }

    nonisolated private static func fingerprintMatches(
        sample: PhotosAutomationMediaCatalogPage,
        manifest: LibraryPreviewManifest
    ) -> Bool {
        fingerprintMatches(
            sampleIDs: Set(sample.mediaItems.map(\.id)),
            sampleTotal: sample.totalMediaItemCount,
            manifest: manifest
        )
    }

    nonisolated private static func fingerprintMatches(
        fingerprint: PhotosAutomationCatalogFingerprint,
        manifest: LibraryPreviewManifest
    ) -> Bool {
        fingerprintMatches(
            sampleIDs: Set(fingerprint.mediaItemIdentifiers),
            sampleTotal: fingerprint.totalMediaItemCount,
            manifest: manifest
        )
    }

    nonisolated private static func fingerprintMatches(
        sampleIDs: Set<String>,
        sampleTotal: Int,
        manifest: LibraryPreviewManifest
    ) -> Bool {
        let cachedIDs = Set(manifest.items.map(\.id))
        guard !sampleIDs.isEmpty, !cachedIDs.isEmpty else { return false }

        let smallerCount = min(sampleTotal, manifest.totalMediaItemCount)
        let largerCount = max(sampleTotal, manifest.totalMediaItemCount)
        guard smallerCount > 0,
              largerCount <= max(smallerCount * 2, smallerCount + 100) else {
            return false
        }

        let overlapCount = sampleIDs.intersection(cachedIDs).count
        let comparisonCount = min(sampleIDs.count, cachedIDs.count)
        let minimumOverlap = min(10, comparisonCount)
        guard minimumOverlap > 0, overlapCount >= minimumOverlap else { return false }

        return Double(overlapCount) / Double(comparisonCount) >= 0.8
    }

}

nonisolated private struct PreparedAutomaticSyncCatalog: Sendable {
    let totalMediaItemCount: Int
    let items: [PhotosAutomationMediaItem]
    let albums: [PhotosAutomationAlbum]
}

nonisolated private struct AutoSyncCandidate: Sendable {
    let library: RegisteredLibrary
    let manifest: LibraryPreviewManifest
}

nonisolated private struct KnownLibraryFingerprint: Sendable {
    let libraryID: LibraryID
    let displayName: String
    let manifest: LibraryPreviewManifest
}

nonisolated private enum PreviewIndexingError: LocalizedError, Sendable {
    case photosReturnedNoFiles(Int)
    case previewBatchShouldBeDeferred(Int)
    case deferredPreviewsRemain(Int)

    var errorDescription: String? {
        switch self {
        case .photosReturnedNoFiles(let count):
            "Photos accepted a rendered-preview export for \(count) items, but no files became ready."
        case .previewBatchShouldBeDeferred(let count):
            "Photos did not produce \(count) previews after an automatic retry."
        case .deferredPreviewsRemain(let count):
            "\(count) previews remain deferred for a later synchronization."
        }
    }
}
